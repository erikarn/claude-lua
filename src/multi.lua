local anthropic = require("anthropic")

local history = {}

io.write("You: ")
for line in io.lines() do
    -- append user message
    history[#history + 1] = { role = "user", content = line }

    local response, err = anthropic.messages(history)
    if not response then
        io.stderr:write("Error: " .. err .. "\n")
        break
    end

    local text = anthropic.get_text(response)
    print("Claude: " .. text .. "\n")

    -- append assistant turn to maintain history
    history[#history + 1] = { role = "assistant", content = text }

    io.write("You: ")
end
