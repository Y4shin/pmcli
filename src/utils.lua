-- module
local utils = {}

local lpeg = require("lpeg")

-- ========== COMMAND PARSER ===========
function utils.expand_range(left, right)
  local range = {}
  local step = left <= right and 1 or -1
  for i = left,right,step do
    range[#range + 1] = i
  end
  return range
end


function utils.flatten(t)
  if type(t) ~= "table" then return { t } end
  local flat = {}
  for i = 1, #t do
    local t_i = utils.flatten(t[i])
    for j = 1, #t_i do
      flat[#flat + 1] = t_i[j]
    end
  end
  return flat
end


--[[
Command GRAMMAR in (extended) BNF:
  S ::= "q" | "*" | I
  I ::= num L | R L
  L ::= "," I | ""
  R ::= num "-" num
  num ::= [0-9]+
  
Then there's provisions for whitespace.
]]--
utils.command_list = lpeg.Ct({
  lpeg.V("ws") * (lpeg.C("q") + lpeg.C("*") + lpeg.V("I")) * -1,
  I = lpeg.V("R") * lpeg.V("L") + lpeg.V("n") * lpeg.V("L"),
  L = lpeg.V("ws") * (lpeg.P(",") * lpeg.V("I") + lpeg.P("")),
  R = lpeg.V("n") * lpeg.V("dash") * lpeg.V("n") / utils.expand_range,
  dash = lpeg.V("ws") * lpeg.P("-"),
  n = lpeg.V("ws") * (lpeg.R("09")^1 / tonumber),
  ws = lpeg.P(lpeg.locale().space^0)
}) / utils.flatten


function utils.read_commands()
  local commands = utils.command_list:match(utils.read())
  while not commands do
    io.stderr:write("[!!] Malformed command string, please try again.\n")
    commands = utils.command_list:match(utils.read())
  end
  return commands
end

-- =====================================


-- ========== MISCELLANEOUS ==========
-- save stty state as we found it
function utils.save_stty()
  f = assert(io.popen("stty --save", "r"))
  s = assert(f:read())
  assert(f:close())
  return s
end


utils.stty_save = utils.save_stty()


function utils.generate_random_id()
  -- string of 32 random digits
  math.randomseed(os.time())
  local id = ""
  for i = 1,32 do
    id = id .. math.random(0,9)
  end
  return id
end


function utils.msecs_to_time(ms)
  return os.date("%T", math.floor(ms/1000) - 3600) -- H:M:S, epoch was at 1AM
end


function utils.join_keys(s1, s2)
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


-- ========== IO ==========
function utils.print_menu(items)
  io.stdout:write("\n=== " .. items.title .. " ===\n")
  io.stdout:write(items.is_root and "0: quit\n" or "0: ..\n")
  for i = 1,#items do
    io.stdout:write(items[i].tag .. " " .. i .. ": " .. items[i].title .. "\n")
  end
end

function utils.confirm_yn(msg, default)
  io.stdout:write(msg .. " [y/n]\n")
  local yn = utils.read()
  while yn ~= "y" and yn ~= "n" do
    io.stderr:write("[!!] Please enter either 'y' or 'n'.\n")
    yn = utils.read()
  end
  return yn == "y"
end


function utils.read(mode)
  io.stdout:write("> ")
  return io.read(mode and mode or "*l")
end


function utils.read_utf8_char(file)
  local len = 1
  local char = file:read(1)
  if not char then return nil end
  local first_byte = string.byte(char)
  while (first_byte >= 192) do -- first two bits are 11
    first_byte = (first_byte * 2) % 2^8 -- shift left one bit
    len = len + 1
    char = char .. file:read(1)
  end
  return char, len
end


function utils.read_password()
  local pass = ""
  local len = 0
  local prev_len, ch
  os.execute("stty -echo raw")
  io.stdout:write("> ")
  repeat
    prev_len = len
    ch, len = utils.read_utf8_char(io.stdin)
    if ch == "\127" then -- backspace
      io.stdout:write("\b \b") -- go back, write whitespace, go back again
      io.stdout:flush()
      pass = pass:sub(1, -1 -prev_len) -- eat last character, which could be multiple bytes
    elseif ch == "\n" or ch == "\r" then -- EOL
      io.stdout:write("\n\r") -- accept EOL as end of string
      io.stdout:flush()
    elseif not ch then -- some IO error has occurred
      os.execute("stty " .. utils.stty_save)
      return nil, "Error while reading character from stdin."
    else -- valid character. mind it's a... wide definition of valid. like, Meta+F1 is valid.
      io.stdout:write("*")
      io.stdout:flush()
      pass = pass .. ch
    end
  until ch == '\n' or ch == '\r'
  os.execute("stty " .. utils.stty_save)
  return pass
end


function utils.indent(tt, times)
  for i = 1,times do
    tt[#tt + 1] = " "
  end
  return tt
end


-- tostring extension that can also work on tables
-- heavily based on code from http://lua-users.org/wiki/TableSerialization :)
function utils.tostring(tt, inline, indent, done)
  local sep = inline and " " or "\n"
  indent = indent or 0
  done = done or {} -- for cycle breaking
  if type(tt) == "table" then
    local sb = {}
    sb = utils.indent(sb, indent)
    sb[#sb + 1] = "{" .. sep
    indent = not inline and indent + 2 or 0
    for key, value in pairs (tt) do
      if type(value) == "table" and not done[value] then
        done[value] = true
        sb[#sb + 1] = utils.tostring(value, inline, indent, done)
      elseif "number" == type(key) then
        sb = utils.indent(sb, indent)
        sb[#sb + 1] = string.format("\"%s\"", tostring(value))
      else
        sb = utils.indent(sb, indent)
        sb[#sb + 1] = string.format("%s = \"%s\"", tostring(key), tostring(value))
      end
      sb[#sb + 1] = "," .. sep
    end
    if sb[#sb] == "," .. sep then
      sb[#sb] = sep
    end
    sb = utils.indent(sb, indent - 2)
    sb[#sb + 1] = "}"
    return table.concat(sb)
  else
    return tostring(tt)
  end
end
-- ========================


-- ========== CONFIG FILE ===========
function utils.parse_config_line(line)
  -- comments
  if string.match(line, '^#') then return nil end
  -- proper lines
  local key, value = string.match(line,'^%s-([^=%s]+)%s-=%s-([^%s]+)%s-$')
  -- recognize booleans
  if value == "true" then
    value = true
  elseif value == "false" then
    value = false
  end
  return key, value
end


function utils.get_config_absolute_filename()
  local dir = os.getenv("XDG_CONFIG_HOME")
  dir = dir or (os.getenv("HOME") and os.getenv("HOME") .. "/.config")
  if not dir then
    return nil, "specify a configuration file location by --config or either $XDG_CONFIG_HOME or $HOME need to be set"
  else
    return dir .. "/pmcli_config"
  end
end


function utils.write_config(options, user_filename)
  local config_filename, error_message = user_filename ~= "" and user_filename or utils.get_config_absolute_filename()
  if not config_filename then
    -- file not found of sorts
    return nil, error_message, -1
  end
  local file, error_message, error_code = io.open(config_filename, "w")
  if not file then
    -- error when opening
    return file, error_message, error_code
  end
  for k,v in pairs(options) do
    file:write(tostring(k) .. " = " .. tostring(v) .. "\n")
  end
  file:close()
  
  if not os.execute("chmod 600 " .. config_filename) then
    return nil, "Error setting 600 permissions to " .. config_filename .. ", you may want to double-check", -2
  else
    return true
  end
end


function utils.get_config(user_filename)
  -- defaults
  local options = {
    require_hostname_validation = true,
    verify_server_certificates = true,
    unique_identifier = "pmcli-dummy"
  }
    
  -- open file
  local config_filename, error_message = user_filename ~= "" and user_filename or utils.get_config_absolute_filename()
  if not config_filename then
    return nil, error_message
  end
  local file, error_message, error_code = io.open(config_filename)
  if not file then -- config file not found or other error
    return nil, error_message, error_code
  end
  
  -- parse file
  for line in file:lines() do
    local key, value = utils.parse_config_line(line)
    if key ~= nil and value ~= nil then options[key] = value end
  end

  file:close()  
  return options
end
-- ==================================


-- ========== INPUT.CONF ===========
-- This mechanism is a terrible hack, but there is no easy alternative.
-- We need to remap user quit commands to stop commands and mpv has no interface
-- to give you a list of keys bound to a certain command (reasonably: commands
-- can be arbitrary sequences); the only alternatives would be to reimplement
-- the event loop manually or embed mpv through libmpv... I'd rather not.
function utils.get_input_conf_filename()
-- NB: as of right now mpv only ever reads a single input.conf file
	local dir = os.getenv("XDG_CONFIG_HOME")
	dir = dir or os.getenv("HOME")
	return dir and dir .. "/.config/mpv/input.conf"
end


function utils.parse_input_conf_line(line)
	-- read up to comment
	local bind = string.match(line, "^[^#]*")
	-- (key command) pairs, either can be nil if malformed input.conf
	return string.match(bind, '^%s*(%S+)%s+(.+)')
end


function utils.get_masked_input_conf_quit_binds()
	-- setup default overwrites
	local quit_binds = {
		["q"] = "stop",
		["Q"] = "write-watch-later-config; stop"
	}
	local input_conf_filename = utils.get_input_conf_filename()
	if input_conf_filename then
	-- there are nondefault binds of some sort
		local file, error_message, error_code = io.open(input_conf_filename)
		if not file then
			return nil, error_message, error_code
		end
		for l in file:lines() do
			local key, command = utils.parse_input_conf_line(l)
			if key and command then
			-- it's not a comment or otherwise malformed
				if quit_binds[key] and not string.match(command, "quit") then
				-- remapped, hopefully it was just the default
					quit_binds[key] = command
				elseif string.match(command, "quit") then
				-- nondefault with quit
					quit_binds[key] = string.gsub(command, "quit%-watch%-later", "write-watch-later-config; stop")
					quit_binds[key] = string.gsub(quit_binds[key], "quit", "stop")
				end
			end
		end
	end
	return quit_binds
end
-- =================================



-- ========== STACK ==========
utils.STACK = {}


function utils.STACK.new()
	local self = {}
	setmetatable(self, { __index = utils.STACK })
	self.m_stack = {}
	return self
end


-- TODO: add a counter of removals done since last push
-- when they're too many, do a bogus assignment to allow garbage collection
function utils.STACK:pop(idx)
	local idx = idx and #self.m_stack + idx or #self.m_stack
	local retval = self.m_stack[idx]
	table.remove(self.m_stack, idx)
	return retval
end


function utils.STACK:push(o)
	assert(o ~= nil)
	self.m_stack[#self.m_stack +1] = o
end
-- ===========================



-- ========== QUEUE ==========
utils.QUEUE = {}


function utils.QUEUE.new()
	local self = {}
	setmetatable(self, { __index = utils.QUEUE })
	self.m_queue = {}
	self.m_first = 1
	self.m_last = 0
	return self
end


function utils.QUEUE:enqueue(o)
	assert(o ~= nil)
	self.m_last = self.m_last + 1
	self.m_queue[self.m_last] = o
end


function utils.QUEUE:dequeue()
	if self.m_first <= self.m_last then
		local retval = self.m_queue[self.m_first]
		self.m_queue[self.m_first] = nil
		self.m_first = self.m_first +1
		return retval
	else
		return nil
	end
end


-- TODO: smartly shift from the closest end
function utils.QUEUE:remove(idx)
	idx = idx or 0
	if idx <= 0 then
		idx = self.m_last - idx
	end
	assert(self.m_first <= idx and idx <= self.m_last, "queue removal out of bounds")
	for i = idx,self.m_last do
		self.m_queue[i] = self.m_queue[i +1]
	end
	self.m_last = self.m_last - 1
end
-- ===========================


-- ========== DOWNLOAD HELPER ==========
utils.DOWNLOADER = {}utils.DOWNLOADER = {}

-- NOTA BENE: for the moment, this code is all duplicated
-- hopefully, we'll eventually be able to use a downloader instance for all our requests
-- especially considering that we plan to stream everything from local files
function utils.DOWNLOADER.new(options, stream_file_name)
	local self = {}
	setmetatable(self, { __index = utils.DOWNLOADER })
	
	self.thread, self.conn = require("cqueues.thread").start(
	function(conn, plex_token, stream_file_name, require_hostname_validation_str, verify_server_certificates_str)
	-- this is a whole new VM so it's a complete blank slate
	-- no globals, modules, upvalues or anything
	-- only the arguments of the thread function
		io.stdout:write("WOOHOO THREAD\n")
		local http_request = require("http.request")
		local cq = require("cqueues").new()
		
		io.stdout:write("FILE ", stream_file_name, "\n")
		local stream_file_handle = io.open(stream_file_name, "w")
		io.stdout:write("OPENED FILE\n")
		
		-- if we need to step around mismatched hostnames from the certificate
		local http_tls = require("http.tls")
		http_tls.has_hostname_validation = require_hostname_validation_str == "true"
		local ssl_context = http_tls.new_client_context()
		
		-- if we need to skip certificate validation
		if verify_server_certificates_str == "false" then
			ssl_context:setVerify(require("openssl.ssl.context").VERIFY_NONE)
		end
		
		cp:wrap(function()
		-- read request address from socket, download to file
			io.stdout:write("WOOHOO CQUEUE\n")
			local target = conn:read()
			io.stdout:write("DOWNLOADER: " .. target .. "\n")
			local request = http_request.new_from_uri()
			request.headers:append("x-plex-token", plex_token, true)
			request.ctx = ssl_context
			local headers, stream = request:go(10.0) -- 10 secs timeout
			if not headers then
				-- timeout or other network error of sorts
				rconn:write("Network error on API request " .. target .. ":\n" .. stream, "\n")
			end
			if headers:get(":status") == "200" then
				stream:save_body_to_file(stream_file_handle)
				conn:write("ok")
			elseif headers:get(":status") == "401" then
				conn:write("API request " .. target .. " returned error 401: unauthorized.\nYour token may have expired, consider logging in again by passing --login.", "\n")
			else
				conn:write("API request " .. target .. " returned error " .. headers:get(":status") .. ".", "\n")
			end
		end)
		io.stdout:write("WOOHOO ABOUT TO LOOP\n")
		assert(cp:loop())
		io.stdout:write("WOOHOO LOOPED\n")
	end, options.plex_token, stream_file_name, tostring(require_hostname_validation), tostring(verify_server_certificates_str)
	)

	return self
end


function utils.DOWNLOADER:get(target)
	io.stdout:write("DOWNLOADER:get ".. target, "\n")
	self.conn:write(target, "\n")
end

function utils.DOWNLOADER:get_result()
	return self.conn:read()
end

-- NOTA BENE: for the moment, this code is all duplicated
-- hopefully, we'll eventually be able to use a downloader instance for all our requests
-- especially considering that we plan to stream everything from local files
function utils.DOWNLOADER.new(options, stream_file_name)
	local self = {}
	setmetatable(self, { __index = utils.DOWNLOADER })
	
	self.thread, self.conn = require("cqueues.thread").start(
	function(conn, plex_token, stream_file_name, require_hostname_validation_str, verify_server_certificates_str)
	-- this is a whole new VM so it's a complete blank slate
	-- no globals, modules, upvalues or anything
	-- only the arguments of the thread function
		io.stdout:write("WOOHOO THREAD\n")
		local http_request = require("http.request")
		local cq = require("cqueues").new()
		
		io.stdout:write("FILE ", stream_file_name, "\n")
		local stream_file_handle = io.open(stream_file_name, "w")
		io.stdout:write("OPENED FILE\n")
		
		-- if we need to step around mismatched hostnames from the certificate
		local http_tls = require("http.tls")
		http_tls.has_hostname_validation = require_hostname_validation_str == "true"
		local ssl_context = http_tls.new_client_context()
		
		-- if we need to skip certificate validation
		if verify_server_certificates_str == "false" then
			ssl_context:setVerify(require("openssl.ssl.context").VERIFY_NONE)
		end
		
		cq:wrap(function()
		-- read request address from socket, download to file
			io.stdout:write("WOOHOO CQUEUE\n")
			for target in conn:lines() do
				io.stdout:write("DOWNLOADER: " .. target .. "\n")
				local request = http_request.new_from_uri(target)
				request.headers:append("x-plex-token", plex_token, true)
				request.ctx = ssl_context
				local headers, stream = request:go(10.0) -- 10 secs timeout
				if not headers then
					-- timeout or other network error of sorts
					rconn:write("Network error on API request " .. target .. ":\n" .. stream, "\n")
				end
				if headers:get(":status") == "200" then
					conn:write("ok\n")
					stream:save_body_to_file(stream_file_handle)
					conn:write("done\n")
				elseif headers:get(":status") == "401" then
					conn:write("API request " .. target .. " returned error 401: unauthorized.\nYour token may have expired, consider logging in again by passing --login.", "\n")
				else
					conn:write("API request " .. target .. " returned error " .. headers:get(":status") .. ".", "\n")
				end
			end
		end)
		io.stdout:write("WOOHOO ABOUT TO LOOP\n")
		assert(cq:loop())
		io.stdout:write("WOOHOO LOOPED\n")
	end, options.plex_token, stream_file_name, tostring(require_hostname_validation), tostring(verify_server_certificates_str)
	)

	return self
end


function utils.DOWNLOADER:get(target)
	io.stdout:write("DOWNLOADER:get ".. target, "\n")
	self.conn:write(target, "\n")
end

function utils.DOWNLOADER:get_result(timeout)
	return self.conn:read()
--	return self.conn:xread("*l", "tlap", timeout)
end
-- =====================================

return utils