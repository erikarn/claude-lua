-- BashSession.lua
--
-- This has been vibe coded by Claude.  I'm not a huge fan of this
-- as-is but I do need something stood up so I can start looping the
-- tooling into iterating on itself.
--
-- It also hallucinated a whole lot - notably the result is in the json field
-- "content", not in "stdout" / "stderr". Sigh.
--
-- Anthropic bash_20250124 tool — persistent session, object model, luaposix
-- Separate stdout/stderr, allowlist sandboxing, per-command exit codes.
--
-- Usage:
--   local BashSession = require("BashSession")
--   local session = BashSession.new()
--   local r = session:execute({ command = "ls -la" })
--   print(r.exit_code, r.stdout, r.stderr)
--   local r = session:execute({ restart = true })

-- TODO:
--
-- implement a __close() metamethod!  To clean up the process state, pipes, etc

local unistd = require("posix.unistd")
local poll   = require("posix.poll")
local wait   = require("posix.sys.wait")
local signal = require("posix.signal")
local posix  = require("posix")
local config = require("config")

-- ── Class table ───────────────────────────────────────────────────────────────

local BashSession = {
}
BashSession.__index = BashSession

-- ── Config defaults ───────────────────────────────────────────────────────────

local DEFAULTS = {
    timeout_seconds  = 30,
    allowed_root     = "/TODO", -- XXX eww, this needs to be empty and enforced its set to SOMETHING
    max_output_chars = 100000,
}

-- ── Sentinels ─────────────────────────────────────────────────────────────────
-- Written after every command so we can frame stdout, stderr, and exit code
-- as discrete chunks from a continuous stream.
-- These strings must never appear in normal command output.

-- TODO: should generate unique sentinels each session/invocation!
--
local STDOUT_SENTINEL = "__BASH_STDOUT_DONE_7f3a9b__"
local EXIT_PREFIX     = "__BASH_EXIT_7f3a9b__:"

-- ── Allowlist ─────────────────────────────────────────────────────────────────

local ALLOWLIST = {
    -- Filesystem read
    ls = true, find = true, stat = true, du = true, file = true,
    -- File read
    cat = true, head = true, tail = true, grep = true, rg = true,
    wc = true, diff = true,
    -- Git
    git = true,
    -- Lua
    lua = true, lua5_4 = true, luac = true, lua54 = true,
    -- Navigation (required for stateful session)
    cd = true,
    -- Safe utils
    echo = true, printf = true, pwd = true, env = true,
    which = true, date = true, uname = true,
}

local function check_allowlist(command)
    local first = command:match("^%s*(%S+)")
    if not first then return false, "Error: empty command" end
    local base = (first:match("([^/]+)$") or first):gsub("%.", "_")
    if not ALLOWLIST[base] then
        return false, string.format("Error: command '%s' is not on the allowlist", base)
    end
    return true
end

-- ── Internal: spawn a persistent bash process ─────────────────────────────────

local function spawn(config)
    local stdin_r,  stdin_w  = unistd.pipe()
    local stdout_r, stdout_w = unistd.pipe()

    if not stdin_r or not stdout_r then
        return nil, "Error: failed to create pipes"
    end

    print("spawn: called!\n")

    local pid = unistd.fork()

    if pid == nil then
        return nil, "Error: fork failed"

    elseif pid == 0 then
        -- ── Child: become bash ─────────────────────────────────────────────
        unistd.close(stdin_w)
        unistd.close(stdout_r)

        unistd.dup2(stdin_r,  unistd.STDIN_FILENO)
        unistd.dup2(stdout_w, unistd.STDOUT_FILENO)
        unistd.dup2(stdout_w, unistd.STDERR_FILENO)

        unistd.close(stdin_r)
        unistd.close(stdout_w)

	-- TODO: holy crap I really REALLY want sandboxing here!
	--
        unistd.chdir(config.allowed_root)
        unistd.execp("bash", { [0] = "bash", "--norc", "--noprofile" })
        os.exit(1)

    else
        -- ── Parent: keep write-end of stdin, read-ends of stdout ────
        unistd.close(stdin_r)
        unistd.close(stdout_w)

--	print("pid: " .. tostring(pid))

        return {
            pid      = pid,
            stdin_w  = stdin_w,
            stdout_r = stdout_r,
        }
    end
end

-- ── Internal: kill and clean up the current process ───────────────────────────

function BashSession:_kill()
    if self._proc then
        posix.kill(self._proc.pid, signal.SIGKILL)
        wait.wait(self._proc.pid)
        unistd.close(self._proc.stdin_w)
        unistd.close(self._proc.stdout_r)
        self._proc = nil
    end
end

-- ── Constructor ───────────────────────────────────────────────────────────────

function BashSession:create(opts)
    local m = {}
    setmetatable(m, BashSession)
    m.local_config = {}
    m.config = config:new()

    -- Defaults
    for k, v in pairs(DEFAULTS) do m.local_config[k] = v end

    -- Override with global configuration fields
    --
    -- This always has to be provided!
    --
    -- XXX TODO: handle if m.config.config.tools is empty or
    -- m.config.config.tools.bash is empty!
    --
    m.local_config.sandbox = m.config.config.sandbox.path
    if m.config.config.tools.bash.timeout_seconds ~= nil then
    	m.local_config.timeout_seconds = m.config.config.tools.bash.timeout_seconds
    end
    if m.config.config.tools.bash.max_output_chars ~= nil then
        m.local_config.max_output_chars = m.config.config.tools.bash.max_output_chars
    end

    -- Override with provided opts (eg if this object wants a different timeout)
    --
    if opts then
        for k, v in pairs(opts) do m.local_config[k] = v end
    end

    -- Note: this means calling this to eg get the schema is spawning bash.
    -- Eww.
    --
    local proc, err = spawn(m.local_config)
    if not proc then error("BashSession.new: " .. err) end
    m._proc = proc
    return m
end

-- Explicit close for "local var <close> = bash.create()"
--
function BashSession:__close()
	print("Called, closing!\n")
	self:_kill()
end

function BashSession:__gc()
	print("Called, gc'ing!\n")
	self:_kill()
end

-- ── restart ───────────────────────────────────────────────────────────────────

function BashSession:restart()
    self:_kill()
    local proc, err = spawn(self.local_config)
    if not proc then
        return {
            is_error  = true,
            content = "Error restarting session: " .. err,
            exit_code = nil,
        }
    end
    self._proc = proc
    return {
        is_error  = false,
        exit_code = nil,
        content = "Bash session restarted",
    }
end

function BashSession:get_schema()
	return {
		type = "bash_20250124",
		name = "bash",
	}
end

function BashSession:get_properties()
	return {
		persistent = true
	}
end

-- Return a string indicating what we're doing

function BashSession:get_ui_label(req)
	if not req.input.command then
		return {
			content = "(missing input, error)"
		}
	end

	if req.input.restart then
		return {
			content = "(restart shell)"
		}
	end

	return {
		content = "Running: " .. req.input.command
	}

end

-- ── execute ───────────────────────────────────────────────────────────────────

function BashSession:run(req)
    local input = req.input

    if input.restart then
        return self:restart()
    end

    if not input.command then
        return {
            is_error  = true,
            content = "Error: command or restart is required",
        }
    end

    local ok, allow_err = check_allowlist(input.command)
    if not ok then
        return { is_error = true, content = allow_err, exit_code = nil }
    end

    if not self._proc then
        return {
            is_error  = true,
            content = "Error: no active bash session — call restart",
            exit_code = nil,
        }
    end

    -- ── Wrap the command ──────────────────────────────────────────────────
    -- Execution order:
    --   1. Run the user command
    --   2. Capture $? immediately before anything else can clobber it
    --   3. Emit the exit code line to stdout (it's easier to parse there)
    --   4. Emit sentinels to both stdout so we know each
    --      stream is done for this command.
    --
    -- The exit code echo goes to stdout so it arrives on the same fd
    -- we're already polling, avoiding a third fd. We strip it from
    -- the visible stdout before returning.

    -- Fix: EXIT_PREFIX already ends with ':', so the format above double-colons.
    -- Rebuild cleanly:
    wrapped = string.format(
        "(%s)\n"                                    ..
        "__exit_code=$?\n"                          ..
        "printf '%%s%%s\\n' '%s' \"$__exit_code\"\n" ..
        "echo '%s'\n",
        input.command,
        EXIT_PREFIX,
        STDOUT_SENTINEL
    )

--    print("running:\n===" .. wrapped .. "\n===\n")

    local written, write_err = unistd.write(self._proc.stdin_w, wrapped)
    if not written then
        return {
            is_error  = true,
            content = "Error writing to bash: " .. (write_err or "unknown"),
        }
    end

    -- ── Poll stdout until both sentinels arrive ────────────────

    local stdout_buf  = ""
    local stdout_done = false
    local timed_out   = false
    local deadline    = os.time() + self.local_config.timeout_seconds

    local fds = {
        [self._proc.stdout_r] = { events = { IN = true } },
    }

    while not stdout_done do
        if os.time() >= deadline then
            timed_out = true
            break
        end

        local activity = poll.poll(fds, 200)

        if activity and activity > 0 then
            if not stdout_done
                and fds[self._proc.stdout_r]
                and fds[self._proc.stdout_r].revents
                and fds[self._proc.stdout_r].revents.IN then

                local chunk = unistd.read(self._proc.stdout_r, 4096)
                if chunk and chunk ~= "" then
                    stdout_buf = stdout_buf .. chunk
                    if stdout_buf:find(STDOUT_SENTINEL, 1, true) then
                        stdout_done = true
                    end
                end
            end
        end
    end
    
--    print("finished!\n")
--    print("stdout_buf: " .. stdout_buf)

    -- ── Handle timeout ────────────────────────────────────────────────────

    if timed_out then
        self:_kill()
        return {
            is_error  = true,
            content = string.format(
                "\nError: timed out after %ds — session killed. Send restart to continue.",
                self.local_config.timeout_seconds),
        }
    end

    -- ── Extract exit code from stdout ─────────────────────────────────────
    -- stdout_buf now looks like:
    --   <command output lines>
    --   __BASH_EXIT_7f3a9b__:0
    --   __BASH_STDOUT_DONE_7f3a9b__
    --
    -- We pull the exit line out before stripping the sentinel, so we
    -- don't expose either to the caller.

    local exit_code = nil

    -- Match the exit line: PREFIX followed by digits, at a line boundary
    local exit_pattern = EXIT_PREFIX:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%1")
                         .. "(%d+)\n"

    local code_str = stdout_buf:match(exit_pattern)
    if code_str then
        exit_code = tonumber(code_str)
        -- Remove the exit code line from stdout
        stdout_buf = stdout_buf:gsub(exit_pattern, "")
    end

    -- Strip sentinels
    stdout_buf = stdout_buf:gsub(STDOUT_SENTINEL .. "\n?", "")

    -- ── Truncate ──────────────────────────────────────────────────────────

    local function truncate(s, label)
        if #s > self.local_config.max_output_chars then
            return s:sub(1, self.local_config.max_output_chars)
                .. string.format("\n[%s truncated at %d chars]", label,
		    self.local_config.max_output_chars)
        end
        return s
    end

    stdout_buf = truncate(stdout_buf, "stdout")

    -- ── Return ────────────────────────────────────────────────────────────

    -- Note: we don't return is_error if the exit code is non-zero.
    -- I'm not sure why Claude hallucinated that!
    --
    return {
        content = stdout_buf,
    }
end

return BashSession
