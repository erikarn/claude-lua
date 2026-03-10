
-- Example weather tool
--

local json = require('dkjson')

Weather = {}
Weather.__index = Weather

-- Create a log instance
function Weather:create()
	local m = {}
	setmetatable(m, Weather)
	m.locals = {}
	return m
end

function Weather:get_schema()
	return {
		name = "get_weather",
		description = "Get the current weather in a given location",
		input_schema = {
			type = "object",
			properties = {
				location = {
					type = "string",
					description = "The city and state, eg San Francisco, CA",
				},
			},
			required = { "location" }
		},
	}
end

-- Return a valid response content block for the given input
--
function Weather:run(input)

	local tool_id = nil

	-- TODO: actually do a weather lookup somehow!

	return {
		type = "tool_result",
		tool_use_id = input.id,
		content = "15 degrees C, and this is a test reponse!"
	}
end

return Weather
