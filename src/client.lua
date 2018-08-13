-- module
local pmcli = {}

-- class
-- we init some "static" values
local PMCLI = {
  VERSION = "0.1",
  HELP_TEXT = [[Usage:
  pmcli [ --login ]
  pmcli [ --help ]
]]
}

-- ========== REQUIRES ==========
-- lua-http for networking
local http_request = require("http.request")

-- html entities (escape sequences)
local html_entities = require("htmlEntities")

-- JSON parsing
local json = require("dkjson").use_lpeg()

-- our own utils
local utils = require("pmcli.utils")

-- for now at least, a necessary evil
local sleep = require("cqueues").sleep

-- mpv IPC
local socket = require("cqueues.socket")
-- ==============================


-- ========== CONVENIENCIES ==========
-- conveniency for simple y/n confirmation dialogs
function pmcli.confirm_yn(msg)
  io.stdout:write(msg .. " [y/n]\n")
  repeat
    yn = io.read()
  until yn == "y" or yn == "n"
  return yn == "y"
end


function pmcli.msecs_to_time(ms)
  return os.date("%T", math.floor(ms/1000) - 3600) -- H:M:S, epoch was at 1AM
end


function pmcli.print_menu(items)
  io.stdout:write("\n=== " .. items.title .. " ===\n")
  io.stdout:write(items.is_root and "0: quit\n" or "0: ..\n")
  for i,item in ipairs(items) do
    io.stdout:write(item.tag .. " " .. i .. ": " .. item.title .. "\n")
  end
end


function pmcli.join_keys(s1, s2)
  local i = 0
  local match_length = -1
  -- preprocessing: remove leading /
  if s1:sub(1,1) == "/" then s1 = s1:sub(2) end
  if s2:sub(1,1) == "/" then s2 = s2:sub(2) end
  for i = 1, math.min(#s1, #s2) do
    if s1:sub(1,i) == s2:sub(1,i) then
      match_length = i
    elseif match_length ~= -1 then
      -- there's been a match before, so that was the overlap
      break
    end
  end
  if match_length == -1 then
    return "/" .. s1 .. "/" .. s2
  elseif match_length == #s2 then
    return "/" .. s2
  else
    return "/" .. s1:sub(1, match_length) .. s2:sub(match_length + 1)
  end
end
-- ===================================


-- ========== SETUP ==========
-- constructor
function pmcli.new(args)
  io.stdout:write("Plex Media CLIent v" ..  PMCLI.VERSION .. "\n")
  local self = {}
  setmetatable(self, { __index = PMCLI })
  
  -- first, read 
  local parsed_args = self:parse_args(args)
  
  -- setup options from config file
  -- or, alternatively, ask user and login
  self.options = utils.get_config()
  if not self.options then
    -- config file not found
    -- if --login was passed, skip confirmation prompt
    self.options = self:first_time_config(parsed_args.login)
  elseif self.options and parsed_args.login then
    -- config file found but user wants to redo login
    io.stdout:write("Attempting new login to obtain a new token.\n")
    self.options.plex_token, self.options.unique_identifier = self:login()
    io.stdout:write("Committing config to disk...\n\n")
    utils.write_config(self.options)
  end
  
  -- if we need to step around mismatched hostnames from the certificate
  local http_tls = require("http.tls")
  http_tls.has_hostname_validation = self.options.require_hostname_validation
  self.ssl_context = http_tls.new_client_context()
  
  self.mpv_socket_name = os.tmpname()
  
  return self
end


function PMCLI:connect_mpv_socket()
  self.mpv_socket = socket.connect({ path = self.mpv_socket_name })
  self.mpv_socket:settimeout(10.0)
end


-- command line arguments
function PMCLI:parse_args(args)
  local parsed_args = {}
  for i,arg in ipairs(args) do
    if arg == "--login" then
      parsed_args.login = true
    elseif arg == "--help" then
      self:quit(PMCLI.HELP_TEXT)
    end
  end
  return parsed_args
end


-- headers for auth access
function PMCLI:setup_headers(headers)
  headers:append("X-Plex-Client-Identifier", self.options.unique_identifier)
  headers:append("X-Plex-Product", "PMCLI")
  headers:append("X-Plex-Version", PMCLI.VERSION)
  headers:append("X-Plex-Token", self.options.plex_token, true)
  headers:append("Accept", "application/json")
end


function PMCLI:login()
  local plex_token
  local unique_identifier = "pmcli-" .. PMCLI.VERSION .. "-" .. utils.generate_random_id()
  repeat 
    io.stdout:write("\nPlease enter your Plex account name or email.\n")
    local login = io.read()
    io.stdout:write("\nPlease enter your Plex account password.\n")
    local password = utils.read_password()
    local errmsg
    plex_token, errmsg = self:request_token(login, password, unique_identifier)
    if not plex_token then
      io.stderr:write("[!!] Authentication error:\n", errmsg .. "\n")
      if not pmcli.confirm_yn("Would you like to try again with new credentials?") then
        self:quit("Configuration was unsuccessful.\n")
      end
    end
  until plex_token
  -- delete password from process memory as soon as possible
  password = nil
  collectgarbage()
  return plex_token, unique_identifier
end


function PMCLI:first_time_config(skip_prompt)
  if not skip_prompt and not pmcli.confirm_yn("\nConfiguration file not found. Would you like to proceed with configuration and login?") then
    self:quit()
  end
  
  local options = {}
  
  local uri_patt = require("lpeg_patterns.uri").uri * -1
  io.stdout:write("\nPlease enter an address (and port if not default) to access your Plex Media Server.\nIt should look like https://example.com:32400 .\n")
  repeat
    options.base_addr = io.read()
    if not uri_patt:match(options.base_addr) then
      io.stderr:write("[!] Malformed URI. Please try again.\n")
    end
  until uri_patt:match(options.base_addr)
  
  options.plex_token, options.unique_identifier = self:login()
  
  options.require_hostname_validation = not pmcli.confirm_yn("\nDo you need PMCLI to ignore hostname validation (must e.g. if PMS under different local address)?")
  
  io.stdout:write("\nCommitting configuration to disk...\n")
  utils.write_config(options)
  
  return options
end


-- token request
function PMCLI:request_token(login, pass, id)
  local escape = require("http.util").encodeURIComponent
  local request = http_request.new_from_uri("https://plex.tv/users/sign_in.json")
  request.headers:append("X-Plex-Client-Identifier", id)
  request.headers:append("X-Plex-Product", "PMCLI")
  request.headers:append("X-Plex-Version", PMCLI.VERSION)
  request.headers:delete(":method")
  request.headers:append(":method", "POST")
  request.headers:append("Content-Type", "application/x-www-form-urlencoded")
  request.headers:append("Accept", "application/json")
  request:set_body("user%5blogin%5d=" .. escape(login) .. "&user%5bpassword%5d=" .. escape(pass))
  local headers, stream = request:go()
  if not headers then
    self:quit("[!!!] Network error on token request: " .. stream ..  "\n")
  end
  local reply = json.decode(stream:get_body_as_string())
  if reply.error then
    return nil, reply.error
  else
    return reply.user.authentication_token
  end
end
-- ===========================


-- ========== FUNCTIONS ==========
function PMCLI:quit(error_message)
  if self.mpv_socket_name then os.remove(self.mpv_socket_name) end
  if error_message then
    io.stderr:write(error_message)
    os.exit(1)
  else
    io.stdout:write("Bye!\n")
    os.exit(0)
  end
end


function PMCLI:plex_request(suffix)
-- TODO: better error handling
  local request = http_request.new_from_uri(self.options.base_addr .. suffix)
  request.ctx = ssl_context
  self:setup_headers(request.headers)
  local headers, stream = request:go(10.0) -- 10 secs timeout
  if not headers then
    self:quit("[!!!] Network error on API request " .. self.options.base_addr .. suffix .. ":\n" .. stream ..  "\n")
  end
  if headers:get(":status") == "401" then
    self:quit("[!!!] API request returned error 401: unauthorized.\nYour token may have expired, consider logging in again by passing --login.\n")
  end
  return stream:get_body_as_string()
end


function PMCLI:mpv_socket_read_all(item)
    repeat
    local msg, err = self.mpv_socket:read()
    if msg == nil and err == 110 then
      -- timeout
      self.mpv_socket:clearerr()
      return false
    elseif msg then
      local decoded = json.decode(msg)
      if decoded.data then -- reply to playback-time request
        local msecs = math.floor(decoded.data*1000) -- secs from mpv, millisecs for plex
        if msecs > item.duration * 0.975 then -- close enough to end, scrobble
          self:plex_request("/:/scrobble?key=" .. item.rating_key .. "&identifier=com.plexapp.plugins.library")
          item.view_offset = nil
        else -- just update viewOffset
          self:plex_request("/:/progress?key=" .. item.rating_key .. "&time=" .. msecs .. "&identifier=com.plexapp.plugins.library")
          item.view_offset = msecs
        end
      end
    end
  until msg == nil and err ~= 110 -- TODO: handle this
  self.mpv_socket:clearerr()
  return true
end


function PMCLI:play_media(item)
-- this whole mechanism is a mess. look into something better.
  local mpv_args = "--input-ipc-server=" .. self.mpv_socket_name
  if item.view_offset and pmcli.confirm_yn("The item is set as partially viewed. Would you like to resume at " .. pmcli.msecs_to_time(item.view_offset) .. "?") then
    mpv_args = mpv_args .. " --start=" .. pmcli.msecs_to_time(item.view_offset)
  end
  mpv_args = mpv_args .. " " .. '--title="' .. item.title .. '"'
  mpv_args = mpv_args .. " " .. self.options.base_addr .. item.part_key .. "?X-Plex-Token=" .. self.options.plex_token
  
  os.execute("mpv " .. mpv_args .. " &")
  -- wait for mpv to setup the socket
  self:connect_mpv_socket()
  local laps = 0
  repeat
    sleep(0.25)
    laps = laps + 1
  until self.mpv_socket:peername() or laps > 20 -- after 5 seconds, we recognize a failure. very ugly.
  -- sync loop
  if laps > 20 then
    io.stderr:write("[!] Couldn't reach IPC socket, won't sync progress to Plex server.\n")
  else
    repeat
      self.mpv_socket:write('{ "command": ["get_property", "playback-time"] }\n')
    until self:mpv_socket_read_all(item)
  end

  -- wait for mpv to exit; especially useful if IPC socket failed; still, abominably ugly
  -- note: the full process name gets cut, but the socket name is unique so it is enough as an identifier
  while os.execute("pkill -0 -f 'mpv --input-ipc-server=" .. self.mpv_socket_name .. "'") do
    sleep(0.5)
  end
  
  os.execute("stty sane") -- really, really ugly
end


function PMCLI:get_menu_items(reply, parent_key)
  local items = {}
  
  -- libraries and relevant views (All, By Album etc.)
  if reply.MediaContainer.Directory then
    for _, item in ipairs(reply.MediaContainer.Directory) do
      items[#items + 1] = {
        title = html_entities.decode(item.title),
        key = pmcli.join_keys(parent_key, item.key),
        tag = "L"
      }
    end
  end
  -- actual items
  if reply.MediaContainer.Metadata then
    for _, item in ipairs(reply.MediaContainer.Metadata) do
      if item.type == "track" or item.type == "episode" or item.type == "movie" then
      -- streamable file
        items[#items + 1] = {
          title = html_entities.decode(item.title),
          duration = item.duration,
          view_offset = item.viewOffset,
          rating_key = item.ratingKey,
          part_key = pmcli.join_keys(parent_key, item.Media[1].Part[1].key), -- TODO: support items with multiple versions
          tag = item.type:sub(1,1):upper() -- T, E, M
        }
      else
      -- some kind of directory; NB this includes when type is nil which, afaik, is only for folders in "By Folder" view
        items[#items + 1] = {
          title = html_entities.decode(item.title),
          key = item.key,
          tag = "D"
        }
      end
    end
  end

  items.title = html_entities.decode(reply.MediaContainer.title1)
  items.allow_sync = reply.MediaContainer.allowSync
  items.is_root = reply.MediaContainer.viewGroup == nil
  return items
end


function PMCLI:open_item(item)
  if item.tag == "D" or item.tag == "L" then
    self:open_menu(item)
  elseif item.tag == "T" or item.tag == "M" or item.tag == "E" then
    self:play_media(item)
  end
end


function PMCLI:open_menu(parent_item)
-- TODO: rewrite to avoid recursion (so old handlers can go out of scope and be GC'd)
-- we'll need a stack of menu keys to know where to backtrack
  local reply = json.decode(self:plex_request(parent_item.key))
  local items = self:get_menu_items(reply, parent_item.key)
  reply = nil
  while true do
    pmcli.print_menu(items)
    for _,c in ipairs(utils.read_commands()) do
        if c == "q" then
          self:quit()
        elseif c == "*" then
          for _,item in ipairs(items) do
            self:open_item(item)
          end
        elseif c == 0 then
          return
        elseif c > 0 and c <= #items then
          self:open_item(items[c])
        end
    end
  end
end
-- ===============================


function PMCLI:run()
  io.stdout:write("Connecting to Plex Server...\n")
  self:open_menu({ key = "/library/sections" })
  self:quit()
end


return pmcli
