-- main.lua

local anthropic2 = require("anthropic2")
local readline = require("readline")
local uuid = require('uuid')
local lfs = require('lfs')
local clog = require('clog')

local session_history = {}

local log_file = nil

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

	local c = clog.create()

	if not c:open(fn) then
		return nil
	end
	return c
end

local function run_input(input)
	local messages = {
	    { role = "user", content = input },
	}

	local stream = anthropic2.stream_messages(messages)
	local state = anthropic2.get_init_state()
	-- I'm assuming here the response is completely read in a call
	-- to run_input().  If this isn't the case then we'll need an
	-- alternate way to track the session history here.
	--
	local response = ""

	for line in stream:each_chunk() do
		for single_line in (line .. "\n"):gmatch("([^\n]*)\n") do
			anthropic2.parse_sse_line(single_line, state)

			-- State now contains whatever partial or full
			-- output needs to be handled, either by being
			-- output/logged, or to call a tool.
			if state.response_set == true then
				response = response .. state.response_text
				io.write(state.response_text)
				state.response_text = nil
				state.response_set = false
			end

			if state.needs_tool == true then
				print("[ERROR] Tool request but not yet implemented!")
			end

			if state.done then break end
		end
		if state.done then break end
	end
	table.insert(session_history, { role = "assistant", content = response })
	log_file:write_json({ block = "response", content = response })
	log_file:write_json({ block = "stats", input_tokens = state.input_tokens, output_tokens = state.output_tokens })
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

	-- Sigh, global since this isn't a class and we need it in other functions
	log_file = open_log_file(session_uuid)

	log_file:write_json( { start_timestamp = 1234 } );

	while true do
		local input = readline.readline("> ")
		if input == nil then break end
		input = input:match("^%s*(.-)%s*$")
		if #input > 0 then
			readline.addhistory(input)
			table.insert(session_history, { role = "user", content = input })
			log_file:write_json({ block = "input", input_str = input })
--			readline.historysave(os.getenv("HOME") .. "/.claude_history")
--
--			-- TODO: log output / intermediary steps
			run_input(input)
		end
		log_file:flush()
		print("\n====\n")
	end

	log_file:close()

end

run()

