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
local json = require('dkjson')
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
	m.tool_cache = {}
	m.response_callback = nil
	m.max_tokens = nil

	-- Current API call state; used for retrying
	m.current_state = {}
	m.current_state.input = nil
	m.current_state.tool_request_list = nil
	m.current_state.stop_reason = nil

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

-- Set maximum tokens for processing
--
function Actor:set_max_tokens(max_tokens)
	self.max_tokens = max_tokens
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

-- Add a message to the session history
--
-- This is persisted locally /and/ optionally written to the actor
-- state log so it can be replayed later.
function Actor:add_to_session_history(role, content)
	table.insert(self.session_history,
	    { role = "user", content = content })
end

-- Set the callback for receving payloads / responses from the run()
-- routine.
--
-- The run / run_input routines don't print anything; instead they return
-- tables with the response type / status.  The function itself will terminate
-- once it's finished its processing loop and/or requires some external
-- action.
--
-- Supported return values include:
--
-- { type = text, content = "text response" }
-- { type = tool_ui, name = <tool name>, content = "tool ui line" }
-- { type = state_done, stop_reason = "stop reason" }
-- { type = api_error, err_state = { code = <http code>, type = <error type> } }
-- { type = tokens, input_tokens = <input token count>, output_tokens = <output token count> }
--
-- If the function requires local state (eg it's an object) then please
-- pass in an anonymous function to wrap the self reference.
--
-- To clear the callback, call this with 'nil' as the function.
--
function Actor:set_callback(func)
	self.response_callback = func
end

--
-- Hand the output to the callback if it exists.
--
function Actor:output(out)
	if self.response_callback ~= nil then
		self.response_callback(out)
	end
end

-- old code from main.lua that needs to be cleaned up / rethought
-- as part of this mess.

--
-- Run the input, return a list of tools that need to be run and fed
-- back into the API.
--
-- Returns {true|false}, { stop_reason = stop_reason }
--
-- Defined stop_reason fields for errors - ideally processing logic only
-- needs to handle the known set of stop_reason values.
--
-- api_error - an API error; err_state contains response_code
--    (HTTP reponse code); err_type contains the error type from
--    the API code, and err_state includes any error state information
--    from the API call results itself.
--
-- api_rate_limit - the API call returned a 429 status error / rate limit;
--    the caller is responsible for retrying the API call with the same
--    payload after a delay.
--
-- max_tokens - the API call hit a token limit.  The request should be
--    continued either by retrying with a higher token limit and stripping
--    the last response, or by submitting the last response with a new
--    prompt such as "Please continue" to, well, encourage the model to
--    continue.
--
-- TODO: very specifically define the other outputs that can be returned here
-- and what the processing rules should be.
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
	local opts = {}

	if self.max_tokens ~= nil then
		opts.max_tokens = self.max_tokens
	end

	local stream, err_state = an_req:stream_messages(messages,
	    self.tool_list:get_tool_schema_list(), opts)
	if (stream == nil) then
		local es = {}
		if (err_state.content ~= nil) then
			es = json.decode(err_state.content)
		end
		-- Squirrel the HTTP reponse code in here too
		es.response_code = err_state.code
		es.err_type = err_state.type

		-- API error
		--
		self.log_file:dlog("conversation", err_state.content)

		-- This is for UI output, not for handling the actual error
		--
		self:output({ type = "api_error", err_state = es})

		if (err_state.code == 429 and es.type == "error"
		    and es.error.type == "rate_limit_error") then
			self:output({ type = "rate_limit_error", err_state = es})
			return false, { stop_reason = "api_rate_limit",
			    err_state = es }
		end

		self:output({ type = "api_error", err_state = es})
		return false, { stop_reason = "api_error", err_state = es }
	end

	local state = an_req:get_init_state()

	self:add_to_session_history("user", input_content)

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
				self:output({ type = "text",
				    content = state.response_text })
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
				self:output({ type = "state_done",
				    stop_reason = state.stop_reason })
			end
			if state.done then break end
::next_single_line::
		end
		if state.done then break end
	end

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

	self:add_to_session_history("assistant", content_list)

	self.log_file:write_json({ block = "response", content = response })
	self.log_file:write_json({ block = "stats", input_tokens = state.input_tokens, output_tokens = state.output_tokens })

	self:output({ type = "tokens",
	    input_tokens = state.input_tokens,
	    output_tokens = state.output_tokens })

	return true, { stop_reason = state.stop_reason }
end

--
-- Run the given tool list, return the tool list output to feed back
-- into the model as input.
--
-- Returns true, nil if successful
-- Returns false, err if unsuccessful
-- TODO: define the err table if unsuccessful
--
function Actor:run_tool_list(tool_request_list)
	local tl = {}

	self.log_file:dlog("tools",
	    "tool count: " .. #tool_request_list)
	for _, v in ipairs(tool_request_list) do
		self.log_file:dlog("tools", "tool name: " .. v.name)

		-- Check to see if we have a tool in the cache;
		-- if we do then use that instance otherwise create
		-- a new one.
		--
		if (self.tool_cache[v.name] == nil) then
			self.tool_cache[v.name] =
			    self.tool_list:lookup_and_create(v.name)
		end
		local tool = self.tool_cache[v.name]
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
--			print("created tool")
			self.log_file:dlog("tools", "tool request: " .. json.encode(v))
			self:output({ type = "tool_ui", name = v.name,
			    content = tool:get_ui_label(v).content })
			local tr = tool:run(v)
			-- populate common info
			tr.type = "tool_result"
			tr.tool_use_id = v.id
--			print("tool result:" .. tr.content)

			-- log
			self.log_file:dlog("tools", "tool response: " .. json.encode(tr))

			-- insert into the request/response flow
			table.insert(tl, tr)
		end
	end

	return tl, nil
end

-- Set the input and optionally the tool request list state
--
-- This will reset the API call state to the given input/tool request list
-- for subsequent calls to Actor:run() to run over.
--
-- TODO: this doesn't allow a tool response to be set as input,
-- I'll tackle that later.
--
function Actor:set_input(input, tool_request_list)

	self.log_file:write_json({ block = "input", input_str = self.current_state.input })

	self.current_state.input = { { type = "text", text = input } }
	if tool_request_list ~= nil then
		self.current_state.tool_request_list = tool_request_list
	else
		self.current_state.tool_request_list = {}
	end
	self.current_state.stop_reason = nil
end

--
-- API entry point to run the API/model over the given input.
--
-- The actor maintains conversion state, tooling config and other
-- history.  This call will take all of that, add the provided input
-- string, and send it to the API.  It will then iterate over
-- the API return results, handle tooling calls and such until it
-- reaches a point where it can't make forward progress on its own
-- and will return error/status to the caller.
--
-- TODO: the eventual goal is that the returned error/status doesn't
-- require API data to make decisions.  Eg if it's a temporary API
-- rate limit error, return that as an explicit error type, rather
-- than relying upon anthropics returned HTTP status code / return
-- error.  Similar for max tokens - don't return the max_tokens
-- return result from Anthropic, we need to return our own defined
-- error/status.
--
-- Return values are:
--
-- (success <true|false>), (status table)
--
-- 'success' defines whether the API call succeeded or not.
--
-- TODO: success and failure need defining here, especially
-- around whether user input needs to be provided, whether the
-- actor can be retried/restarted or some other error handling
-- is required, etc, etc.
--

function Actor:run()
--	-- TODO: log intermediary steps
	local r, retrun = self:run_input(self.current_state.input,
	    self.current_state.tool_request_list)
	self.current_state.stop_reason = retrun.stop_reason

	-- Error; kick to actor owner to handle
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
		return false, retrun
	end

	-- Back to normal comment/work flow

	-- If tool_request_list is not nil then we need to run the tool
	-- requests, populate a user request with the tool responses,
	-- and then send it over.
	-- 
	while (#self.current_state.tool_request_list > 0) do
		-- Run the tool list
		local tl = self:run_tool_list(self.current_state.tool_request_list)
		-- The tool list has completed, blank the tool list
		self.current_state.tool_request_list = {}
		self.current_state.input = tl

		-- Run another pass of the model with the input being
		-- the current tool results
		local r, retrun = self:run_input(self.current_state.input,
		    self.current_state.tool_request_list)
		self.current_state.stop_reason = retrun.stop_reason

		-- Permanent error; kick to actor owner to handle
		if r == false then
			return false, retrun
		end

		-- TODO max tokens again, see above, sigh
		--
		if retrun.stop_reason == "max_tokens" then
			return false, retrun
		end
	end

	return true, nil

end


return Actor
