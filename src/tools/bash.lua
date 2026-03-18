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

local unistd = require("posix.unistd")
local poll   = require("posix.poll")
local wait   = require("posix.sys.wait")
local signal = require("posix.signal")
local posix  = require("posix")

-- ── Class table ───────────────────────────────────────────────────────────────

local BashSession = {}
BashSession.__index = BashSession

-- ── Config defaults ───────────────────────────────────────────────────────────

local DEFAULTS = {
    timeout_seconds  = 30,
    allowed_root     = "/home/adrian/sandbox",
    max_output_chars = 100000,
}

-- ── Sentinels ─────────────────────────────────────────────────────────────────
-- Written after every command so we can frame stdout, stderr, and exit code
-- as discrete chunks from a continuous stream.
-- These strings must never appear in normal command output.

-- TODO: should generate unique sentinels each session/invocation!
--
local STDOUT_SENTINEL = "__BASH_STDOUT_DONE_7f3a9b__"
local STDERR_SENTINEL = "__BASH_STDERR_DONE_7f3a9b__"
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
    local stderr_r, stderr_w = unistd.pipe()

    if not stdin_r or not stdout_r or not stderr_r then
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
        unistd.close(stderr_r)

        unistd.dup2(stdin_r,  unistd.STDIN_FILENO)
        unistd.dup2(stdout_w, unistd.STDOUT_FILENO)
        unistd.dup2(stderr_w, unistd.STDERR_FILENO)

        unistd.close(stdin_r)
        unistd.close(stdout_w)
        unistd.close(stderr_w)

	-- TODO: holy crap I really REALLY want sandboxing here!
	--
        unistd.chdir(config.allowed_root)
        unistd.execp("bash", { [0] = "bash", "--norc", "--noprofile" })
        os.exit(1)

    else
        -- ── Parent: keep write-end of stdin, read-ends of stdout/stderr ────
        unistd.close(stdin_r)
        unistd.close(stdout_w)
        unistd.close(stderr_w)

	print("pid: " .. tostring(pid))

        return {
            pid      = pid,
            stdin_w  = stdin_w,
            stdout_r = stdout_r,
            stderr_r = stderr_r,
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
        unistd.close(self._proc.stderr_r)
        self._proc = nil
    end
end

-- ── Constructor ───────────────────────────────────────────────────────────────

function BashSession:create(opts)
    local m = {}
    setmetatable(m, BashSession)
    m.config = {}
    for k, v in pairs(DEFAULTS) do m.config[k] = v end
    if opts then
        for k, v in pairs(opts) do m.config[k] = v end
    end

    local proc, err = spawn(m.config)
    if not proc then error("BashSession.new: " .. err) end
    m._proc = proc
    return m
end

-- ── restart ───────────────────────────────────────────────────────────────────

function BashSession:restart()
    self:_kill()
    local proc, err = spawn(self.config)
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

-- ── execute ───────────────────────────────────────────────────────────────────

function BashSession:run(req)
    local input = req.input

    if input.restart then
        return self:restart()
    end

    if not input.command then
        return {
            is_error  = true,
            stdout    = "",
            stderr    = "Error: command or restart is required",
            exit_code = nil,
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
    --   4. Emit sentinels to both stdout and stderr so we know each
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
        "echo '%s'\n"                               ..
        "echo '%s' >&2\n",
        input.command,
        EXIT_PREFIX,
        STDOUT_SENTINEL,
        STDERR_SENTINEL
    )

    print("running:\n===" .. wrapped .. "\n===\n")

    local written, write_err = unistd.write(self._proc.stdin_w, wrapped)
    if not written then
        return {
            is_error  = true,
            stdout    = "",
            stderr    = "Error writing to bash: " .. (write_err or "unknown"),
            exit_code = nil,
        }
    end

    -- ── Poll stdout and stderr until both sentinels arrive ────────────────

    local stdout_buf  = ""
    local stderr_buf  = ""
    local stdout_done = false
    local stderr_done = false
    local timed_out   = false
    local deadline    = os.time() + self.config.timeout_seconds

    local fds = {
        [self._proc.stdout_r] = { events = { IN = true } },
        [self._proc.stderr_r] = { events = { IN = true } },
    }

    while not stdout_done or not stderr_done do
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

            if not stderr_done
                and fds[self._proc.stderr_r]
                and fds[self._proc.stderr_r].revents
                and fds[self._proc.stderr_r].revents.IN then

                local chunk = unistd.read(self._proc.stderr_r, 4096)
                if chunk and chunk ~= "" then
                    stderr_buf = stderr_buf .. chunk
                    if stderr_buf:find(STDERR_SENTINEL, 1, true) then
                        stderr_done = true
                    end
                end
            end
        end
    end
    
    print("finished!\n")
    print("stdout_buf: " .. stdout_buf)
    print("stderr_buf: " .. stderr_buf)

    -- ── Handle timeout ────────────────────────────────────────────────────

    if timed_out then
        self:_kill()
        return {
            is_error  = true,
--            stdout    = stdout_buf,
--            stderr    = stderr_buf .. string.format(
            content = string.format(
                "\nError: timed out after %ds — session killed. Send restart to continue.",
                self.config.timeout_seconds),
            exit_code = nil,
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
    stderr_buf = stderr_buf:gsub(STDERR_SENTINEL .. "\n?", "")

    -- ── Truncate ──────────────────────────────────────────────────────────

    local function truncate(s, label)
        if #s > self.config.max_output_chars then
            return s:sub(1, self.config.max_output_chars)
                .. string.format("\n[%s truncated at %d chars]", label, self.config.max_output_chars)
        end
        return s
    end

    stdout_buf = truncate(stdout_buf, "stdout")
    stderr_buf = truncate(stderr_buf, "stderr")

    -- ── Return ────────────────────────────────────────────────────────────

    -- Note: we don't return is_error if the exit code is non-zero.
    -- I'm not sure why Claude hallucinated that!
    --
    return {
        content = stdout_buf,
    }
end

-- ── serialise (for tool_result content field) ─────────────────────────────────

function BashSession:serialise(result)
    local parts = {}

    if result.note then
        table.insert(parts, result.note)
    end

    if result.exit_code ~= nil then
        table.insert(parts, string.format("exit code: %d", result.exit_code))
    end

    if result.stdout and result.stdout ~= "" then
        table.insert(parts, "stdout:\n" .. result.stdout)
    end

    if result.stderr and result.stderr ~= "" then
        table.insert(parts, "stderr:\n" .. result.stderr)
    end

    if #parts == 0 then
        table.insert(parts, "(no output)")
    end

    return table.concat(parts, "\n\n")
end

-- ── Tool definition (for API tools array) ────────────────────────────────────

BashSession.definition = {
    type = "bash_20250124",
    name = "bash",
}

return BashSession
