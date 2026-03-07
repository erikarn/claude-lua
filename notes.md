notes
=====

This requires some ports built bits

$ pkg install lua54 lua54-luasocket lua54-luasec

It also requires the http and cqueues packages.

However, cqueues has a bug on freebsd - see 
https://github.com/wahern/cqueues/issue/266 for more details.

# dkjson is a single .lua file - just download it
fetch https://dkolf.de/dkjson/dkjson.lua

To experiment:

export ANTHROPIC_API_KEY="sk-ant-..."
lua54 main.lua
