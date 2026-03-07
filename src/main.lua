-- main.lua

local anthropic2 = require("anthropic2")
local readline = require("readline")

-- readline.historyload(os.getenv("HOME") .. "/.claude_history")
-- readline.historysetmaxlen(1000)

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

local function run_input(input)
	local messages = {
	    { role = "user", content = input },
	}

	local stream = anthropic2.stream_messages(messages)
	local state = anthropic2.get_init_state()

	for line in stream:each_chunk() do
		for single_line in (line .. "\n"):gmatch("([^\n]*)\n") do
			anthropic2.parse_sse_line(single_line, state)
			if state.done then break end
		end
		if state.done then break end
	end
end

local function run()

	while true do
		local input = readline.readline("> ")
		if input == nil then break end
		input = input:match("^%s*(.-)%s*$")
		if #input > 0 then
			readline.addhistory(input)
--			readline.historysave(os.getenv("HOME") .. "/.claude_history")
			run_input(input)
		end
		print("\n====\n")
	end

end

run()

