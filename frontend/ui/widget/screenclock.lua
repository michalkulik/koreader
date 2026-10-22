--[[--
Small clock painted in the top-right corner of the current UI.

It is not a window: the reader paints it as a ReaderView view module, and the
file manager paints it after its normal content. This keeps input, menus and
the screensaver completely untouched.
]]

local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local Screen = Device.screen
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local datetime = require("datetime")
local logger = require("logger")

-- Android screens are much denser than e-ink ones, so the same scaled font
-- size ends up far too large there and overlaps the first line of the book.
local IS_ANDROID = Device:isAndroid()

local function fontSize()
    return Screen:scaleBySize(IS_ANDROID and 10 or 14)
end

local function verticalPadding()
    return Screen:scaleBySize(IS_ANDROID and 2 or 3)
end

local function getBatteryText()
    if not Device:hasBattery() then return nil end
    local powerd = Device:getPowerDevice()
    if not powerd then return nil end
    local ok, capacity = pcall(powerd.getCapacity, powerd)
    if not ok or type(capacity) ~= "number" then return nil end
    local charging = false
    local ok_charging, is_charging = pcall(powerd.isCharging, powerd)
    if ok_charging then charging = is_charging end
    return string.format("%s%d%%", charging and "+" or "", math.floor(capacity))
end

local ClockWidget = TextWidget:extend{
    padding = 3,
}

function ClockWidget:getDisplayText()
    local text = datetime.secondsToHour(os.time(),
        G_reader_settings:isTrue("twelve_hour_clock"))
    if G_reader_settings:isTrue("screen_clock_battery") then
        local battery = getBatteryText()
        if battery then
            text = text .. "  " .. battery
        end
    end
    return text
end

function ClockWidget:init()
    self.padding = verticalPadding()
    self.face = Font:getFace("cfont", fontSize())
    self.text = self:getDisplayText()
    -- Reserve room for the widest possible content so the position stays
    -- stable when the time or the battery percentage changes.
    local probe = TextWidget:new{
        text = "88:88 WWW +100%",
        face = self.face,
        padding = 0,
    }
    local probe_size = probe:getSize()
    probe:free()
    self.width = math.max(probe_size.w, self:getSize().w)
    self.height = probe_size.h
end

function ClockWidget:updateTime()
    local text = self:getDisplayText()
    if text == self.text then return false end
    self:setText(text)
    return true
end

function ClockWidget:paintTo(bb)
    if not G_reader_settings:isTrue("screen_clock") then return end
    local size = self:getSize()
    local x = Screen:getWidth() - self.width - self.padding
        + math.floor((self.width - size.w) / 2)
    local ok, err = pcall(TextWidget.paintTo, self, bb, x, self.padding)
    if not ok then logger.err("ScreenClock: paint failed:", err) end
end

local ScreenClock = {
    host = nil,
    widget = nil,
}

function ScreenClock:isEnabled()
    return G_reader_settings:isTrue("screen_clock")
end

function ScreenClock:region()
    local w = self.widget
    if not w then return nil end
    return Geom:new{
        x = Screen:getWidth() - w.width - w.padding,
        y = w.padding,
        w = w.width,
        h = w.height,
    }
end

function ScreenClock:_schedule()
    UIManager:unschedule(self._tick, self)
    if not self.host or not self:isEnabled() then return end
    local t = os.date("*t")
    UIManager:scheduleIn(60 - (t.sec or 0) + 0.05, self._tick, self)
end

function ScreenClock:_tick()
    self:refresh()
end

-- Register the widget with the host that is currently on screen. The clock is
-- a singleton shared by the file manager and every ReaderUI instance, so this
-- has to run on every attach, not only when the widget is first created.
function ScreenClock:_register()
    local host = self.host
    if not host or not self.widget then return end
    if host.view and host.view.view_modules then
        host.view:registerViewModule("screen_clock", self.widget)
    else
        host.screen_clock_widget = self.widget
    end
end

function ScreenClock:_ensureWidget()
    if not self:isEnabled() or not self.host then return false end
    if not self.widget then
        local ok, widget = pcall(function() return ClockWidget:new() end)
        if not ok then
            logger.err("ScreenClock: creation failed:", widget)
            return false
        end
        self.widget = widget
    end
    self:_register()
    return true
end

function ScreenClock:attach(host)
    if self.host and self.host ~= host and self.host.screen_clock_widget == self.widget then
        -- Do not let a closed file manager keep painting our widget.
        self.host.screen_clock_widget = nil
    end
    self.host = host
    if self:_ensureWidget() then
        self.widget:updateTime()
    end
    self:_schedule()
end

function ScreenClock:refresh(force)
    if not self.host then return end
    if not self:isEnabled() then
        UIManager:unschedule(self._tick, self)
        if self.widget then
            local region = self:region()
            if region then UIManager:setDirty(self.host, "ui", region) end
        end
        return
    end
    if not self:_ensureWidget() then return end
    if self.widget:updateTime() or force then
        UIManager:setDirty(self.host, "ui", self:region())
    end
    self:_schedule()
end

function ScreenClock:refreshLayout()
    if not self.host or not self.widget then return end
    UIManager:setDirty(self.host, "ui", self:region())
end

function ScreenClock:hide()
    UIManager:unschedule(self._tick, self)
    self.host = nil
end

return ScreenClock
