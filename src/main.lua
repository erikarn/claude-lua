-- main.lua

local anthropic = require("anthropic")
local readline = require("readline")
local uuid = require('uuid')
local lfs = require('lfs')
local clog = require('clog')
local json = require('dkjson')
local tools = require('tools')
local config = require('config')
local actor = require('actor')

-- Load configuration info early
--
Config = config:new()
Config:load(os.getenv("HOME") .. "/.claude_cli/conf.json")

-- Create tool list early
--
local tool_list = tools.create()

-- XXX god damnit I should have the tool announce its name too
tool_list:register("get_weather", require('tools/weather'))
tool_list:register("str_replace_based_edit_tool", require('tools/text_editor'))
tool_list:register("bash", require('tools/bash'))

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

local function set_rng_fn()
	local bytes = {}
	for i = 1, 16 do
		bytes[i] = string.char(math.random(0,255))
	end
	return table.concat(bytes)
end

local function local_output(out)
	if (out.type == "text") then
		io.write(out.content)
	elseif (out.type == "tool_ui") then
		-- Yes, it'd be nice if we could handle this as an overlay and
		-- not trash partially written output.
		print("\n[TOOL] " .. out.content)
	elseif (out.type == "tokens") then
		print(string.format("[TOKENS] input tokens = %d, output tokens = %d\n",
		    out.input_tokens, out.output_tokens))
	elseif (out.type == "state_done") then
		-- TODO: this is not REALLY needed; the caller will get it
		-- as part of the return and handle it appropriately
		print(string.format("\n[done] reason = %s, type = %s\n",
		    out.stop_reason, out.type))
	else
		print(string.format("[unknown type = '%s']: %s\n",
		    out.type, json.encode(out)))
	end
end

local function run()

	-- Create a new actor; will configure the various parameters afterwards
	--
	local a = actor.new()

	-- Initialise the session information with a random uuid; later on I'll
	-- establish a way to continue a global session / actor session.
	--
	uuid.set_rng(set_rng_fn)
	local session_uuid = uuid()
	print("Session: " .. session_uuid)

	-- For now actor uuid == session uuid; remember at some point I
	-- want to be able to have multiple actors (dynamic, static) be
	-- available per session and have them the session / actors
	-- restartable.
	--
	a:set_actor_uuid(session_uuid)

	-- Set the global tool list
	a:set_tool_list(tool_list)

	a:set_api_key(Config.config.keys.anthropic_api)

	-- Set an output callback to capture the output for printing
	a:set_callback(local_output)

	-- Sigh, global since this isn't a class and we need it in other
	-- functions
	--
	log_file = open_log_file(session_uuid)
--	log_file:debug_section("tools", true)

	-- XXX TODO: write a real timestamp
	log_file:write_json( { start_timestamp = 1234 } );

	-- Set the log object
	a:set_log(log_file)

	while true do
		local input = readline.readline("> ")
		if input == nil then break end
		input = input:match("^%s*(.-)%s*$")
		if #input > 0 then
::try_again::
			-- TODO: we should have callbacks for the
			-- output data, right? rather than having it
			-- print?
			local ret, err = a:run(input)

			-- We hit a stop reason that requires handling
			-- versus just end of input.
			-- TODO: figure out what to do for each of them
			-- here!
			--
			if ret == false then
				-- max token handling
				if err.stop_reason == "max_tokens" then
					-- For now just bump token limit and
					-- submit a new request. I think the
					-- next thing to do here is to allow
					-- passing in some opts in each call to
					-- run() so I can control this stuff per
					-- invocation.
					--
					print("[TOKENS] hit max tokens; bumping to 64k for now\n")
					a:set_max_tokens(64000)
					input = "Please continue."
					goto try_again
				end

				-- API error handling - request timeout
				if err.stop_reason == "api_error"
				    and err.err_state.err_type == "request_timeout" then
					print("[ERROR] API error; request timeout, retrying\n")
					os.execute("sleep 5")
					goto try_again
				end

				-- TODO: API error handling
				if err.stop_reason == "api_error" then
					print("[ERROR] API error; bailing\n")
					print("*** stop reason: " .. json.encode(err))
					break
				end

				-- TODO: API rate limit handling
				if err.stop_reason == "api_rate_limit" then
					print("[ERROR] rate limited, sleeping 30 seconds\n")
					os.execute("sleep 5")
					goto try_again
				end

				-- TODO: API specifically hitting iteration
				-- limit and wanting a continuation (similar
				-- to hitting "max_tokens" above.)

				print("*** stop reason: " .. json.encode(err))
				break
			end
		end
		log_file:flush()
		print("====\n")
	end

	log_file:close()
end

run()

