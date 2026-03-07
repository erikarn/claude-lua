local http_request = require("http.request")
local json         = require("dkjson")

local API_KEY = os.getenv("ANTHROPIC_API_KEY"):gsub("%s+", "")

local M = {}

function M.stream_messages(messages, opts)
    opts = opts or {}

    local payload = {
        model      = opts.model      or "claude-sonnet-4-20250514",
        max_tokens = opts.max_tokens or 1024,
        stream     = true,            -- enable SSE streaming
        messages   = messages,
    }
    if opts.system then payload.system = opts.system end

    local body = json.encode(payload)

    -- build request
    local req = http_request.new_from_uri("https://api.anthropic.com/v1/messages")
    req.headers:upsert(":method",          "POST")
    req.headers:upsert("content-type",     "application/json")
    req.headers:upsert("x-api-key",        API_KEY)
    req.headers:upsert("anthropic-version","2023-06-01")
    req.headers:upsert("accept",           "text/event-stream")
    req:set_body(body)

    local headers, stream = req:go(30)  -- 30s timeout
    if not headers then
        error("request failed: " .. tostring(stream))
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
function M.parse_sse_line(line, state)
    if line:match("^event:") then
        state.event = line:match("^event:%s*(.+)$")

    elseif line:match("^data:") then
        local data_str = line:match("^data:%s*(.+)$")
        if data_str == "[DONE]" then
            state.done = true
            return
        end

        local data, _, err = json.decode(data_str)
        if not data then
            io.stderr:write("JSON parse error: " .. tostring(err) .. "\n")
            return
        end

        -- print text deltas as they arrive
        if data.type == "content_block_delta"
        and data.delta
        and data.delta.type == "text_delta" then
            io.write(data.delta.text)
            io.flush()  -- important - force output immediately

        elseif data.type == "message_stop" then
            state.done = true

        elseif data.type == "message_start" then
            -- contains model, usage info if you want it
            print("[debug] model: " .. tostring(data.message.model))

        elseif data.type == "error" then
            io.stderr:write("stream error: " .. json.encode(data) .. "\n")
            state.done = true
        end

    elseif line == "" then
        -- blank line = end of SSE event, reset event type
        state.event = nil
    end
end

return M
