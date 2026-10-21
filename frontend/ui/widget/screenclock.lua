--[[--
Small always-on-top clock in the top-right corner of the screen.

The overlay is deliberately a plain Widget: it does not consume input events,
so taps still reach the reader/file manager underneath it.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local Screen = require("device").screen
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local Widget = require("ui/widget/widget")
local datetime = require("datetime")

local ClockWidget = Widget:extend{
    covers_fullscreen = false,
    disable_double_tap = G_reader_settings:nilOrTrue("disable_double_tap"),
    padding = Screen:scaleBySize(3),
    margin = Screen:scaleBySize(3),
    fgcolor = Blitbuffer.COLOR_BLACK,
    bgcolor = Blitbuffer.COLOR_WHITE,
}

function ClockWidget:init()
    self.disable_double_tap = G_reader_settings:nilOrTrue("disable_double_tap")
    self.face = Font:getFace("cfont", Screen:scaleBySize(14))

    -- Keep the overlay width stable across 9:59 -> 10:00 so the erased area
    -- is always exactly the same rectangle.
    local probe = TextWidget:new{ text = "88:88 WWW", face = self.face, padding = 0 }
    local probe_size = probe:getSize()
    probe:free()
    self.dimen = Geom:new{
        x = 0,
        y = 0,
        w = probe_size.w + 2 * self.padding,
        h = probe_size.h + 2 * self.padding,
    }
    self:_reposition()
    self:updateTime()
end

function ClockWidget:_reposition()
    self.dimen.x = Screen:getWidth() - self.dimen.w - self.margin
    self.dimen.y = self.margin
end

function ClockWidget:updateTime()
    local text = datetime.secondsToHour(os.time(),
        G_reader_settings:isTrue("twelve_hour_clock"))
    if text == self.text then return false end
    self.text = text
    if self.text_widget then self.text_widget:free() end
    self.text_widget = TextWidget:new{
        text = text,
        face = self.face,
        fgcolor = self.fgcolor,
        padding = 0,
    }
    self._text_size = self.text_widget:getSize()
    return true
end

function ClockWidget:paintTo(bb, x, y)
    if not self.text_widget then self:updateTime() end
    local w, h = self.dimen.w, self.dimen.h
    if not self._bb or self._bb:getWidth() ~= w or self._bb:getHeight() ~= h
        or self._bb:getType() ~= bb:getType() then
        if self._bb then self._bb:free() end
        self._bb = Blitbuffer.new(w, h, bb:getType())
    end
    self._bb:fill(self.bgcolor)
    self.text_widget:paintTo(self._bb,
        math.floor((w - self._text_size.w) / 2),
        math.floor((h - self._text_size.h) / 2))
    bb:blitFrom(self._bb, self.dimen.x + x, self.dimen.y + y)
end

function ClockWidget:free()
    if self._bb then
        self._bb:free()
        self._bb = nil
    end
    if self.text_widget then
        self.text_widget:free()
        self.text_widget = nil
    end
end

local ScreenClock = {
    widget = nil,
}

function ScreenClock:isEnabled()
    return G_reader_settings:isTrue("screen_clock")
end

function ScreenClock:_schedule()
    UIManager:unschedule(self._tick, self)
    local t = os.date("*t")
    UIManager:scheduleIn(60 - (t.sec or 0) + 0.05, self._tick, self)
end

function ScreenClock:_tick()
    self:refresh()
end

function ScreenClock:refresh(force)
    if not self:isEnabled() then
        self:hide()
        return
    end
    if not self.widget then
        self.widget = ClockWidget:new{}
        UIManager:show(self.widget, "ui", self.widget.dimen)
    else
        local changed = self.widget:updateTime()
        if changed or force then
            UIManager:setDirty(self.widget, "ui", self.widget.dimen)
        end
    end
    self:_schedule()
end

function ScreenClock:refreshLayout()
    if not self.widget then return end
    self.widget:_reposition()
    UIManager:setDirty(self.widget, "ui", self.widget.dimen)
end

function ScreenClock:show(raise)
    if not self:isEnabled() then
        self:hide()
        return
    end
    if self.widget and raise then
        local old = self.widget
        self.widget = nil
        UIManager:close(old, "ui", old.dimen)
        old:free()
    end
    if self.widget then
        self:refresh()
    else
        self.widget = ClockWidget:new{}
        UIManager:show(self.widget, "ui", self.widget.dimen)
        self:_schedule()
    end
end

function ScreenClock:hide()
    UIManager:unschedule(self._tick, self)
    if self.widget then
        local widget = self.widget
        self.widget = nil
        UIManager:close(widget, "ui", widget.dimen)
        widget:free()
    end
end

return ScreenClock
