
-- Weather tool with OpenWeatherMap integration
--

local json = require('dkjson')
local http_request = require('http.request')
local http_util = require('http.util')
local config = require('config')

Weather = {}
Weather.__index = Weather

-- Create a weather tool instance
function Weather:create()
	local m = {}
	setmetatable(m, Weather)
	m.locals = {}
	m.config = config:new()
	m.base_url = "https://api.openweathermap.org/data/2.5/weather"
	return m
end

function Weather:__close()
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

function Weather:get_properties()
	return {
		persistent = false
	}
end

function Weather:get_ui_label(req)
	return {
		content = "Weather lookup for: " .. req.input.location or "<missing>"
	}
end

-- Helper function to validate input
function Weather:validate_input(input)
	if not input then
		return false, "No input provided"
	end
	
	if type(input) ~= "table" then
		return false, "Input must be a table"
	end
	
	if not input.location then
		return false, "Location is required"
	end
	
	if type(input.location) ~= "string" then
		return false, "Location must be a string"
	end
	
	if string.len(input.location) == 0 then
		return false, "Location cannot be empty"
	end
	
	return true, nil
end

-- Helper function to format temperature
function Weather:format_temperature(temp_k)
	local temp_c = math.floor(temp_k - 273.15 + 0.5)  -- Convert Kelvin to Celsius and round
	local temp_f = math.floor((temp_k - 273.15) * 9/5 + 32 + 0.5)  -- Convert to Fahrenheit and round
	return string.format("%d°C (%d°F)", temp_c, temp_f)
end

-- Helper function to format wind direction
function Weather:format_wind_direction(degrees)
	if not degrees then return "unknown direction" end
	
	local directions = {
		"N", "NNE", "NE", "ENE",
		"E", "ESE", "SE", "SSE", 
		"S", "SSW", "SW", "WSW",
		"W", "WNW", "NW", "NNW"
	}
	
	local index = math.floor((degrees + 11.25) / 22.5) % 16 + 1
	return directions[index]
end

-- Helper function to make HTTP request to OpenWeatherMap
function Weather:fetch_weather_data(location)
	local api_key = self.config.config.keys.openweather_api

	if not api_key then
		return nil, "OpenWeatherMap API key not found. Please set the openweather_api key in the config file."
	end
	
	-- URL encode the location
	local encoded_location = http_util.encodeURIComponent(location)
	local url = string.format("%s?q=%s&appid=%s&units=metric", 
		self.base_url, encoded_location, api_key)
	
	-- Create HTTP request
	local req = http_request.new_from_uri(url)
	req.headers:upsert("user-agent", "claude-lua-weather-tool/1.0")
	
	-- Set timeout (30 seconds)
	local timeout = 30
	
	-- Make the request
	local headers, stream = req:go(timeout)
	if not headers then
		return nil, "Failed to connect to OpenWeatherMap API"
	end
	
	-- Check HTTP status
	local status = headers:get(":status")
	if not status or status ~= "200" then
		-- Try to get error message from response body
		local body, err = stream:get_body_as_string(5)  -- 5 second timeout for body
		if body then
			local ok, error_data = pcall(json.decode, body)
			if ok and error_data and error_data.message then
				return nil, string.format("OpenWeatherMap API error (%s): %s", status or "unknown", error_data.message)
			end
		end
		return nil, string.format("OpenWeatherMap API returned status %s", status or "unknown")
	end
	
	-- Read response body
	local body, err = stream:get_body_as_string(10)  -- 10 second timeout for body
	if not body then
		return nil, "Failed to read response from OpenWeatherMap API: " .. (err or "unknown error")
	end
	
	-- Parse JSON response
	local weather_data, pos, parse_err = json.decode(body)
	if not weather_data then
		return nil, "Failed to parse weather data: " .. (parse_err or "invalid JSON")
	end
	
	return weather_data, nil
end

-- Helper function to format weather response
function Weather:format_weather_response(weather_data)
	local location_name = weather_data.name
	if weather_data.sys and weather_data.sys.country then
		location_name = location_name .. ", " .. weather_data.sys.country
	end
	
	-- Temperature
	local temperature = "unknown"
	if weather_data.main and weather_data.main.temp then
		local temp_c = math.floor(weather_data.main.temp + 0.5)
		local temp_f = math.floor(weather_data.main.temp * 9/5 + 32 + 0.5)
		temperature = string.format("%d°C (%d°F)", temp_c, temp_f)
	end
	
	-- Weather condition
	local condition = "unknown conditions"
	if weather_data.weather and weather_data.weather[1] then
		condition = weather_data.weather[1].description
		-- Capitalize first letter
		condition = string.upper(string.sub(condition, 1, 1)) .. string.sub(condition, 2)
	end
	
	-- Humidity
	local humidity_str = ""
	if weather_data.main and weather_data.main.humidity then
		humidity_str = string.format(", Humidity: %d%%", weather_data.main.humidity)
	end
	
	-- Wind
	local wind_str = ""
	if weather_data.wind then
		local wind_speed = weather_data.wind.speed or 0
		local wind_speed_kmh = math.floor(wind_speed * 3.6 + 0.5)  -- Convert m/s to km/h
		
		if weather_data.wind.deg then
			local wind_dir = self:format_wind_direction(weather_data.wind.deg)
			wind_str = string.format(", Wind: %d km/h %s", wind_speed_kmh, wind_dir)
		else
			wind_str = string.format(", Wind: %d km/h", wind_speed_kmh)
		end
	end
	
	-- Feels like temperature
	local feels_like_str = ""
	if weather_data.main and weather_data.main.feels_like then
		local feels_like_c = math.floor(weather_data.main.feels_like + 0.5)
		local feels_like_f = math.floor(weather_data.main.feels_like * 9/5 + 32 + 0.5)
		feels_like_str = string.format(", Feels like: %d°C (%d°F)", feels_like_c, feels_like_f)
	end
	
	return string.format("Weather in %s: %s, %s%s%s%s", 
		location_name, temperature, condition, humidity_str, wind_str, feels_like_str)
end

-- Return a valid response content block for the given input
function Weather:run(req)
	local input = req.input

	-- Validate input
	local valid, error_msg = self:validate_input(input)
	if not valid then
		return {
			content = "Error: " .. error_msg
		}
	end
	
	-- Fetch weather data
	local weather_data, fetch_error = self:fetch_weather_data(input.location)
	if not weather_data then
		return {
			content = "Unable to get weather data: " .. fetch_error
		}
	end
	
	-- Format and return response
	local formatted_response = self:format_weather_response(weather_data)
	return {
		content = formatted_response
	}
end

return Weather
