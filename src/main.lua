-- main.lua

local anthropic2 = require("anthropic2")
local readline = require("readline")
local uuid = require('uuid')
local lfs = require('lfs')
local clog = require('clog')
local json = require('dkjson')

local session_history = {}

local log_file = nil

-- TODO: we're statically using this for now,
-- soon we'll want to register tools and then have a way to
-- populate the tool requests and handle responses
-- and route them correctly.
--
local weather = require('tools/weather')
local weather_inst = weather:create()

function generate_tool_list()
	local tl = {}
	table.insert(tl, weather_inst:get_schema())
	return tl
end

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

--
-- Run the input, return a list of tools that need to be run and fed
-- back into the API.
--
local function run_input(input_content, tool_request_list)
	-- Assemble the messages with the history
	local messages = {}

	-- This for now hard-codes the content as being text.
	-- I think the API lets me provide other content sources
	-- from the user such as tool_result, text, image, etc.
	-- I'll tackle that later.
	--
	for i, e in ipairs(session_history) do
		print("[DEBUG] [HISTORY] i: " .. tostring(i) .. " e: " .. require("dkjson").encode(e))
		table.insert(messages, e)
	end

	table.insert(messages, { role = "user", content = input_content})

	local tool_list = generate_tool_list()
	local stream = anthropic2.stream_messages(messages, tool_list, nil)
	local state = anthropic2.get_init_state()

	table.insert(session_history, { role = "user", content = input_content })

	-- I'm assuming here the response is completely read in a call
	-- to run_input().  If this isn't the case then we'll need an
	-- alternate way to track the session history here.
	--
	local response = ""

	for line in stream:each_chunk() do
		for single_line in (line .. "\n"):gmatch("([^\n]*)\n") do
			if single_line == "\n" then goto next_single_line end
			if single_line == "" then goto next_single_line end
--			print("[DEBUG] line: " .. single_line)
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

			--
			-- Fire off the tool request to populate in the output stream.
			if state.done == true and state.needs_tool == true then
				print("[ERROR] Tool request but not yet implemented!")
				print("[DEBUG] tool request: " .. json.encode(state.pending_tool))
				-- do a full copy
				local tool_req = {
					id = state.pending_tool.id,
					name = state.pending_tool.name,
					input = state.pending_tool.input,
				}
				table.insert(tool_request_list, tool_req)
			end
			if state.done then break end
::next_single_line::
		end
		if state.done then break end
	end
	print("\n")

	-- This gets messy, because if a tool (or more than one tool is requested)
	-- then the conversation history needs to include it all.
	local content_list = {}
	table.insert(content_list, { type = "text", text = response })

	-- And now insert the tool invocation history
	for _, v in ipairs(tool_request_list) do
		table.insert(content_list,
		    { type = "tool_use", id = v.id, name = v.name, input = v.input })
	end

	table.insert(session_history, { role = "assistant", content = content_list })

	-- TODO: now some tool invocations will need to happen; likely done by the caller
	-- if we have a way to populate that.
	--
	--
	-- TODO: this has to happen as part of a queued user request back TO the API, and not
	-- merely handled here.
	--
	-- So, this won't work as-is; I'm going to need to return the tool request up to
	-- the caller so it can run the tool(s), populate the responses and then submit
	-- its own request to the API to continue.
--	if (#tool_request_list > 0) then
--		local tmp_tool_resp_list = {}
--		for _, v in ipairs(tool_request_list) do
--			table.insert(tmp_tool_resp_list,
--			    { type = "tool_result", tool_use_id = v.id, is_error = true, content = "Unimplemented for now!" })
--		end
--		table.insert(session_history, { role = "user", content = tmp_tool_request_list})
--	end

	log_file:write_json({ block = "response", content = response })
	log_file:write_json({ block = "stats", input_tokens = state.input_tokens, output_tokens = state.output_tokens })
	print(string.format("[tokens] %d input tokens, %d output tokens\n", state.input_tokens, state.output_tokens))
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
			local tool_request_list = { }

			readline.addhistory(input)
			log_file:write_json({ block = "input", input_str = input })
--			readline.historysave(os.getenv("HOME") .. "/.claude_history")
--			-- TODO: log intermediary steps
			run_input({ { type = "text", text = input } }, tool_request_list)

			-- If tool_request_list is not nil then we need to run the tool requests,
			-- populate a user request with the tool responses, and then send it over.
			while (#tool_request_list > 0) do
				local tl = {}
				print("[DEBUG] tool count: " .. #tool_request_list)
				for _, v in ipairs(tool_request_list) do
					table.insert(tl, {
						type = "tool_result",
						tool_use_id = v.id,
						is_error = true,
						content = "This isn't yet implemented!",
					});
				end

				tool_request_list = {}

				run_input(tl, tool_request_list)
			end

		end
		log_file:flush()
		print("====\n")
	end

	log_file:close()

end

run()

