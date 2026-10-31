local ScreenClock = require("ui/widget/screenclock")
local _ = require("gettext")

return {
    text = _("Show Wi-Fi icon next to the clock"),
    help_text = _([[Shows a Wi-Fi icon next to the clock in the top-right corner, reflecting whether Wi-Fi is connected and the signal strength when available. Requires the clock to be enabled.]]),
    enabled_func = function() return G_reader_settings:isTrue("screen_clock") end,
    checked_func = function() return G_reader_settings:isTrue("screen_clock_wifi") end,
    callback = function()
        G_reader_settings:flipNilOrFalse("screen_clock_wifi")
        ScreenClock:refresh(true)
    end,
}
