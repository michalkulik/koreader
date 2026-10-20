--[[--
Checks for updates on the specified nightly build server.
]]

local BD = require("ui/bidi")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local MultiConfirmBox = require("ui/widget/multiconfirmbox")
local NetworkMgr = require("ui/network/manager")
local ProgressbarDialog = require("ui/widget/progressbardialog")
local UIManager = require("ui/uimanager")
local Trapper = require("ui/trapper")
local Version = require("version")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local C_ = _.pgettext
local ffiUtil = require("ffi/util")
local T = ffiUtil.template

local ota_dir = DataStorage:getDataDir() .. "/ota/"

local OTAManager = {
    -- NOTE: Each URL *MUST* end with a /
    -- This fork publishes its own OTA assets on GitHub releases:
    --   koreader-android-arm64-latest-stable  (text manifest, 1st line = APK name)
    --   koreader-android-arm64-<version>.apk
    --   latest.json                          (version/sha256 metadata)
    -- GitHub redirects /releases/latest/download/<asset> to the real asset;
    -- fetch_text_follow_redirects() below handles that.
    ota_servers = {
        "https://github.com/michalkulik/koreader/releases/latest/download/",
    },
    ota_channels = {
        "stable",
        "nightly",
    },
    kotasync_template = "koreader-%s-latest-%s.kotasync",
    kotasync_update_package = ota_dir .. "update.tar.xz",
    link_template = "koreader-%s-latest-%s",
}

local ota_channels = {
    stable = _("Stable"),
    nightly = _("Development (nightly build)"),
}

function OTAManager:getOTAType()
    local platform, kind = Device:otaModel()
    if not platform then return "none" end
    return kind
end

function OTAManager:getOTAServer()
    local server = G_reader_settings:readSetting("ota_server")
    if not server or server == "" then
        return self.ota_servers[1]
    end
    -- Migrate old upstream defaults to this fork's feed. Otherwise an old
    -- saved setting would keep offering official KOReader builds.
    if server:match("ota%.koreader%.rocks")
        or server:match("github%.com/koreader/koreader")
        or server:match("ak%-team%.com") then
        server = self.ota_servers[1]
        G_reader_settings:saveSetting("ota_server", server)
    end
    return server
end

function OTAManager:setOTAServer(server)
    logger.dbg("Set OTA server:", server)
    G_reader_settings:saveSetting("ota_server", server)
end

function OTAManager:getOTAChannel()
    return G_reader_settings:readSetting("ota_channel") or self.ota_channels[1]
end

function OTAManager:setOTAChannel(channel)
    logger.dbg("Set OTA channel:", channel)
    G_reader_settings:saveSetting("ota_channel", channel)
end

function OTAManager:getOTAUnpackDir()
    return select(3, Device:otaModel()) or ".."
end

function OTAManager:getFilename(kind)
    if type(kind) ~= "string" then return end
    local model = Device:otaModel()
    local channel = self:getOTAChannel()
    if kind == "kotasync" then
        return self.kotasync_template:format(model, channel)
    elseif kind == "link" then
        return self.link_template:format(model, channel)
    end
end

local function fetch_text_follow_redirects(url)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")

    socketutil:set_timeout()
    local current = url
    local data, err
    for _ = 1, 5 do
        local chunks = {}
        local code, headers, status = socket.skip(1, http.request{
            url = current,
            sink = ltn12.sink.table(chunks),
        })
        if code == 200 then
            data = table.concat(chunks)
            break
        elseif code == 301 or code == 302 or code == 303
            or code == 307 or code == 308 then
            local location = headers and headers.location
            if not location then
                err = status or code
                break
            end
            if location:match("^https?://") then
                current = location
            elseif location:sub(1, 2) == "//" then
                local scheme = current:match("^(https?:)")
                current = scheme .. location
            elseif location:sub(1, 1) == "/" then
                local scheme_host = current:match("^(https?://[^/]+)")
                current = scheme_host .. location
            else
                local base = current:match("^(.*/)") or current
                current = base .. location
            end
        else
            err = status or code
            break
        end
    end
    socketutil:reset_timeout()
    return data, err
end

function OTAManager:checkUpdate()
    if Device:isDeprecated() then return -1 end

    local update_kind = self:getOTAType()
    if not update_kind then return -1 end

    local update_file = self:getFilename(update_kind)
    if not update_file then return -2 end

    local ota_update_file = self:getOTAServer() .. update_file
    local link, ota_package

    logger.dbg("downloading update file", ota_update_file)

    local ota_type = self:getOTAType()
    if ota_type == "kotasync" then
        self.updater = require("ffi/updater"):new(ota_update_file, ota_dir, self:getOTAUnpackDir(), "ffi/kotasync")
        local ok, err = pcall(self.updater.fetch_manifest, self.updater)
        if not ok then
            return nil, err
        end
        ota_package = err
    elseif ota_type == "link" then
        local local_update_file = ota_dir .. update_file
        local content, err = fetch_text_follow_redirects(ota_update_file)
        if not content then
            logger.dbg("OTA check failed:", ota_update_file, err)
            return nil, err or "network unreachable"
        end
        local file = io.open(local_update_file, "w")
        if file then
            file:write(content)
            file:close()
        end
        -- The first line is either the APK asset name or an absolute URL.
        local first = content:match("^([^\r\n]+)")
        if first then
            first = first:gsub("^%s+", ""):gsub("%s+$", "")
        end
        if first and first ~= "" then
            if first:match("^https?://") then
                ota_package = first:match("([^/\\]+)$") or first
                link = first
            else
                ota_package = first
                link = self:getOTAServer() .. first
            end
        end
    end
    local local_ok, local_version = pcall(function()
        local rev = Version:getCurrentRevision()
        if rev then return Version:getNormalizedVersion(rev) end
    end)
    local ota_ok, ota_version = pcall(function()
        return Version:getNormalizedVersion(ota_package)
    end)
    -- return ota package version if package on OTA server has version
    -- larger than the local package version
    if local_ok and ota_ok and ota_version and local_version and
        ota_version ~= local_version then
        return ota_version, local_version, link, ota_package
    elseif ota_version and ota_version == local_version then
        return 0
    end
end

local co_confirm = function(text, ok_text, cancel_text)
    local co = coroutine.running()
    UIManager:show(ConfirmBox:new{
        text = text,
        ok_text = ok_text, ok_callback = function() coroutine.resume(co, true) end,
        cancel_text = cancel_text, cancel_callback = function() coroutine.resume(co, false) end,
    })
    return coroutine.yield()
end

local co_choose = function(text, choice1_text, choice2_text, cancel_text)
    local co = coroutine.running()
    UIManager:show(MultiConfirmBox:new{
        text = text,
        choice1_text = choice1_text, choice1_callback = function() coroutine.resume(co, 1) end,
        choice2_text = choice2_text, choice2_callback = function() coroutine.resume(co, 2) end,
        cancel_text = cancel_text, cancel_callback = function() coroutine.resume(co, false) end,
    })
    return coroutine.yield()
end

function OTAManager:fetchAndProcessUpdate()
    if Device:hasOTARunning() then
        UIManager:show(InfoMessage:new{
            text = _("Download already scheduled. You'll be notified when it's ready."),
        })
        return
    end

    -- Ensure we're running in a coroutine.
    local co = coroutine.running()
    if not co then
        Trapper:wrap(function()
            self:fetchAndProcessUpdate()
            -- Cleanup…
            if self.updater then
                self.updater:free()
                self.updater = nil
            end
        end)
        return
    end
    local re = function(res) coroutine.resume(co, res) end

    -- Ensure network is online.
    if NetworkMgr:willRerunWhenConnected(re) then
        coroutine.yield()
        if not NetworkMgr:isConnected() then
            return
        end
    end

    local ota_version, local_version, link, ota_package = self:checkUpdate()

    if ota_version == 0 then
        UIManager:show(InfoMessage:new{
            text = _("KOReader is up to date."),
        })
        return
    elseif ota_version == -1 then
        UIManager:show(InfoMessage:new{
            text = T(_("Device no longer supported.\n\nPlease check %1"), "https://github.com/koreader/koreader/wiki/deprecated-devices")
        })
        return
    elseif ota_version == -2 then
        UIManager:show(InfoMessage:new{
            text = _("Unable to determine OTA model.")
        })
        return
    elseif not ota_version then
        logger.warn("OTA check failed:", local_version)
        UIManager:show(InfoMessage:new{
            text = _("Unable to contact OTA server. Try again later, or try another mirror."),
        })
        return
    end

    local update_message = T(_("Do you want to update?\nInstalled version: %1\nAvailable version: %2"),
                             BD.ltr(local_version),
                             BD.ltr(ota_version))
    local update_ok_text = C_("Application update | Button", "Update")
    if ota_version < local_version then
        -- Android cannot downgrade APKs. The user needs to uninstall current app first.
        -- Instead of doing the auto-update when ready we just download the APK using the browser.
        if Device:isAndroid() then
            UIManager:show(ConfirmBox:new{
                text = T(_("The currently installed version is newer than the available version.\nYou'll need to uninstall the app before installing a previous version.\nDownload anyway?\n\nInstalled version: %1\nAvailable version: %2"),
                    BD.ltr(local_version),
                    BD.ltr(ota_version)),
                ok_text = _("Download"),
                ok_callback = function()
                    Device:openLink(link)
                end,
            })
            return
        end
        update_message =  T(_("The currently installed version is newer than the available version.\nWould you still like to continue and downgrade?\nInstalled version: %1\nAvailable version: %2"),
                            BD.ltr(local_version),
                            BD.ltr(ota_version))
        update_ok_text = _("Downgrade")
    end

    if self:getOTAType() == "link" then
        UIManager:show(ConfirmBox:new{
            text = update_message,
            ok_text = update_ok_text,
            ok_callback = function()
                if Device:isAndroid() then
                    Device:download(link, ota_package, _("Downloading may take several minutes…"))
                elseif Device:isSDL() then
                    Device:openLink(link)
                end
            end
        })
        return
    end

    if not co_confirm(update_message, update_ok_text) then
        return
    end

    local ok, err

    ok, err = self:_prepareUpdate()
    if not ok then
        -- Canceled or errored.
        logger.warn("failed to prepare OTA update:", err)
        return
    end
    local stats = err

    if not co_confirm(T(_("Need to fetch %1 out of %2 files (%3), proceed?"), stats.missing_files, stats.total_files, util.getFriendlySize(stats.download_size))) then
        return
    end

    while true do

        ok, err = self:_fetchUpdate()
        if ok then
            Device:install()
            return
        end
        logger.warn("failed to fetch OTA update:", err)

        local choice = err == "aborted" and 2 or co_choose(
            _("Downloading update failed, you can:\nCancel, keeping temporary files.\nRetry the update process.\nAbort and cleanup all temporary files."),
            _("Retry"), _("Abort")
        )
        if choice == 1 then -- luacheck: ignore 542
            -- Retry.
        elseif choice == 2 then
            -- Abort.
            local ota_file = ota_dir..self:getFilename("kotasync")
            os.remove(ota_file)
            os.remove(ota_file..".etag")
            os.remove(self.kotasync_update_package..".part")
            break
        else
            -- Cancel.
            break
        end

    end
end

local function progress_dialog(title, max, dismiss_text)
    local co = coroutine.running()
    local dialog = ProgressbarDialog:new {
        title = title,
        progress_max = max,
        refresh_time_seconds = Device:hasEinkScreen() and 0.5 or 0.1,
        cancel = function() coroutine.resume(co, true) end,
        resume = function() coroutine.resume(co) end,
        dismiss_text = dismiss_text,
    }
    dialog.dismiss_callback = dialog.cancel
    local refresh = function(delay)
        if delay then
            UIManager:scheduleIn(delay, dialog.resume)
        else
            UIManager:nextTick(dialog.resume)
        end
        return coroutine.yield()
    end
    function dialog:update(n, delay)
        if self:reportProgress(n) then
            return refresh(delay)
        end
    end
    UIManager:show(dialog)
    UIManager:forceRePaint()
    refresh()
    return dialog
end

function OTAManager:_prepareUpdate()
    local progress
    local aborted = false
    local ok, err = pcall(self.updater.prepare_update, self.updater, function(count, total)
        if not progress then
            progress = progress_dialog(_("Analyzing local install…"), total, _("Abort?"))
        end
        if progress:update(count, 0.05) then
            aborted = true
            return false
        end
        return true
    end)
    if progress then
        progress:close()
    end
    if aborted then
        return false, "aborted"
    end
    return ok, err
end

function OTAManager:_fetchUpdate()
    local progress
    local aborted = false
    local ok, err = pcall(self.updater.download_update, self.updater, function(count, total)
        if not progress then
            progress = progress_dialog(_("Downloading update…"), total, _("Abort?"))
        end
        if progress:update(count, 0.05) then
            aborted = true
            return false
        end
        return true
    end)
    if progress then
        progress:close()
    end
    if aborted then
        return false, "aborted"
    end
    return ok, err
end

function OTAManager:genServerList()
    local servers = {}
    for _, server in ipairs(self.ota_servers) do
        local server_item = {
            text = server,
            checked_func = function() return self:getOTAServer() == server end,
            callback = function() self:setOTAServer(server) end
        }
        table.insert(servers, server_item)
    end
    return servers
end

function OTAManager:genChannelList()
    local channels = {}
    for _, channel in ipairs(self.ota_channels) do
        local channel_item = {
            text = ota_channels[channel],
            checked_func = function() return self:getOTAChannel() == channel end,
            callback = function() self:setOTAChannel(channel) end
        }
        table.insert(channels, channel_item)
    end
    return channels
end

function OTAManager:getOTAMenuTable()
    return {
        text = C_("Application update | Menu", "Update"),
        hold_callback = function()
            OTAManager:fetchAndProcessUpdate()
        end,
        sub_item_table = {
            {
                text = _("Check for updates"),
                callback = function()
                    OTAManager:fetchAndProcessUpdate()
                end
            },
            {
                text = _("Settings"),
                sub_item_table = {
                    {
                        text = _("Update server"),
                        sub_item_table = self:genServerList()
                    },
                    {
                        text = _("Update channel"),
                        sub_item_table = self:genChannelList()
                    },
                    {
                        text = T(_("Source: %1"), "github.com/michalkulik/koreader"),
                        callback = function()
                            Device:openLink("https://github.com/michalkulik/koreader/releases")
                        end,
                    },
                }
            },
        }
    }
end

return OTAManager
