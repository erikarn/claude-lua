
-- Logging library for logging everything currently being done here.
--

local json = require('dkjson')
local lfs = require('lfs')

Clog = {}
Clog.__index = Clog

-- Create a log instance
function Clog:create()
	local m = {}
	setmetatable(m, Clog)
	m.locals = {}
	return m
end

function Clog:open(fname)
	local f = io.open(fname, "a+")
	if not f then return nil end

	self.fh = f
	return true
end

function Clog:close()
	if not self.fh then
		return false
	end

	self.fh:flush()
	self.fh:close()
	self.fh = nil
	return true
end

function Clog:flush()
	if not self.fh then
		return false
	end

	self.fh:flush()
	return true
end

-- Write a raw string
--
-- This is primarily aimed for debugging; the goal here is to only
-- ever write json fields.
--
function Clog:write_raw_str(str)
	if not self.fh then
		return false
	end

	self.fh:write(str)
	return true
end

-- Write a json chunk out with a terminating ,\n
--
-- This represents the bulk of what we should be logging here.
--
-- TODO: add a timestamp?
--
function Clog:write_json(jt)
	local str = json.encode(jt)
	if not self.fh then
		return false
	end

	self.fh:write(str .. ",\n")
	return true
end

return Clog
