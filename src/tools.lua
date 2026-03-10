
-- Support/registry for tooling.
--


Tools = {}
Tools.__index = Tools

-- Create a log instance
function Tools:create()
	local m = {}
	setmetatable(m, Tools)
	m.tools = {}
	return m
end

-- Register the given tool class with the given tool name.
-- This is to register the whole class instance; not an
-- object created from it.
--
function Tools:register(tn, tc)
	self.tools[tn] = tc
	return true
end

function Tools:unregister(tn)
	self.tools[tn] = nil
	return true
end


-- Lookup whether a tool exists.
--
-- Return the class itself if the tool exists, nil otherwise.
--
function Tools:lookup(tn)
	return self.tools[tn]
end

-- Lookup a tool and return an instance of it if it exists.
--
-- Returns an instance of the tool if it exists, nil otherwise.
--
function Tools:lookup_and_create(tn)
	local t
	print("[DEBUG] Called; tn=" .. tn)
	if not self.tools[tn] then
		return nil
	end

	t = self.tools[tn]
	return t.create()
end

-- Return a list of tool names as a hash table.
--
function Tools:get_tool_list()
	local t = {}

	for tn, tc in pairs(self.tools) do
		t[tn] = tn
	end
	return t
end

-- Return a list of tool names as an array.
--
function Tools:get_tool_list_array()
	local t = {}

	for tn, tc in pairs(self.tools) do
		table.insert(t, tn)
	end
	return t
end

-- Return the schema for the given tool name.
--
function Tools:get_tool_schema(tn)
	if not self.tools[tn] then
		return nil
	end

	-- This creates a temporary instance of the class
	-- to extract the schema.  This isn't very efficient.
	-- Ideally the tool will export the schema as a class
	-- attribute or function, not an object instance function.
	local t = self.tools[tn]
	local tc = t.create()
	return t:get_schema()
end

-- Return the schema for all registered tools.
--
-- This is again not the most efficient routine but this isn't
-- going to be called super frequently in the grand scheme
-- of things.
--
-- Eventually we'll want to cache tool schemas and not do all
-- of this heavy work, but that can come later and it'll be
-- hidden from the consumers of this API.
--

function Tools:get_tool_schema_list()
	local ts = {}
	for tn, tc in pairs(self.tools) do
		local t = tc.create()
		table.insert(ts, t:get_schema())
	end
	return ts
end

return Tools
