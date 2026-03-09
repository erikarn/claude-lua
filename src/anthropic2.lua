local http_request = require("http.request")
local json         = require("dkjson")

local API_KEY = os.getenv("ANTHROPIC_API_KEY"):gsub("%s+", "")

local M = {}

function M.stream_messages(messages, tools, opts)
    opts = opts or {}

    local payload = {
        model      = opts.model      or "claude-sonnet-4-20250514",
        max_tokens = opts.max_tokens or 1024,
        stream     = true,            -- enable SSE streaming
        messages   = messages,
	tools = tools,
    }
    if opts.system then payload.system = opts.system end

    local body = json.encode(payload)

--    print(string.format("[DEBUG] payload; %d bytes, %d entries\n", #body, #payload.messages))
--    print("[debug] request body: " .. body)

    -- build request
    local req = http_request.new_from_uri("https://api.anthropic.com/v1/messages")

    -- Force HTTP/1.1 for now; HTTP/2 is hanging when the body is greater
    -- than 1024 bytes and I'm not sure why just yet.
    req.version = 1.1

    req.headers:upsert(":method",          "POST")
    req.headers:upsert("content-type",     "application/json")
    req.headers:upsert("x-api-key",        API_KEY)
    req.headers:upsert("anthropic-version","2023-06-01")
    req.headers:upsert("accept",           "text/event-stream")
    req:set_body(body)

    local headers, stream, errno = req:go(30)  -- 30s timeout
    if not headers then
        error("request failed: " .. tostring(stream) .. "errno: " .. errno)
    end

    local status = tonumber(headers:get(":status"))
    if status ~= 200 then
        error("API error " .. status .. ": " .. stream:get_body_as_string())
    end

    return stream
end

-- SSE parser - Anthropic sends lines like:
--   event: content_block_delta
--   data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"hello"}}
--
--

function M.parse_sse_line(line, state)
    if line:match("^event:") then
        state.event = line:match("^event:%s*(.+)$")
--	print("[DEBUG] state.event = " .. state.event)

    elseif line:match("^data:") then
        local data_str = line:match("^data:%s*(.+)$")
--	print("[DEBUG] data: = " .. data_str)
        if data_str == "[DONE]" then state.done = true; return end

        local data, _, err = json.decode(data_str)
        if not data then
            io.stderr:write("JSON parse error: " .. tostring(err) .. "\n")
            return
        end

        if data.type == "message_start" then
            local msg = data.message
            state.message_id   = msg.id
            state.model        = msg.model
            state.input_tokens = msg.usage and msg.usage.input_tokens
	    state.done = false

        elseif data.type == "content_block_start" then
            state.current_index = data.index
            state.block_type    = data.content_block.type
	    -- if type == "text" then blank out the response text
	    if data.content_block.type == "text" then
		state.response_text = nil
		state.response_set = false
	    end
            -- if type == "tool_use", capture tool name:
            if data.content_block.type == "tool_use" then
                state.tool_name = data.content_block.name
                state.tool_id   = data.content_block.id
                state.tool_json = ""  -- accumulate input_json_delta chunks
            end

        elseif data.type == "content_block_delta" then
            local delta = data.delta
            if delta.type == "text_delta" then
		state.response_text = (state.response_text or "") .. delta.text
		state.response_set = true
            elseif delta.type == "input_json_delta" then
                -- accumulate tool input JSON
                state.tool_json = (state.tool_json or "") .. delta.partial_json
            end

        elseif data.type == "content_block_stop" then
            if state.block_type == "tool_use" and state.tool_json then
                -- tool input is now complete - parse and handle it
                local tool_input = json.decode(state.tool_json)
                state.pending_tool = {
                    id    = state.tool_id,
                    name  = state.tool_name,
                    input = tool_input,
                }
                state.tool_json = nil
            end

        elseif data.type == "message_delta" then
            state.stop_reason   = data.delta.stop_reason
            state.output_tokens = data.usage and data.usage.output_tokens
            if state.stop_reason == "tool_use" then
                state.needs_tool = true
            end

        elseif data.type == "message_stop" then
            state.done = true

        elseif data.type == "error" then
            io.stderr:write("stream error: " .. json.encode(data) .. "\n")
            state.done  = true
            state.error = data.error
        end

    elseif line == "" then
        state.event = nil
    end
end

function M.get_init_state()
	local state = {
	    done          = false,
	    event         = nil,
	    response_text = nil,
	    reponse_set   = false,
	    -- message metadata
	    message_id    = nil,
	    model         = nil,
	    input_tokens  = nil,
	    output_tokens = nil,
	    stop_reason   = nil,
	    -- content block tracking
	    current_index = nil,
	    block_type    = nil,
	    -- tool use
	    tool_name     = nil,
	    tool_id       = nil,
	    tool_json     = nil,
	    pending_tool  = nil,
	    needs_tool    = false,
	    -- error
	    error         = nil,
	}
	return state
end

return M
