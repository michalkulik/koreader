--[[--
Persistent offline queue for ShelfSync.

Items:
  { kind = "upload",   path, partial_md5, size, filename, title, authors }
  { kind = "progress", path, book_id, position, percentage, base_rev }
]]

local LuaSettings = require("luasettings")

local Queue = {}
Queue.__index = Queue

local MAX_ATTEMPTS = 5

function Queue:new(settings_file)
    local o = setmetatable({}, self)
    o.settings = LuaSettings:open(settings_file)
    o.items = o.settings:readSetting("items", {})
    return o
end

function Queue:all()
    return self.items
end

function Queue:count()
    return #self.items
end

function Queue:pending_uploads()
    local count = 0
    for _, item in ipairs(self.items) do
        if item.kind == "upload" then
            count = count + 1
        end
    end
    return count
end

function Queue:add(item)
    for i, existing in ipairs(self.items) do
        if existing.kind == item.kind and existing.path == item.path then
            item.attempts = existing.attempts or 0
            item.queued_at = existing.queued_at or os.time()
            item.last_error = existing.last_error
            self.items[i] = item
            self:save()
            return false
        end
    end
    item.attempts = item.attempts or 0
    item.queued_at = item.queued_at or os.time()
    table.insert(self.items, item)
    self:save()
    return true
end

function Queue:remove(item)
    for i, existing in ipairs(self.items) do
        if existing == item then
            table.remove(self.items, i)
            self:save()
            return true
        end
    end
    return false
end

function Queue:remove_by_key(kind, path)
    for i, existing in ipairs(self.items) do
        if existing.kind == kind and existing.path == path then
            table.remove(self.items, i)
            self:save()
            return true
        end
    end
    return false
end

function Queue:fail(item, error)
    item.attempts = (item.attempts or 0) + 1
    item.last_error = tostring(error or "unknown error")
    item.last_attempt = os.time()
    if item.attempts >= MAX_ATTEMPTS then
        item.give_up = true
    end
    self:save()
end

function Queue:clear_give_up()
    local kept = {}
    for _, item in ipairs(self.items) do
        if not item.give_up then
            table.insert(kept, item)
        end
    end
    self.items = kept
    self:save()
end

function Queue:save()
    self.settings:saveSetting("items", self.items)
    self.settings:flush()
end

function Queue:clear()
    self.items = {}
    self:save()
end

return Queue
