--[[--
ShelfSync: self-hosted shelf/library integration for koreader-server.

Stage 2:
  * device token login,
  * local index and offline queue,
  * progress pull/push,
  * upload the current book when it is opened,
  * basic remote shelf with download/open.
]]

local BD = require("ui/bidi")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local ProgressbarDialog = require("ui/widget/progressbardialog")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local md5 = require("ffi/sha2").md5
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local Client = require("client")
local Index = require("index")
local Queue = require("queue")

local settings_dir = DataStorage:getSettingsDir()

local ShelfSync = WidgetContainer:extend{
    name = "shelfsync",
    is_doc_only = false,
    auto_upload = true,
    auto_progress = true,
    page_counter = 0,
    library = {},
    library_time = 0,
}

function ShelfSync:init()
    self.settings = LuaSettings:open(settings_dir .. "/shelfsync.lua")
    self.server_url = self.settings:readSetting("server_url", "https://shelf.mkulik.eu")
    self.username = self.settings:readSetting("username")
    self.token = self.settings:readSetting("token")
    self.device_id = self.settings:readSetting("device_id")
    self.device_name = self.settings:readSetting("device_name", Device.model or "KOReader")
    self.download_dir = self.settings:readSetting("download_dir")
    self.auto_upload = self.settings:readSetting("auto_upload", true)
    self.auto_progress = self.settings:readSetting("auto_progress", true)

    if not self.device_id then
        self.device_id = md5(tostring(os.time()) .. tostring(Device.model) .. tostring(math.random(1, 1000000)))
        self.settings:saveSetting("device_id", self.device_id)
    end

    self.queue = Queue:new(settings_dir .. "/shelfsync_queue.lua")
    self.index = Index:new(settings_dir .. "/shelfsync_index.lua")
    self.client = Client:new{
        base_url = self.server_url,
        token = self.token,
    }
end

function ShelfSync:saveSettings()
    self.settings:saveSetting("server_url", self.server_url)
    self.settings:saveSetting("username", self.username)
    self.settings:saveSetting("token", self.token)
    self.settings:saveSetting("device_id", self.device_id)
    self.settings:saveSetting("device_name", self.device_name)
    self.settings:saveSetting("download_dir", self.download_dir)
    self.settings:saveSetting("auto_upload", self.auto_upload)
    self.settings:saveSetting("auto_progress", self.auto_progress)
    self.settings:flush()
end

function ShelfSync:isLoggedIn()
    return self.server_url and self.server_url ~= "" and self.token and self.token ~= ""
end

function ShelfSync:showInfo(text, timeout)
    UIManager:show(InfoMessage:new{
        text = text,
        timeout = timeout or 3,
    })
end

function ShelfSync:handleError(code, body, action)
    if code == 401 then
        self.token = nil
        self.client.token = nil
        self:saveSettings()
        self:showInfo(_("Shelf sync: log in again."))
        return
    end
    local detail = body and body.detail or body
    if type(detail) == "table" then
        detail = detail.raw or detail.detail
    end
    self:showInfo(T(_("Shelf sync error (%1): %2"), action or _("request"),
        tostring(detail or code or _("unknown"))), 5)
end

function ShelfSync:onFlushSettings()
    if self.settings then self:saveSettings() end
    if self.queue then self.queue:save() end
    if self.index then self.index:save() end
end

-- --------------------------------------------------------------- book info

function ShelfSync:currentBook()
    local ui = self.ui
    if not ui or not ui.document then return end
    local file = ui.document.file
    if not file then return end
    local partial_md5 = ui.doc_settings and ui.doc_settings:readSetting("partial_md5_checksum")
    if not partial_md5 then
        partial_md5 = util.partialMD5(file)
    end
    local props = ui.doc_props or {}
    return {
        file = file,
        partial_md5 = partial_md5,
        size = lfs.attributes(file, "size"),
        filename = file:match("([^/\\]+)$") or file,
        title = props.display_title or props.title,
        authors = props.authors,
        series = props.series,
        language = props.language,
    }
end

function ShelfSync:currentPosition()
    local ui = self.ui
    if not ui or not ui.document then return end
    if ui.document.info.has_pages then
        return tostring(ui.paging:getLastProgress()), ui.paging:getLastPercent()
    else
        return ui.rolling:getLastProgress(), ui.rolling:getLastPercent()
    end
end

function ShelfSync:gotoPosition(position)
    if not position or position == "" then return end
    if self.ui.document.info.has_pages then
        self.ui:handleEvent(Event:new("GotoPage", tonumber(position)))
    else
        self.ui:handleEvent(Event:new("GotoXPointer", position))
    end
end

-- ------------------------------------------------------------------ library

function ShelfSync:refreshLibrary()
    if not self:isLoggedIn() then return end
    local books, code, err = self.client:list_books()
    if not books then
        self:handleError(code, err, _("library"))
        return
    end
    self.library = books
    self.library_time = os.time()
    return books
end

function ShelfSync:findBookByMD5(partial_md5)
    if not partial_md5 then return end
    for _, book in ipairs(self.library or {}) do
        if book.partial_md5 == partial_md5 then
            return book
        end
    end
end

function ShelfSync:findBookById(book_id)
    for _, book in ipairs(self.library or {}) do
        if book.id == book_id then
            return book
        end
    end
end

function ShelfSync:ensureBook(meta, create)
    if not meta or not meta.file then return end
    local entry = self.index:get(meta.file)
    if entry and entry.book_id then
        return entry.book_id
    end
    if not create then return end

    local book = self:findBookByMD5(meta.partial_md5)
    if not book and os.time() - (self.library_time or 0) > 30 then
        self:refreshLibrary()
        book = self:findBookByMD5(meta.partial_md5)
    end
    if book then
        self.index:update(meta.file, {
            book_id = book.id,
            partial_md5 = meta.partial_md5,
            uploaded = book.upload_required == false,
        })
        return book.id
    end

    local data, code, err = self.client:create_book({
        partial_md5 = meta.partial_md5,
        size = meta.size,
        filename = meta.filename,
        metadata = {
            title = meta.title,
            authors = meta.authors,
            series = meta.series,
            language = meta.language,
        },
    })
    if not data then
        self:handleError(code, err, _("create book"))
        return
    end
    self.index:update(meta.file, {
        book_id = data.id,
        partial_md5 = meta.partial_md5,
        uploaded = data.upload_required == false,
    })
    table.insert(self.library, data)
    return data.id
end

-- ------------------------------------------------------------------- upload

function ShelfSync:queueCurrentBook()
    local meta = self:currentBook()
    if not meta then return end
    local entry = self.index:get(meta.file)
    if entry and entry.uploaded then return end
    local remote = self:findBookByMD5(meta.partial_md5)
    if remote and remote.upload_required == false then
        self.index:update(meta.file, {
            book_id = remote.id,
            partial_md5 = meta.partial_md5,
            uploaded = true,
        })
        return
    end
    local added = self.queue:add({
        kind = "upload",
        path = meta.file,
        partial_md5 = meta.partial_md5,
        size = meta.size,
        filename = meta.filename,
        title = meta.title,
        authors = meta.authors,
        series = meta.series,
        language = meta.language,
    })
    if added then
        self:showInfo(T(_("Shelf: queued %1 for upload."), meta.filename), 2)
    end
    if NetworkMgr:isOnline() then
        self:flushQueue(false)
    end
end

function ShelfSync:doUpload(item, interactive)
    local book_id = self:ensureBook({
        file = item.path,
        partial_md5 = item.partial_md5,
        size = item.size,
        filename = item.filename,
        title = item.title,
        authors = item.authors,
        series = item.series,
        language = item.language,
    }, true)
    if not book_id then
        return nil, _("could not create book")
    end
    local entry = self.index:get(item.path)
    if entry and entry.uploaded then
        return true
    end
    local size = item.size or lfs.attributes(item.path, "size")
    if not size or size <= 0 then
        return nil, _("file is missing")
    end

    local dialog = ProgressbarDialog:new{
        title = T(_("Uploading %1"), item.filename or item.path),
        progress_max = size,
    }
    dialog:show()
    local data, code, err = self.client:upload_file(book_id, item.path, size, function(progress)
        dialog:reportProgress(progress)
    end)
    dialog:close()
    if not data then
        return nil, code == 401 and "unauthorized" or err
    end
    self.index:update(item.path, {
        book_id = book_id,
        partial_md5 = item.partial_md5,
        uploaded = true,
        size = size,
        content_sha256 = data.content_sha256,
    })
    return true
end

-- ----------------------------------------------------------------- progress

function ShelfSync:doProgress(item, interactive)
    local book_id = item.book_id
    if not book_id then
        book_id = self:ensureBook({
            file = item.path,
            partial_md5 = item.partial_md5,
            size = item.size,
            filename = item.filename,
            title = item.title,
            authors = item.authors,
        }, true)
    end
    if not book_id then
        return nil, _("could not create book")
    end
    local progress = {
        position = tostring(item.position),
        percentage = item.percentage or 0,
        device = self.device_name,
        device_id = self.device_id,
        base_rev = item.base_rev or 0,
    }
    local data, code, err = self.client:put_progress(book_id, progress)
    if not data and code == 409 then
        local current_rev = err and err.current_rev or 0
        progress.base_rev = current_rev
        data, code, err = self.client:put_progress(book_id, progress)
    end
    if not data then
        return nil, code == 401 and "unauthorized" or err
    end
    self.index:update(item.path, {
        book_id = book_id,
        last_rev = data.rev,
        last_position = data.position,
        last_percentage = data.percentage,
    })
    return true
end

function ShelfSync:pushProgress(interactive)
    if not self:isLoggedIn() then return end
    local meta = self:currentBook()
    if not meta then return end
    local position, percentage = self:currentPosition()
    if not position then return end
    local entry = self.index:get(meta.file) or {}
    local item = {
        kind = "progress",
        path = meta.file,
        partial_md5 = meta.partial_md5,
        size = meta.size,
        filename = meta.filename,
        title = meta.title,
        authors = meta.authors,
        position = position,
        percentage = percentage or 0,
        base_rev = entry.last_rev or 0,
    }
    if NetworkMgr:isOnline() then
        local ok, err = self:doProgress(item, interactive)
        if ok then
            if interactive then self:showInfo(_("Progress sent to the shelf.")) end
            return true
        end
        logger.dbg("ShelfSync: progress push failed", err)
    end
    self.queue:add(item)
    if interactive then
        self:showInfo(_("Progress queued for the next sync."))
    end
end

function ShelfSync:pullProgress(interactive)
    if not self:isLoggedIn() then return end
    if not NetworkMgr:isOnline() then
        if interactive then
            NetworkMgr:willRerunWhenOnline(function() self:pullProgress(true) end)
        end
        return
    end
    local meta = self:currentBook()
    if not meta then return end

    local book = self:findBookByMD5(meta.partial_md5)
    if not book then
        self:refreshLibrary()
        book = self:findBookByMD5(meta.partial_md5)
    end
    if not book or not book.progress or not book.progress.rev or book.progress.rev == 0 then
        return
    end
    local entry = self.index:get(meta.file) or {}
    if (entry.last_rev or 0) >= book.progress.rev then
        return
    end

    local current_position, current_percentage = self:currentPosition()
    if tostring(book.progress.position) == tostring(current_position)
        or (book.progress.percentage and current_percentage
            and math.abs(book.progress.percentage - current_percentage) < 0.001) then
        self.index:update(meta.file, {
            book_id = book.id,
            partial_md5 = meta.partial_md5,
            uploaded = book.upload_required == false,
            last_rev = book.progress.rev,
        })
        if interactive then self:showInfo(_("Progress is already up to date.")) end
        return
    end

    local function apply()
        self:gotoPosition(book.progress.position)
        self.index:update(meta.file, {
            book_id = book.id,
            partial_md5 = meta.partial_md5,
            uploaded = book.upload_required == false,
            last_rev = book.progress.rev,
        })
        self:showInfo(T(_("Moved to %1% from another device."),
            math.floor((book.progress.percentage or 0) * 100)))
    end

    if interactive then
        apply()
    else
        UIManager:show(ConfirmBox:new{
            text = T(_("Sync to position %1% from another device?"),
                math.floor((book.progress.percentage or 0) * 100)),
            ok_text = _("Go"),
            ok_callback = apply,
            cancel_callback = function()
                self.index:update(meta.file, { last_rev = book.progress.rev })
            end,
        })
    end
end

-- -------------------------------------------------------------------- queue

function ShelfSync:flushQueue(interactive)
    if not self:isLoggedIn() then return end
    if self.flushing then return end
    if not NetworkMgr:isOnline() then
        if interactive then
            NetworkMgr:willRerunWhenOnline(function() self:flushQueue(true) end)
        end
        return
    end
    self.flushing = true
    local items = {}
    for _, item in ipairs(self.queue:all()) do
        table.insert(items, item)
    end

    local sent, failed, uploads = 0, 0, 0
    for _, item in ipairs(items) do
        if not item.give_up then
            local ok, err
            if item.kind == "upload" then
                ok, err = self:doUpload(item, interactive)
                if ok then uploads = uploads + 1 end
            elseif item.kind == "progress" then
                ok, err = self:doProgress(item, false)
            end
            if ok then
                self.queue:remove(item)
                sent = sent + 1
            else
                self.queue:fail(item, err)
                failed = failed + 1
                if err == "unauthorized" then
                    self.token = nil
                    self.client.token = nil
                    self:saveSettings()
                    break
                end
            end
        end
    end
    self.flushing = false
    if sent > 0 then
        self:refreshLibrary()
    end
    if interactive then
        self:showInfo(T(_("Shelf sync: %1 sent, %2 failed."), sent, failed), 5)
    end
end

function ShelfSync:syncNow()
    if not self:isLoggedIn() then
        self:showLoginDialog()
        return
    end
    if not NetworkMgr:isOnline() then
        NetworkMgr:willRerunWhenOnline(function() self:syncNow() end)
        return
    end
    self:flushQueue(true)
    self:pullProgress(true)
    self:refreshLibrary()
end

-- --------------------------------------------------------------------- shelf

function ShelfSync:showShelf()
    if not self:isLoggedIn() then
        self:showLoginDialog()
        return
    end
    if not NetworkMgr:isOnline() then
        NetworkMgr:willRerunWhenOnline(function() self:showShelf() end)
        return
    end
    local books = self:refreshLibrary()
    if not books then return end
    if #books == 0 then
        self:showInfo(_("The shelf is empty."))
        return
    end

    local items = {}
    for _, book in ipairs(books) do
        if not book.deleted then
            local local_path = self.index:find_by_book_id(book.id)
            local percent = book.progress and book.progress.percentage or 0
            local title = book.title or book.filename or book.id
            if book.authors and book.authors ~= "" then
                title = title .. " — " .. book.authors
            end
            table.insert(items, {
                text = title,
                mandatory = T(_("%1% · %2"), math.floor(percent * 100),
                    local_path and _("on device") or _("on server")),
                callback = function()
                    if local_path and lfs.attributes(local_path, "mode") == "file" then
                        filemanagerutil.openFile(self.ui, local_path)
                    else
                        self:downloadBook(book)
                    end
                end,
            })
        end
    end

    UIManager:show(Menu:new{
        title = _("Shelf"),
        item_table = items,
        width = Device.screen:getWidth() * 0.9,
        title_bar_fm_style = true,
    })
end

function ShelfSync:downloadBook(book)
    local dir = self.download_dir or G_reader_settings:readSetting("lastdir")
    if not dir or lfs.attributes(dir, "mode") ~= "directory" then
        dir = DataStorage:getDataDir() .. "/shelf"
    end
    util.makePath(dir)
    local filename = (book.filename or "book"):match("([^/\\]+)$") or "book"
    local dest = dir .. "/" .. filename
    local suffix = 1
    while lfs.attributes(dest, "mode") == "file" do
        suffix = suffix + 1
        dest = string.format("%s/%s (%d)%s", dir, filename:match("^(.-)(%.[^%.]+)$") or filename,
            suffix, filename:match("%.[^%.]+$") or "")
    end

    UIManager:show(ConfirmBox:new{
        text = T(_("Download \"%1\" to:\n%2?"), book.title or filename, BD.dirpath(dir)),
        ok_text = _("Download"),
        ok_callback = function()
            local dialog = ProgressbarDialog:new{
                title = T(_("Downloading %1"), filename),
                progress_max = book.size,
            }
            dialog:show()
            local ok, code, err = self.client:download_file(book.id, dest, book.size,
                function(progress) dialog:reportProgress(progress) end)
            dialog:close()
            if not ok then
                os.remove(dest)
                self:handleError(code, err, _("download"))
                return
            end
            self.index:update(dest, {
                book_id = book.id,
                partial_md5 = book.partial_md5,
                uploaded = true,
                size = lfs.attributes(dest, "size"),
            })
            UIManager:show(ConfirmBox:new{
                text = T(_("Downloaded to:\n%1\nOpen now?"), BD.filepath(dest)),
                ok_text = _("Open"),
                ok_callback = function()
                    filemanagerutil.openFile(self.ui, dest)
                end,
            })
        end,
    })
end

function ShelfSync:showQueue()
    local items = {}
    for _, item in ipairs(self.queue:all()) do
        local name = item.filename or (item.path and item.path:match("([^/\\]+)$")) or item.path
        table.insert(items, {
            text = string.format("%s · %s", item.kind, name or "?"),
            mandatory = item.give_up and _("failed") or
                T(_("%1 attempts"), item.attempts or 0),
        })
    end
    if #items == 0 then
        items = {{ text = _("The queue is empty."), enabled = false }}
    else
        table.insert(items, {
            text = _("Retry all"),
            callback = function()
                for _, item in ipairs(self.queue:all()) do
                    item.give_up = nil
                    item.attempts = 0
                end
                self.queue:save()
                self:flushQueue(true)
            end,
        })
    end
    UIManager:show(Menu:new{
        title = T(_("Shelf sync queue (%1)"), self.queue:count()),
        item_table = items,
        width = Device.screen:getWidth() * 0.9,
        title_bar_fm_style = true,
    })
end

-- ------------------------------------------------------------------ settings

function ShelfSync:showServerDialog()
    local dialog
    dialog = InputDialog:new{
        title = _("Shelf server URL"),
        input = self.server_url or "",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Save"),
                    callback = function()
                        local url = dialog:getInputText()
                        UIManager:close(dialog)
                        if url and url ~= "" then
                            self.server_url = Client.normalize_url(url)
                            self.client = Client:new{ base_url = self.server_url, token = self.token }
                            self:saveSettings()
                            self:showInfo(_("Server address saved."))
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function ShelfSync:showDeviceDialog()
    local dialog
    dialog = InputDialog:new{
        title = _("Device name"),
        input = self.device_name or "",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Save"),
                    callback = function()
                        local name = dialog:getInputText()
                        UIManager:close(dialog)
                        if name and name ~= "" then
                            self.device_name = name
                            self:saveSettings()
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function ShelfSync:showDownloadDirDialog()
    local dialog
    dialog = InputDialog:new{
        title = _("Shelf download folder"),
        input = self.download_dir or "",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Save"),
                    callback = function()
                        local path = dialog:getInputText()
                        UIManager:close(dialog)
                        if path and path ~= "" then
                            if lfs.attributes(path, "mode") ~= "directory" then
                                self:showInfo(_("This folder does not exist."))
                                return
                            end
                            self.download_dir = path
                            self:saveSettings()
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function ShelfSync:showLoginDialog()
    local dialog
    local fields = {
        {
            text = self.username or "",
            hint = _("Username"),
        },
        {
            text = "",
            text_type = "password",
            hint = _("Password"),
        },
    }
    dialog = MultiInputDialog:new{
        title = _("Shelf sync login"),
        fields = fields,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Login"),
                    callback = function()
                        local values = dialog:getFields()
                        UIManager:close(dialog)
                        self:doLogin(values[1], values[2])
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function ShelfSync:doLogin(username, password)
    if not username or username == "" or not password or password == "" then
        self:showInfo(_("Username and password are required."))
        return
    end
    self.server_url = Client.normalize_url(self.server_url)
    local client = Client:new{ base_url = self.server_url }
    local data, code, err = client:login(username, password, self.device_id)
    if not data then
        self:handleError(code, err, _("login"))
        return
    end
    self.username = username
    self.token = data.token
    self.device_id = data.device_id
    self.client = Client:new{ base_url = self.server_url, token = self.token }
    self:saveSettings()
    self:showInfo(T(_("Logged in as %1."), username))
    self:refreshLibrary()
end

function ShelfSync:doLogout()
    self.token = nil
    self.client.token = nil
    self:saveSettings()
    self:showInfo(_("Logged out from shelf sync."))
end

function ShelfSync:getSettingsMenuTable()
    return {
        {
            text = _("Server address"),
            callback = function() self:showServerDialog() end,
        },
        {
            text_func = function()
                return self:isLoggedIn()
                    and T(_("Logged in as %1"), self.username or "?")
                    or _("Log in")
            end,
            sub_item_table_func = function()
                local items = {
                    {
                        text = _("Log in to the shelf"),
                        callback = function() self:showLoginDialog() end,
                    },
                }
                if self:isLoggedIn() then
                    table.insert(items, {
                        text = _("Log out"),
                        callback = function() self:doLogout() end,
                    })
                end
                return items
            end,
        },
        {
            text = _("Device name"),
            callback = function() self:showDeviceDialog() end,
        },
        {
            text = _("Upload books when opened"),
            checked_func = function() return self.auto_upload end,
            callback = function()
                self.auto_upload = not self.auto_upload
                self:saveSettings()
            end,
        },
        {
            text = _("Sync progress automatically"),
            checked_func = function() return self.auto_progress end,
            callback = function()
                self.auto_progress = not self.auto_progress
                self:saveSettings()
            end,
        },
        {
            text = _("Download folder"),
            callback = function() self:showDownloadDirDialog() end,
        },
    }
end

-- --------------------------------------------------------------------- menu

function ShelfSync:addToMainMenu(menu_items)
    menu_items.shelfsync = {
        text = _("Shelf sync"),
        sub_item_table = {
            {
                text = _("Shelf"),
                callback = function() self:showShelf() end,
            },
            {
                text = _("Sync now"),
                callback = function() self:syncNow() end,
            },
            {
                text = _("Upload current book"),
                enabled_func = function() return self.ui and self.ui.document ~= nil end,
                callback = function() self:queueCurrentBook() end,
            },
            {
                text_func = function()
                    return T(_("Queue (%1)"), self.queue:count())
                end,
                callback = function() self:showQueue() end,
            },
            {
                text = _("Settings"),
                sub_item_table = self:getSettingsMenuTable(),
            },
        },
    }
end

-- -------------------------------------------------------------------- hooks

function ShelfSync:onReaderReady()
    if not self:isLoggedIn() then return end
    self.page_counter = 0
    if self.auto_progress then
        UIManager:nextTick(function() self:pullProgress(false) end)
    end
    if self.auto_upload then
        UIManager:scheduleIn(3, function() self:queueCurrentBook() end)
    end
end

function ShelfSync:onPageUpdate(page)
    if not self:isLoggedIn() or not self.auto_progress then return end
    self.page_counter = (self.page_counter or 0) + 1
    if self.page_counter >= 10 then
        self.page_counter = 0
        self:pushProgress(false)
    end
end

function ShelfSync:onCloseDocument()
    if self:isLoggedIn() then
        self:pushProgress(false)
        UIManager:scheduleIn(2, function() self:flushQueue(false) end)
    end
end

function ShelfSync:onSuspend()
    if self:isLoggedIn() then
        self:pushProgress(false)
    end
end

function ShelfSync:onNetworkConnected()
    if self:isLoggedIn() then
        UIManager:scheduleIn(2, function() self:flushQueue(false) end)
    end
end

function ShelfSync:onResume()
    if self:isLoggedIn() and NetworkMgr:isOnline() then
        UIManager:scheduleIn(2, function() self:flushQueue(false) end)
    end
end

return ShelfSync
