local ScreenClock = require("ui/widget/screenclock")

return {
    text = _("Show clock in top-right corner"),
    help_text = _([[Shows a small clock in the top-right corner of the screen, including while reading. It follows the 12/24-hour clock setting.]]),
    checked_func = function() return G_reader_settings:isTrue("screen_clock") end,
    callback = function(touchmenu_instance)
        G_reader_settings:flipNilOrFalse("screen_clock")
        if ScreenClock:isEnabled() then
            -- Showing the overlay while the menu is open would put it above
            -- the menu; close the menu first so it lands on the reader page.
            if touchmenu_instance then touchmenu_instance:closeMenu() end
            ScreenClock:show()
        else
            ScreenClock:hide()
        end
    end,
}
