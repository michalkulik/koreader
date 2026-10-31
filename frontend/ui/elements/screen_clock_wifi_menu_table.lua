local ScreenClock = require("ui/widget/screenclock")
local _ = require("gettext")

return {
    text = _("Show Wi-Fi status next to the clock"),
    help_text = _([[Shows whether Wi-Fi is connected next to the clock in the top-right corner. Requires the clock to be enabled.]]),
    enabled_func = function() return G_reader_settings:isTrue("screen_clock") end,
    checked_func = function() return G_reader_settings:isTrue("screen_clock_wifi") end,
    callback = function()
        G_reader_settings:flipNilOrFalse("screen_clock_wifi")
        ScreenClock:refresh(true)
    end,
}
