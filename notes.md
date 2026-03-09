notes
=====

This requires some ports built bits

$ pkg install lua54 lua54-luasocket lua54-luasec lua54-luafilesystem

It also requires the lua-readline, uuid, http and cqueues packages, which
are only available via luarocks.

However, cqueues has a bug on freebsd - see 
https://github.com/wahern/cqueues/issue/266 for more details.

# dkjson is a single .lua file - just download it
fetch https://dkolf.de/dkjson/dkjson.lua

lua-readline:

The current rockspec (0.8-1) has a bug in its specification
where it's fetching the wrong URL for the repository.

I've opened two issues:

 * https://github.com/motoprogger/lua-readline/issues/1 - source URL
 * https://github.com/motoprogger/lua-readline/issues/2 - linking to readline

experimenting
=============

To experiment:

export ANTHROPIC_API_KEY="sk-ant-..."
lua54 main.lua


Notes about the SSE event stream
================================

https://docs.anthropic.com/en/api/messages-stream

https://docs.anthropic.com/en/api/messages


message_start:

{"type":"message_start","message":{"id":"msg_01...","model":"claude-sonnet-4-20250514","usage":{"input_tokens":12}}}

Useful for: capturing the message ID, model name, and input token count.

content_block_start:

{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

Marks the start of a content block. Index matters if there are multiple blocks (e.g. tool use alongside text). For simple text responses you'll only see index 0.

content_block_delta:

{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}

This is what you print. Key fields:

    index — which content block this delta belongs to
    delta.type — either text_delta (normal text) or input_json_delta (tool use arguments)
    delta.text — the actual text chunk to print

content_block_stop:

{"type":"content_block_stop","index":0}

Signals a content block is complete. Good place to print a final newline if needed.

message_delta

{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":42}}


    delta.stop_reason — why generation stopped: end_turn, max_tokens, stop_sequence, or tool_use
    usage.output_tokens — output token count (combine with input tokens from message_start for total usage)

message_stop

{"type":"message_stop"}

Stream is done. Clean up and close.

Tools
=====

The tool list is provided upon every API call.  I haven't written
anything here yet, but this does mean I can limit which tools it
can choose from when deciding what to do next.


Conversation flow
=================

The API is apparently state-less.  It looks like I'm required to send
the whole conversation exchange history with roles switching between
user and assistant.

