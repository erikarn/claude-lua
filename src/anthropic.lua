-- anthropic.lua
-- Minimal Anthropic API client for Lua 5.4

local socket = require("socket")
local ssl    = require("ssl")
local json   = require("dkjson")

local M = {}

-- ── configuration ────────────────────────────────────────────────────────────

M.config = {
    api_key = os.getenv("ANTHROPIC_API_KEY"),
    model   = "claude-sonnet-4-20250514",
    host    = "api.anthropic.com",
    port    = 443,
    version = "2023-06-01",
}

-- ── TLS socket helper ─────────────────────────────────────────────────────────

local function make_tls_socket(host, port)
    local sock, err = socket.tcp()
    if not sock then return nil, err end

    sock:settimeout(30)

    local ok, err = sock:connect(host, port)
    if not ok then return nil, "connect failed: " .. tostring(err) end

    print("[debug] luasec version: " .. tostring(ssl._VERSION))

    local params = {
	mode = "client",
	protocol = "any",
	verify = "peer",
        -- cafile  = "/etc/ssl/cert.pem",  -- FreeBSD default CA bundle
	cafile = "/usr/local/share/certs/ca-root-nss.crt",
    }

    -- wrap in TLS
    local tls_sock, err = ssl.wrap(sock, params)
    if not tls_sock then return nil, "ssl.wrap failed: " .. tostring(err) end

    tls_sock:sni("api.anthropic.com")

    local ok, err = tls_sock:dohandshake()
    if not ok then return nil, "handshake failed: " .. tostring(err) end

    return tls_sock
end


-- ── raw HTTP/1.1 request ──────────────────────────────────────────────────────

local function decode_chunked(body)
    local result = {}
    local pos = 1
    while pos <= #body do
        -- find end of chunk size line
        local size_end = body:find("\r\n", pos, true)
        if not size_end then break end
        
        local size_str = body:sub(pos, size_end - 1)
        -- strip chunk extensions if any
        size_str = size_str:match("^%x+")
        local chunk_size = tonumber(size_str, 16)
        
        if not chunk_size or chunk_size == 0 then break end
        
        local chunk_start = size_end + 2
        local chunk_end   = chunk_start + chunk_size - 1
        result[#result + 1] = body:sub(chunk_start, chunk_end)
        pos = chunk_end + 3  -- skip trailing \r\n
    end
    return table.concat(result)
end

local function http_post(host, port, path, headers, body)
    local sock, err = make_tls_socket(host, port)
    if not sock then return nil, err end

    -- build request
    local req_lines = {
        string.format("POST %s HTTP/1.1", path),
        string.format("Host: %s", host),
        "Connection: close",
    }
    for k, v in pairs(headers) do
        req_lines[#req_lines + 1] = string.format("%s: %s", k, v)
    end
    req_lines[#req_lines + 1] = string.format("Content-Length: %d", #body)
    req_lines[#req_lines + 1] = ""  -- blank line ending headers
    req_lines[#req_lines + 1] = ""

    local request = table.concat(req_lines, "\r\n") .. body

    -- send
    local ok, err = sock:send(request)
    if not ok then sock:close(); return nil, "send failed: " .. tostring(err) end

    -- receive full response
    local response = {}
    while true do
        local chunk, err, partial = sock:receive(4096)
        if chunk then
            response[#response + 1] = chunk
        elseif partial and #partial > 0 then
            response[#response + 1] = partial
            break
        else
            break
        end
    end
    sock:close()

    local raw = table.concat(response)

    -- split headers / body
    local header_section, body_section = raw:match("^(.-)\r\n\r\n(.*)$")
    if not header_section then
        return nil, "malformed HTTP response"
    end

    local is_chunked = header_section:lower():find("transfer%-encoding:%s*chunked") ~= nil
    local final_body

    print("[debug] is_chunked: " .. tostring(is_chunked))

    if is_chunked then
	    final_body = decode_chunked(body_section)
   else
	    final_body = body_section
    end

    -- extract status code
    local status = tonumber(header_section:match("HTTP/%d%.%d (%d+)"))

    return { status = status, body = final_body }
end

-- ── public API ────────────────────────────────────────────────────────────────

--- Send a messages request to the Anthropic API.
-- @param messages  table  Array of {role, content} tables
-- @param opts      table  Optional overrides: model, max_tokens, system
-- @return          table  Parsed response, or nil + error string
function M.messages(messages, opts)
    opts = opts or {}

    assert(M.config.api_key, "ANTHROPIC_API_KEY not set")

    local payload = {
        model      = opts.model      or M.config.model,
        max_tokens = opts.max_tokens or 1024,
        messages   = messages,
    }
    if opts.system then
        payload.system = opts.system
    end

    local body = json.encode(payload)

    local headers = {
        ["Content-Type"]      = "application/json",
        ["x-api-key"]         = M.config.api_key,
        ["anthropic-version"] = M.config.version,
    }

    local resp, err = http_post(
        M.config.host,
        M.config.port,
        "/v1/messages",
        headers,
        body
    )

    if not resp then return nil, err end

    if resp.status ~= 200 then
        return nil, string.format("API error %d: %s", resp.status, resp.body)
    end

    local decoded, _, err = json.decode(resp.body)
    if not decoded then return nil, "JSON decode failed: " .. tostring(err) end

    return decoded
end

--- Convenience: extract text from a messages response.
function M.get_text(response)
    if not response or not response.content then return nil end
    for _, block in ipairs(response.content) do
        if block.type == "text" then return block.text end
    end
    return nil
end

return M
