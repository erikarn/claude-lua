general flow
============

(tbd)

* at some point that big loop in main and the stream handling in the
  client library should get cleaned up a bunch more and moved into
  an "agent" class.  That way I can create multiple agents maintaining
  their own states (tools/tool state, conversation state, etc) so I can
  build more complicated agent control flows.

* (done) add initial caching so i don't blow through tokens so fast

* add logic to retry if i hit pause_run, max_tokens, etc.

* notably for max_tokens i likely need to ask if the token limit can be
  bumped up before continuing, as 1024 output tokens isn't enough for
  code generation.

tool handling
=============

(tbd)

* migrate the schema_get() to be a static function, not an object
  function, so i don't have to call create() first (which for the bash
  tool is spawning the program, sigh.)

* make a persistent tool cache class that the main loop (and later
  an agent) will use - the bash tool needs to be persistent and not
  spawn a shell each invocation (not just for efficiency, but to
  persist state like current dir, environment variables, etc.)

* add lua-5.4 explicit ```__close``` metamethod in the various
  class instances - again especially important for bash, which i want
  to make sure explicitly tears down and frees the process/pipes.

sandboxing
==========

(tbd)

conversation history
====================

 * (done) if i don't fetch a tool response and the conversation flow
   has a tool invocation, then subsequent requests will also
   trigger the tool invocation?  I need to dig into this a bit more.
