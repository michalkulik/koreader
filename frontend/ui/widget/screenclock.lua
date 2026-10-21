--[[--
Small clock painted in the top-right corner of the current UI.

It is not a window: the reader paints it as a ReaderView view module, and the
file manager paints it after its normal content. This keeps input, menus and
the screensaver completely untouched.
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
    bordersize = 0,
    margin = 0,
    background = Blitbuffer.COLOR_WHITE,
    padding = 3,
}

function ClockWidget:init()
    self.padding = Screen:scaleBySize(3)
    self.face = Font:getFace("cfont", Screen:scaleBySize(14))

    -- Fixed size avoids ghosting when 9:59 becomes 10:00 or when switching
    -- between 12-hour AM/PM strings.
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

function ClockWidget:paintTo(bb)
    if not G_reader_settings:isTrue("screen_clock") then return end
    local x = Screen:getWidth() - self.width - self.padding
    local ok, err = pcall(FrameContainer.paintTo, self, bb, x, self.padding)
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

function ScreenClock:attach(host)
    self.host = host
    if not self.widget then
        local ok, widget = pcall(ClockWidget.new, ClockWidget)
        if not ok then
            logger.err("ScreenClock: creation failed:", widget)
            return
        end
        self.widget = widget
    end
    if host.view and host.view.view_modules then
        host.view:registerViewModule("screen_clock", self.widget)
    else
        host.screen_clock_widget = self.widget
    end
    self.widget:updateTime()
    self:_schedule()
end

function ScreenClock:refresh(force)
    if not self.host or not self.widget then return end
    local region = self:region()
    if not self:isEnabled() then
        UIManager:unschedule(self._tick, self)
        -- Repaint the area so the old clock disappears immediately.
        UIManager:setDirty(self.host, "ui", region)
        return
    end
    if self.widget:updateTime() or force then
        UIManager:setDirty(self.host, "ui", region)
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
