--[[--
Small always-on-top clock in the top-right corner of the screen.

The overlay is a toast: it never steals input from the reader/file manager
underneath it. It is only painted while its host UI is the topmost window, so
menus, dialogs and the screensaver naturally cover it.
]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local Screen = require("device").screen
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local datetime = require("datetime")
local logger = require("logger")

local ClockWidget = FrameContainer:extend{
    toast = true,
    covers_fullscreen = false,
    bordersize = 0,
    margin = 0,
    background = Blitbuffer.COLOR_WHITE,
    padding = Screen:scaleBySize(3),
}

local function host_is_top(host)
    for i = #UIManager._window_stack, 1, -1 do
        local widget = UIManager._window_stack[i].widget
        if not widget.toast then
            return widget == host
        end
    end
    return false
end

function ClockWidget:init()
    self.disable_double_tap = G_reader_settings:nilOrTrue("disable_double_tap")
    self.face = Font:getFace("cfont", Screen:scaleBySize(14))

    -- Keep the overlay width stable across 9:59 -> 10:00 and across 12-hour
    -- AM/PM strings.
    local probe = TextWidget:new{ text = "88:88 WWW", face = self.face, padding = 0 }
    local probe_size = probe:getSize()
    probe:free()

    self.width = probe_size.w + 2 * self.padding
    self.height = probe_size.h + 2 * self.padding
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }

    self.text_widget = TextWidget:new{
        text = "",
        face = self.face,
        fgcolor = Blitbuffer.COLOR_BLACK,
        padding = 0,
    }
    self[1] = CenterContainer:new{
        dimen = Geom:new{
            x = 0,
            y = 0,
            w = self.width - 2 * self.padding,
            h = self.height - 2 * self.padding,
        },
        self.text_widget,
    }
    self:updateTime()
end

function ClockWidget:updateTime()
    local text = datetime.secondsToHour(os.time(),
        G_reader_settings:isTrue("twelve_hour_clock"))
    if text == self.text then return false end
    self.text = text
    self.text_widget:setText(text)
    return true
end

function ClockWidget:paintTo(bb, x, y)
    if self._paint_failed then return end
    if self.host and not host_is_top(self.host) then return end
    local ok, err = pcall(FrameContainer.paintTo, self, bb, x, y)
    if not ok then
        self._paint_failed = true
        logger.err("ScreenClock: paint failed:", err)
    end
end

local ScreenClock = {
    widget = nil,
    host = nil,
}

function ScreenClock:isEnabled()
    return G_reader_settings:isTrue("screen_clock")
end

function ScreenClock:setHost(host)
    self.host = host
    if self.widget then self.widget.host = host end
end

function ScreenClock:_schedule()
    UIManager:unschedule(self._tick, self)
    local t = os.date("*t")
    UIManager:scheduleIn(60 - (t.sec or 0) + 0.05, self._tick, self)
end

function ScreenClock:_tick()
    self:refresh()
end

function ScreenClock:position()
    local w = self.widget
    return Screen:getWidth() - w.width - w.padding,
        w.padding
end

function ScreenClock:refresh(force)
    if not self:isEnabled() then
        self:hide()
        return
    end
    if not self.widget then
        self:show(self.host)
    else
        local changed = self.widget:updateTime()
        if changed or force then
            local x, y = self:position()
            local region = Geom:new{ x = x, y = y, w = self.widget.width, h = self.widget.height }
            UIManager:setDirty(self.widget, "ui", region)
        end
    end
    self:_schedule()
end

function ScreenClock:refreshLayout()
    if not self.widget then return end
    local x, y = self:position()
    UIManager:close(self.widget, "ui", self.widget.dimen)
    self.widget.host = self.host
    UIManager:show(self.widget, "ui",
        Geom:new{ x = x, y = y, w = self.widget.width, h = self.widget.height }, x, y)
end

function ScreenClock:show(host, raise)
    if host then self.host = host end
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
        self.widget.host = self.host
        self:refresh()
    else
        local ok, widget = pcall(ClockWidget.new, ClockWidget, { host = self.host })
        if not ok then
            logger.err("ScreenClock: creation failed:", widget)
            return
        end
        self.widget = widget
        local x, y = self:position()
        UIManager:show(self.widget, "ui",
            Geom:new{ x = x, y = y, w = self.widget.width, h = self.widget.height }, x, y)
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
