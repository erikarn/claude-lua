general flow
============

(tbd)

* at some point that big loop in main and the stream handling in the
  client library should get cleaned up a bunch more and moved into
  an "agent" class.  That way I can create multiple agents maintaining
  their own states (tools/tool state, conversation state, etc) so I can
  build more complicated agent control flows.

* (done) add initial caching so i don't blow through tokens so fast

* (done) add logic to retry if i hit pause_run, max_tokens, etc.

* notably for max_tokens i likely need to ask if the token limit can be
  bumped up before continuing, as 1024 output tokens isn't enough for
  code generation.

* need to decode the context window error, eg

./fea2f697-0a4c-4f64-9a12-52ed81ce6890/session.txt:{"type":"debug","content":{"text":"{\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"input length and `max_tokens` exceed context limit: 140713 + 64000 > 200000, decrease input length or `max_tokens` and try again\"},\"request_id\":\"req_011CaijFW9txnnT45pZ4cJML\"}","section":"conversation"}},

* .. and read the docs on how to make it configurable so I can test much
  smaller context windows?

* handle out of credits, eg

./012f15b5-ab73-4eba-b3f5-57beee0421bf/session.txt:{"type":"debug","content":{"section":"conversation","text":"{\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"Your credit balance is too low to access the Anthropic API. Please go to Plans & Billing to upgrade or purchase credits.\"},\"request_id\":\"req_011Cairp3tKfTAdcjgdcvyT5\"}"}},

* add support for populating the memory context when starting/restarting
  an existing context, rather than having to retype it out - this isn't the
  memory context API, this is the hints to give it at session start/restart.

* add support for the /memory API/ as well

* add support for querying it to compress its current context window into
  a summary, add my own instructions before/after it, so the session can be
  restarted.

* be better-er with badly called tools, eg

[TOOL] Calling str_replace on <missing path>
lua54: ./tools/text_editor.lua:41: attempt to index a nil value (local 'path')
stack traceback:
  ./tools/text_editor.lua:41: in function 'tools/text_editor.sanitize_path'
  ./tools/text_editor.lua:274: in function 'tools/text_editor.cmd_str_replace'


tool handling
=============

(tbd)

* migrate the schema_get() to be a static function, not an object
  function, so i don't have to call create() first (which for the bash
  tool is spawning the program, sigh.)

* (done) make a persistent tool cache class that the main loop (and later
  an agent) will use - the bash tool needs to be persistent and not
  spawn a shell each invocation (not just for efficiency, but to
  persist state like current dir, environment variables, etc.)

* (done) add lua-5.4 explicit ```__close``` metamethod in the various
  class instances - again especially important for bash, which i want
  to make sure explicitly tears down and frees the process/pipes.

* (done) bash - don't create the bash instance upon object creation - when
  the first request is made, fail it so the AI controller knows it
  needs to 'restart' the bash session.

  That way when persistent/restartable actors/agents show up, they
  won't need to worry about trying to persist a bash state between
  runs.

sandboxing
==========

(tbd)

conversation history
====================

 * (done) if i don't fetch a tool response and the conversation flow
   has a tool invocation, then subsequent requests will also
   trigger the tool invocation?  I need to dig into this a bit more.
