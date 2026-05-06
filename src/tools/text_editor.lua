
-- A lua 5.4 implementation of the text editor / directory list tool.
--
-- Documented at https://platform.claude.com/docs/en/agents-and-tools/tool-use/text-editor-tool
--

local json = require('dkjson')
local config = require('config')

TextEditor = {}
TextEditor.__index = TextEditor

-- Create a log instance
function TextEditor:create()
	local m = {}
	setmetatable(m, TextEditor)
	m.locals = {}
	m.config = config:new()
	return m
end

function TextEditor:__close()
end

function TextEditor:get_schema()
	return {
		name = "str_replace_based_edit_tool",
		type = "text_editor_20250728",
	}
end

function TextEditor:get_properties()
	return {
		persistent = false
	}
end

function TextEditor:sanitize_path(path)
	local sandbox = self.config.config.sandbox.path

	if path:find("%.%./") or path:find("/%.%.") or path == ".." then
		return nil, "Error: path traversal not allowed"
	end
	if not (path:sub(1, #sandbox) == sandbox) then
		return nil, "Error: path is outside allowed root"
	end
	return path
end


function TextEditor:count_occurrences(haystack, needle)
    -- Escape magic characters for plain find
    local escaped = needle:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%1")
    local count = 0
    local init = 1
    while true do
        local s = haystack:find(escaped, init, false)
        if not s then break end
        count = count + 1
        init = s + #needle
    end
    return count
end


-- Read a file.
--
-- This reads the whole file in at once. None of this is using streaming,
-- even though in theory we could stream stuff into the post body
-- in the future.
--
-- It also currently doesn't do any security checks on the path, nor is it
-- enforcing any sandboxing at the present moment.
--
function TextEditor:read_file(path)
	local f, err = io.open(path, "r")
	if not f then return nil, err end
	local content = f:read("*a")
	f:close()
	return content
end

-- Write / replace a file.
--
function TextEditor:write_file(path, content)
	local f, err = io.open(path, "w+")
	if not f then return false, err end

	-- TODO: how can we validate the file was written to?
	-- eg, is there a return value from :write() that can be checked?
	f:write(content)
	f:close()

	return true
end

function TextEditor:split_lines(content)
	local lines = {}
	for line in (content .. "\n"):gmatch("([^\n]*)\n") do
		table.insert(lines, line)
	end
	return lines
end

function TextEditor:is_directory(path)
	local fa = lfs.attributes(path)
	if fa == nil then
		return false
	end
	if fa.mode == "directory" then
		return true
	end
	return false
end

function TextEditor:is_file(path)
	local fa = lfs.attributes(path)
	if fa == nil then
		return false
	end
	if fa.mode == "file" then
		return true
	end
	return false
end

function TextEditor:is_exists(path)
	local fa = lfs.attributes(path)
	if fa == nil then
		return false
	end
	return true
end

-- Return a directory listing for the given path.
--
-- This assumes the path has already been validated and is
-- in the sandbox.
-- 
-- Returns nil if there's an error, or the directory listing
-- line by line if not.
--
function TextEditor:cmd_view_directory(req, path)
	local dirs = {}

	for file in lfs.dir(path) do
		if file == "." or file == ".." then
			goto nextdir
		end

		local fn = path .. "/" .. file
		local fa = lfs.attributes(fn)
		if fa.mode == "file" then
			table.insert(dirs, tostring(fa.size) .. "\t" .. file)
		elseif fa.mode == "directory" then
			table.insert(dirs, "0" .. "\t" .. file .. "/")
		else
			-- TODO: what do we do for non file/directory entries?
			table.insert(dirs, "0" .. "\t" .. file)
		end
	::nextdir::
	end
	local output = table.concat(dirs, "\n")
	return {
	    content = output,
	}
end

function TextEditor:cmd_view_file(req, path)
	local content, read_err = self:read_file(path)
	if not content then
		return {
		    is_error = true,
		    content = "Error: " .. (read_err or "unknown"),
		}
	end

	local lines = self:split_lines(content)
	local start_l = 1
	local end_l = #lines

	if req.input.view_range then
		start_l = req.input.view_range[1]
		end_l = req.input.view_range[2]
		if end_l == -1 then end_l = #lines end

		-- Bounds check
		if start_l < 1 or start_l > #lines then
			return {
			    is_error = true,
			    content = string.format(
			        "error: start_line %d out of range (file has %d lines)",
			        start_l, #lines),
			}
		end
		end_l = math.min(end_l, #lines)
	end

	local result = {}
	for i = start_l, end_l do
		table.insert(result, string.format("%d\t%s", i, lines[i]))
	end

	local output = table.concat(result, "\n")

	-- Respect max_characters if set
	--
	-- TODO: update to use global config
	-- TODO: what should the output say to indicate the maximum size has been reached?
	--
	if #output > self.config.config.tools.text_editor.max_output_chars then
	 	output = output:sub(1, self.config.config.tools.text_editor.max_output_chars)
		output = output .. string.format("\nText truncated at %d characters\n",
		    self.config.config.tools.text_editor.max_output_chars)
	end
	return {
	    content = output,
	}
end

--
-- Handle the view command from the agent.
--
-- This is called for both directory and file viewing.
-- Directory viewing will have a trailing slash.
--
-- File contents will be returned line by line prefixed with
-- a line number and a tab character.
--
-- I am not yet sure what the directory contents will be prepended
-- with.  That will require some experimentation.
--
-- It also seems the tool may not know if it is asking for
-- a directory or file.  (I wish the API were better defined.)
-- Specifically if you ask it to list the contents of a path with
-- no trailing slash, it just issues view.  I guess we would have
-- to handle that and if it's a directory list the contents of the
-- directory?  But how do we return that it's a directory?
--
-- Ah, according to the 'memory-tool' documentation, directories
-- are formatted as <size><tab><path/file> . Size is a human readable
-- format, eg "1.5K".  That's sufficiently different to file contents.
-- ok.
--
function TextEditor:cmd_view(req)

	-- Initial path sanitization
	local path, err = self:sanitize_path(req.input.path)
	if not path then
		return {
		    is_error = true,
		    content = err,
		}
	end

	if self:is_directory(path) then
		return self:cmd_view_directory(req, path)
	end

	if self:is_file(path) then
		return self:cmd_view_file(req, path)
	end

	-- XXX TODO: verify what the correct error is here
	return {
	    is_error = true,
	    content = "Error: the object at '" .. path .. "' is not a supported type"
	}
end

function TextEditor:cmd_str_replace(req)
    if not req.input.old_str then
        return { is_error = true, content = "Error: old_str is required" }
    end

    local path, err = self:sanitize_path(req.input.path)
    if not path then return { is_error = true, content = err } end

    local content, read_err = self:read_file(path)
    if not content then
        return { is_error = true,
	    content = "Error: " .. (read_err or "unknown") }
    end

    local count = self:count_occurrences(content, req.input.old_str)

    if count == 0 then
        return { is_error = true, content = "Error: old_str not found in file" }
    end
    if count > 1 then
        return { is_error = true, content = string.format(
            "Error: old_str matches %d locations — must be unique. Add more surrounding context.", count) }
    end

    local escaped     = req.input.old_str:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%1")
    local new_str     = (req.input.new_str or ""):gsub("%%", "%%%%")  -- escape replacement string
    local new_content = content:gsub(escaped, new_str, 1)

    local ok, write_err = self:write_file(path, new_content)
    if not ok then
        return { is_error = true, content = "Error writing file: " .. (write_err or "unknown") }
    end

    return { content = "str_replace applied successfully" }
end


-- Create a file.
--
-- The file contents are in req.input.file_text as a straight up text blob.
-- 
function TextEditor:cmd_create(req)
	local path = req.path

	-- Sanitize path
	--
	local path, err = self:sanitize_path(req.input.path)
	if not path then
		return {
		    is_error = true,
		    content = err,
		}
	end

	-- Check if the file exists
	if self:is_exists(path) then
		-- TODO: I don't know if there's a proper error to
		-- return here!
		return {
			is_error = true,
			content = "A file/directory already exists at '" .. path .. "'"
		}
	end

	-- Attempt to create the file
	local ret, msg = self:write_file(path, req.input.file_text)
	if ret == false then
		return {
			is_error = true,
			content = msg
		}
	end

	return {
	    content = "Successfully create and wrote to '" .. path .. "'"
	}
end

-- Insert a line at the given line number.
--
-- This requires input.insert_line and input.insert_text.
-- input.insert_text will have 1 or more lines separated by \n .
--
function TextEditor:cmd_insert(req)

	-- Sanity check arguments
	if req.input.path == nil
	    or req.input.insert_line == nil
	    or req.input.insert_text == nil then
		return {
		    is_error = true,
		    content = "Error: path, insert_line and insert_text are required"
		}
	end

	-- Sanitize path
	--
	local path, err = self:sanitize_path(req.input.path)
	if not path then
		return {
		    is_error = true,
		    content = err,
		}
	end

	-- Read content
	local content, read_err = self:read_file(path)
	if not content then
		return {
		    is_error = true,
		    content = "Error: " .. (read_err or "unknown"),
		}
	end

	-- Split text lines
	local lines = self:split_lines(content)

	if req.input.insert_line < 0 or req.input.insert_line > #lines then
		return {
			is_error = true,
			content = string.format(
			    "Error: insert_line %d out of range (file has %d lines)",
			    req.input.insert_line, #lines)
		}
	end

	local new_lines = self:split_lines(req.input.insert_text)
	for i, line in ipairs(new_lines) do
		table.insert(lines, req.input.insert_line + i, line)
	end

	-- Concatenate file contents back, write
	local ret, write_err = self:write_file(path, table.concat(lines, "\n"))
	if not ret then
		return {
			is_error = true,
			content = "Error writing file: " .. (write_err or "unknown")
		}
	end

	return {
	    content = string.format("Inserted %d line(s) after line %d",
	        #new_lines, req.input.insert_line)
	}
end

function TextEditor:get_ui_label(req)
	return {
		content = "Calling " .. (req.input.command or "<missing command>")
		    .. " on " .. (req.input.path or "<missing path>")
	}
end

-- Return a valid response content block for the given input
--
function TextEditor:run(req)
	local input = req.input
	local command = input.command

	if command == "view" then return self:cmd_view(req)
	elseif command == "str_replace" then return self:cmd_str_replace(req)
	elseif command == "create" then return self:cmd_create(req)
	elseif command == "insert" then return self:cmd_insert(req)
	elseif command == "undo_edit" then
		return {
		    is_error = true,
		    content = "Error: undo_edit is not supported in text_editor_20250728",
	        }
	elseif command == nil then
		return {
		    is_error = true,
		    content = "Error: missing command field"
		}
	else
		return {
		    is_error = true,
		    content = "Error: unknown command: " .. tostring(command),
		}
	end
end

return TextEditor
