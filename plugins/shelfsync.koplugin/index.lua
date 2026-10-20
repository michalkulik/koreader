--[[--
Local index: maps a local file path to the server book id and
per-book sync state (last known progress revision, upload state).
]]

local LuaSettings = require("luasettings")

local Index = {}
Index.__index = Index

function Index:new(settings_file)
    local o = setmetatable({}, self)
    o.settings = LuaSettings:open(settings_file)
    o.data = o.settings:readSetting("index", {})
    return o
end

function Index:get(path)
    return self.data[path]
end

function Index:set(path, entry)
    entry = entry or {}
    entry.updated_at = os.time()
    self.data[path] = entry
    self:save()
    return entry
end

function Index:update(path, changes)
    local entry = self.data[path] or {}
    for key, value in pairs(changes or {}) do
        entry[key] = value
    end
    return self:set(path, entry)
end

function Index:remove(path)
    self.data[path] = nil
    self:save()
end

function Index:find_by_book_id(book_id)
    for path, entry in pairs(self.data) do
        if entry.book_id == book_id then
            return path, entry
        end
    end
end

function Index:find_by_partial_md5(partial_md5)
    if not partial_md5 then return end
    for path, entry in pairs(self.data) do
        if entry.partial_md5 == partial_md5 then
            return path, entry
        end
    end
end

function Index:save()
    self.settings:saveSetting("index", self.data)
    self.settings:flush()
end

return Index
