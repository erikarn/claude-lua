-- main.lua

local anthropic2 = require("anthropic2")
local readline = require("readline")
local uuid = require('uuid')
local lfs = require('lfs')

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

local function open_log_file(session_uuid)
	local bn = os.getenv("HOME") .. "/.claude_cli"
	local dn = bn .. "/" .. session_uuid
	local fn = dn .. "/" .. "session.txt"

	lfs.mkdir(bn)
	lfs.mkdir(dn)

	local file = io.open(fn, "a+")
	return file
end

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

local function set_rng_fn()
	local bytes = {}
	for i = 1, 16 do
		bytes[i] = string.char(math.random(0,255))
	end
	return table.concat(bytes)
end

local function run()

	uuid.set_rng(set_rng_fn)
	local session_uuid = uuid()
	print("Session: " .. session_uuid)

	local log_file = open_log_file(session_uuid)

	while true do
		local input = readline.readline("> ")
		if input == nil then break end
		input = input:match("^%s*(.-)%s*$")
		if #input > 0 then
			readline.addhistory(input)
			log_file:write("\n==\n")
			log_file:write("INPUT:" .. input .. "\n==\n")
--			readline.historysave(os.getenv("HOME") .. "/.claude_history")
--
--			-- TODO: log output
			run_input(input)
		end
		log_file:flush()
		print("\n====\n")
	end

	log_file:close()

end

run()

