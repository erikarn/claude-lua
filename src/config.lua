-- Class to represent configuration related stuff
--
-- For now this is a singleton.

local json = require("dkjson")

local Config = {}
Config.__index = Config

function Config:new(opts)
	if not Config._instance then
		local m = {}
		Config._instance = setmetatable(m, self)
	end
	return Config._instance
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

return Config:new()
