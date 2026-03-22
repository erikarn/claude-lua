-- Class to represent configuration related stuff
--

local json = require("dkjson")

local Config = {}
Config.__index = Config

function Config:create(opts)
	local m = {}
	setmetatable(m, Config)
	m.config = {}
	return m
end

-- Load the given configuration file into the config array
--
function Config:load(fn)
	local f, err = io.open(fn, "r")
	if not f then
		return false, err
	end

	local cc = f:read("*a")
	f:close()

	local c, pos, err = json.decode(cc)
	if err then
		return false, err
	end

	self.config = c

	return true
end

return Config
