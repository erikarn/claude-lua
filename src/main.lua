-- main.lua
local anthropic = require("anthropic")

local messages = {
    { role = "user", content = "Explain the FreeBSD jail system in one paragraph." }
}

local response, err = anthropic.messages(messages)

if not response then
    io.stderr:write("Error: " .. tostring(err) .. "\n")
    os.exit(1)
end

print(anthropic.get_text(response))
