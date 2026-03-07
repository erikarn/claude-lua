pkg install lua54 lua54-luasocket lua54-luasec
# dkjson is a single .lua file - just download it
fetch https://dkolf.de/dkjson/dkjson.lua

To experiment:

export ANTHROPIC_API_KEY="sk-ant-..."
lua54 main.lua
