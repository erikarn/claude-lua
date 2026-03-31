-- actor.lua
--
-- An "actor" is what I'm calling an instance that does work.
-- (I wanted to call it worker, but that tends to be an overused term.)
--
-- This contains everything one needs to interact with the
-- API - conversation state, tool config/usage/state, some shared
-- information like initial context/prompt, etc.
--
-- It runs the state machine based on input request calls, makes
-- its own function calls to provide incremental state information
-- (thinking output, interactive output, questions, etc).
--
-- One of the goals of this agent is to make the main loop / agent
-- object (when that's written) not deal with the API directly.
-- It creates an actor, it loads in new or existing state, and then
-- it can continue where it left off if needed.
--

local anthropic = require("anthropic")
local uuid = require('uuid')
local lfs = require('lfs')
local clog = require('clog')
local json = require('dkjson')
local tools = require('tools')
local config = require('config')

-- Class table
--
local Actor = {
}
Actor.__index = Actor

-- Constructor
--

function Actor:new(opts)
	local m = {}
	setmetatable(m, Actor)
	m.local_config = {}
	m.config = config:new()

	-- TODO: migrate DEFAULTS to just use the Config object

	if opts then
		for k, v in pairs(opts) do m.local_config[k] = v end
	end

	-- This will override the configured key
	m.session_history = {}
	m.api_key = nil
	m.actor_uuid = ""
	m.system_prompt = ""
	m.log_file = nil
	m.tool_list = nil

	-- TODO: there's likely a lot more interesting API state
	-- the claude API can implement; I'll need to tinker with
	-- that once this is stood up.
	--
	return m
end

-- Explicitly set the anthropic API key
--
function Actor:set_api_key(key)
	self.api_key = key
end

function Actor:get_api_key()
	if self.api_key ~= nil then
		return self.api_key
	end

	return self.config.config.keys.anthropic_api
end

-- Explicitly set the tool list
--
-- For now this is the full list of tools.  The tool list is provided
-- on each call to the API, so we do have the ability to customise the
-- tool list based on what the current ask is.
--
function Actor:set_tool_list(tool_list)
	self.tool_list = tool_list
end

-- Explicitly set the actor uuid
--
-- The actor uuid is used for storing and retrieving the current
-- actor state so it can be restartable between object instances
-- (eg if it's run in separate processes.)

function Actor:set_actor_uuid(uuid)
	self.actor_uuid = uuid
end

-- Explicitly set the initial system prompt.
--
-- This is passed into the Anthropic API as the system field, rather
-- than initial context passed in as the message list.
--

function Actor:set_system_prompt(prompt)
	self.system_prompt = system_prompt
end

-- Set the clog log_file object
--
-- I haven't yet decided whether this should be a singleton that's shared
-- everywhere; will tinker with the logging stuff once this class is used.
--
function Actor:set_log(log_file)
	self.log_file = log_file
end

-- Explicitly set the initial context.
--
-- The context is stored separately from the conversation; it'll be
-- prepended to the messages API being sent before the conversation
-- itself.
--

-- Run an input line from the user/controller.
--
-- Returns {true|false}, { stop_reason = stop_reason }
--

-- old code from main.lua that needs to be cleaned up / rethought
-- as part of this mess.

--
-- Run the input, return a list of tools that need to be run and fed
-- back into the API.
--
-- Returns {true|false}, { stop_reason = stop_reason }
--
function Actor:run_input(input_content, tool_request_list)
	-- Assemble the messages with the history
	local messages = {}

	-- This for now hard-codes the content as being text.
	-- I think the API lets me provide other content sources
	-- from the user such as tool_result, text, image, etc.
	-- I'll tackle that later.
	--
	for i, e in ipairs(self.session_history) do
		self.log_file:dprint("history",
		    "i: " .. tostring(i) .. " e: " .. json.encode(e))
		table.insert(messages, e)
	end

	table.insert(messages, { role = "user", content = input_content})

	-- XXX TODO: this is very spammy; we likely should persist this somewhere
	-- separate to be able to restart things.
	--
	-- self.log_file:dlog("conversation", json.encode(messages))

	local an_req = anthropic.create()
	an_req:set_api_key(self.api_key)
	an_req:set_log(self.log_file)
::retry::
	local stream, err_state = an_req:stream_messages(messages,
	    self.tool_list:get_tool_schema_list(), nil)
	if (stream == nil) then
		local es = json.decode(err_state.content)
		-- Squirrel the HTTP reponse code in here too
		es.response_code = err_state.code

		-- API error
		-- XXX TODO: log!
		-- XXX TODO: return some action!
		--
		self.log_file:dlog("conversation", err_state.content)

		-- Don't uncomment this until the callers of this routine
		-- handle the HTTP API errors in a suitable way (eg by moving
		-- the retry into the caller, not here).
		--
--		return false, { stop_reason = "api", err_state = es }

		print("[ERROR] code=" .. tostring(err_state.code))
		print("[ERROR] payload=" .. err_state.content)
		print("[ERROR] type='" .. es.type .. "'")
		print("[ERROR] error.type=" .. es.error.type)
		if (err_state.code == 429 and es.type == "error"
		    and es.error.type == "rate_limit_error") then
			-- sigh, lua
			print("[ERROR] Sleeping for 30 seconds and retrying..")
			os.execute('sleep 30')
			goto retry
		end
		return false, { stop_reason = "api", err_state = es }
	end

	local state = an_req:get_init_state()

	table.insert(self.session_history, { role = "user", content = input_content })

	-- I'm assuming here the response is completely read in a call
	-- to run_input().  If this isn't the case then we'll need an
	-- alternate way to track the session history here.
	--
	local response = ""

	for line in stream:each_chunk() do
		for single_line in (line .. "\n"):gmatch("([^\n]*)\n") do
			if single_line == "\n" then goto next_single_line end
			if single_line == "" then goto next_single_line end
			self.log_file:dprint("input_line", single_line)
			an_req:parse_sse_line(single_line, state)

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
			--
			if state.done == true and state.needs_tool == true then
				self.log_file:dlog("tools", "tool request: " .. json.encode(state.pending_tool))
				-- do a full copy
				local tool_req = {
					id = state.pending_tool.id,
					name = state.pending_tool.name,
					input = state.pending_tool.input,
				}
				table.insert(tool_request_list, tool_req)
			end

			--
			-- If we get state.done, at least log why to the console
			-- so I can see what's going on here.  There's going to be a bunch
			-- of things I need to handle and turn around, like pause_turn,
			-- max_tokens, model_context_window_exceeded, etc.
			--
			if state.done == true then
				-- TODO: this really needs to be communicated back better
				print("\n[STATE] done, stop_reason: " .. state.stop_reason .. "\n")
			end
			if state.done then break end
::next_single_line::
		end
		if state.done then break end
	end
	print("\n")

	-- This gets messy, because if a tool (or more than one tool is requested)
	-- then the conversation history needs to include it all.
	--
	local content_list = {}
	if (response ~= nil and response ~= "") then
		table.insert(content_list, { type = "text", text = response })
	end

	-- And now insert the tool invocation history
	for _, v in ipairs(tool_request_list) do
		table.insert(content_list,
		    { type = "tool_use", id = v.id, name = v.name, input = v.input })
	end

	table.insert(self.session_history, { role = "assistant", content = content_list })

	self.log_file:write_json({ block = "response", content = response })
	self.log_file:write_json({ block = "stats", input_tokens = state.input_tokens, output_tokens = state.output_tokens })
	print(string.format("[tokens] %d input tokens, %d output tokens\n", state.input_tokens, state.output_tokens))

	return true, { stop_reason = state.stop_reason }
end

function Actor:run(input)

	local tool_request_list = { }

	self.log_file:write_json({ block = "input", input_str = input })
--	-- TODO: log intermediary steps
	local r, retrun = self:run_input({ { type = "text", text = input } },
	    tool_request_list)

	-- TODO: handle HTTP errors, retry, etc

	-- Permanent error
	--
	if r == false then
		return r, retrun
	end

	-- TODO: if we get max_tokens then we'll need to append
	-- a user line like "please continue", bump up the token limit and
	-- resubmit for more work.
	--
	-- This can be easily hit by using the 1024 token default
	--
	if retrun.stop_reason == "max_tokens" then
	end

	-- If tool_request_list is not nil then we need to run the tool
	-- requests, populate a user request with the tool responses,
	-- and then send it over.
	-- 
	while (#tool_request_list > 0) do
		local tl = {}
		self.log_file:dlog("tools",
		    "tool count: " .. #tool_request_list)
		for _, v in ipairs(tool_request_list) do
			self.log_file:dlog("tools", "tool name: " .. v.name)
			local tool <close> = self.tool_list:lookup_and_create(v.name)
			if tool == nil then
				-- TODO: maybe make this an error print/log?
				self.log_file:dlog("tools", "tool lookup failed")
				table.insert(tl, {
					type = "tool_result",
					tool_use_id = v.id,
					is_error = true,
					content = "The requested tool doesn't exist!",
				});
			else
--				print("created tool")
				self.log_file:dlog("tools", "tool request: " .. json.encode(v))
				print("[TOOL] [" .. v.name .. "] " .. tool:get_ui_label(v).content .. "\n")
				local tr = tool:run(v)
				-- populate common info
				tr.type = "tool_result"
				tr.tool_use_id = v.id
--				print("tool result:" .. tr.content)

				-- log
				self.log_file:dlog("tools", "tool response: " .. json.encode(tr))

				-- insert into the request/response flow
				table.insert(tl, tr)
			end
		end

		tool_request_list = {}

		local r, retrun = self:run_input(tl, tool_request_list)

		-- TODO: handle HTTP errors, retry, etc

		-- Perm failure? break
		if r == false then
			return false, retrun
		end

		-- TODO max tokens again, see above, sigh
		--
		if retrun.stop_reason == "max_tokens" then
		end
	end

	return true, nil

end


return Actor
