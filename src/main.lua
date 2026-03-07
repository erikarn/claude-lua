-- main.lua

local anthropic2 = require("anthropic2")

-- local messages = {
--     { role = "user", content = "Explain the FreeBSD jail system in one paragraph." }
-- }
-- 
-- local response, err = anthropic.messages(messages)
-- 
-- if not response then
--     io.stderr:write("Error: " .. tostring(err) .. "\n")
--     os.exit(1)
-- end
-- print(anthropic.get_text(response))
--

local function run()

	local messages = {
	    { role = "user", content = "Count slowly from 1 to 10, one number per line." }
	}

	local stream = anthropic2.stream_messages(messages)
	local state = { done = false, event = nil }

	for line in stream:each_chunk() do
		for single_line in (line .. "\n"):gmatch("([^\n]*)\n") do
			anthropic2.parse_sse_line(single_line, state)
			if state.done then break end
		end
		if state.done then break end
	end

end

run()

