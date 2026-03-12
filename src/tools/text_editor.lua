
-- Example weather tool
--

local json = require('dkjson')

TextEditor = {}
TextEditor.__index = TextEditor

-- Create a log instance
function TextEditor:create()
	local m = {}
	setmetatable(m, TextEditor)
	m.locals = {}
	return m
end

function TextEditor:get_schema()
	return {
		name = "str_replace_based_edit_tool",
		type = "text_editor_20250728",
	}
end

function TextEditor:sanitize_path(path)
	if path:find("%.%./") or path:find("/%.%.") or path == ".." then
		return nil, "Error: path traversal not allowed"
	end
	if not path:sub(1, #"/home/adrian/sandbox") == "/home/adrian/sandbox" then
		return nil, "Error: path is outside allowed root"
	end
	return path
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

function TextEditor:split_lines(content)
	local lines = {}
	for line in (content .. "\n"):gmatch("([^\n]*)\n") do
		table.insert(lines, line)
	end
	return lines
end

function TextEditor:cmd_view(req)
	local path, err = self:sanitize_path(req.input.path)
	if not path then
		return {
		    is_error = true,
		    content = err,
		    type = "tool_result",
		    tool_use_id = req.id
		}
	end

	-- TODO: directory open?
	local content, read_err = self:read_file(path)
	if not content then
		return {
		    is_error = true,
		    content = "Error: " .. (read_err or "unknown"),
		    type = "tool_result",
		    tool_use_id = req.id
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
			    content = string.format("error: start_line %d out of range (file has %d lines)", start_line, #lines),
			    type = "tool_result",
			    tool_use_id = req.id
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
	-- if config.max_characters and #output > config.max_characters then
	-- 	output = output:sub(1, config.max_characters)
	-- end
	return {
	    content = output,
	    type = "tool_result",
	    tool_use_id = req.id,
	}

end

function TextEditor:cmd_str_replace(req)
	return {
	    is_error = true,
	    content = "Error: unimplemented command: " .. tostring(command),
	    type = "tool_result",
	    tool_use_id = req.id
	}
end

function TextEditor:cmd_create(req)
	return {
	    is_error = true,
	    content = "Error: unimplemented command: " .. tostring(command),
	    type = "tool_result",
	    tool_use_id = req.id
	}
end

function TextEditor:cmd_insert(req)
	return {
	    is_error = true,
	    content = "Error: unimplemented command: " .. tostring(command),
	    type = "tool_result",
	    tool_use_id = req.id
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
		    type = "tool_result",
		    tool_use_id = req.id
	        }
	else
		return {
		    is_error = true,
		    content = "Error: unknown command: " .. tostring(command),
		    type = "tool_result",
		    tool_use_id = req.id
		}
	end
end

return TextEditor
