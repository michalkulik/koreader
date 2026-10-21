--[[--
Small clock painted in the top-right corner of the current UI.

It is not a window: the reader paints it as a ReaderView view module, and the
file manager paints it after its normal content. This keeps input, menus and
the screensaver completely untouched.
]]

local Font = require("ui/font")
local Geom = require("ui/geometry")
local Screen = require("device").screen
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local datetime = require("datetime")
local logger = require("logger")

local ClockWidget = TextWidget:extend{
    padding = 3,
}

function ClockWidget:init()
    self.padding = Screen:scaleBySize(3)
    self.face = Font:getFace("cfont", Screen:scaleBySize(14))
    self.text = datetime.secondsToHour(os.time(),
        G_reader_settings:isTrue("twelve_hour_clock"))
    local probe = TextWidget:new{ text = "88:88 WWW", face = self.face, padding = 0 }
    local probe_size = probe:getSize()
    probe:free()
    self.width = math.max(probe_size.w, self:getSize().w)
    self.height = probe_size.h
end

function ClockWidget:updateTime()
    local text = datetime.secondsToHour(os.time(),
        G_reader_settings:isTrue("twelve_hour_clock"))
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

function ScreenClock:_ensureWidget()
    if self.widget then return true end
    if not self:isEnabled() or not self.host then return false end
    local ok, widget = pcall(ClockWidget.new, ClockWidget)
    if not ok then
        logger.err("ScreenClock: creation failed:", widget)
        return false
    end
    self.widget = widget
    if self.host.view and self.host.view.view_modules then
        self.host.view:registerViewModule("screen_clock", self.widget)
    else
        self.host.screen_clock_widget = self.widget
    end
    return true
end

function ScreenClock:attach(host)
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
end

return ScreenClock
