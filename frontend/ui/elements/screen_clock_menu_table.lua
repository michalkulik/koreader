local ScreenClock = require("ui/widget/screenclock")
local _ = require("gettext")

return {
    text = _("Show clock in top-right corner"),
    help_text = _([[Shows a small clock in the top-right corner of the screen, including while reading. It follows the 12/24-hour clock setting.]]),
    checked_func = function() return G_reader_settings:isTrue("screen_clock") end,
    callback = function()
        G_reader_settings:flipNilOrFalse("screen_clock")
        ScreenClock:refresh(true)
    end,
}
