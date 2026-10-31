local EventListener = require("ui/widget/eventlistener")
local ScreenClock = require("ui/widget/screenclock")
local UIManager = require("ui/uimanager")

local ScreenClockListener = EventListener:extend{}

function ScreenClockListener:onResume()
    ScreenClock:refresh(true)
end

local function refresh_after_layout()
    -- Let ReaderView/FileManager apply the new dimensions first.
    UIManager:nextTick(function() ScreenClock:refreshLayout() end)
end

function ScreenClockListener:onSetRotationMode()
    refresh_after_layout()
end

ScreenClockListener.onScreenResize = refresh_after_layout
ScreenClockListener.onSetDimensions = refresh_after_layout

function ScreenClockListener:onToggleNightMode()
    ScreenClock:refresh(true)
end

-- The Wi-Fi label is part of the clock text, so repaint as soon as the
-- connection state changes (and not only on the next minute tick).
function ScreenClockListener:onNetworkConnecting()
    ScreenClock:refresh(true)
end

ScreenClockListener.onNetworkConnected = ScreenClockListener.onNetworkConnecting
ScreenClockListener.onNetworkDisconnecting = ScreenClockListener.onNetworkConnecting
ScreenClockListener.onNetworkDisconnected = ScreenClockListener.onNetworkConnecting

return ScreenClockListener
