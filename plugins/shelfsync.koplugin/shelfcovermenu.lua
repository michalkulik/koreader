--[[--
A small, self-contained cover grid for the shelf.

The cover browser plugin is optional and expects local book files, so it
cannot be reused for books that only live on the server.  This menu keeps the
paging, title bar and focus handling from Menu, but draws one tile per book.
]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local Menu = require("ui/widget/menu")
local ProgressWidget = require("ui/widget/progresswidget")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local lfs = require("libs/libkoreader-lfs")

local Screen = Device.screen

local CoverTile = InputContainer:extend{}

local function placeholder(title, width, height)
    local initial = (title or "?"):match("%S") or "?"
    initial = initial:upper()
    return FrameContainer:new{
        width = width,
        height = height,
        padding = 0,
        margin = 0,
        bordersize = Size.border.thin,
        background = Blitbuffer.COLOR_LIGHT_GRAY,
        CenterContainer:new{
            dimen = Geom:new{ w = width, h = height },
            TextWidget:new{
                text = initial,
                face = Font:getFace("cfont", math.max(24, math.floor(height / 3))),
                bold = true,
                max_width = width - Screen:scaleBySize(8),
            },
        },
    }
end

function CoverTile:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.ges_events = {
        TapSelect = {
            GestureRange:new{ ges = "tap", range = self.dimen },
        },
        HoldSelect = {
            GestureRange:new{ ges = "hold", range = self.dimen },
        },
    }

    local cover
    if self.cover_path and lfs.attributes(self.cover_path, "mode") == "file" then
        cover = FrameContainer:new{
            width = self.cover_w,
            height = self.cover_h,
            padding = 0,
            margin = 0,
            bordersize = Size.border.thin,
            background = Blitbuffer.COLOR_WHITE,
            CenterContainer:new{
                dimen = Geom:new{ w = self.cover_w, h = self.cover_h },
                ImageWidget:new{
                    file = self.cover_path,
                    width = self.cover_w,
                    height = self.cover_h,
                    scale_factor = 0,
                },
            },
        }
    else
        cover = placeholder(self.title, self.cover_w, self.cover_h)
    end

    local title = TextWidget:new{
        text = self.title or "",
        face = Font:getFace("cfont", Screen:scaleBySize(15)),
        bold = true,
        max_width = self.width,
    }
    -- Author uses the same typeface as the title, only smaller.
    local author = TextWidget:new{
        text = self.author or "",
        face = Font:getFace("cfont", Screen:scaleBySize(12)),
        max_width = self.width,
    }
    local progress_text = TextWidget:new{
        text = self.progress_text or "",
        face = Font:getFace("cfont", Screen:scaleBySize(12)),
        bold = true,
        max_width = self.width,
    }
    local progress = ProgressWidget:new{
        width = self.cover_w,
        height = self.progress_h,
        percentage = math.max(0, math.min(1, tonumber(self.progress) or 0)),
        bgcolor = Blitbuffer.COLOR_WHITE,
        bordercolor = Blitbuffer.COLOR_DARK_GRAY,
        fillcolor = Blitbuffer.COLOR_BLACK,
        margin_h = Screen:scaleBySize(1),
        margin_v = Screen:scaleBySize(1),
    }

    self[1] = FrameContainer:new{
        width = self.width,
        height = self.height,
        padding = 0,
        margin = 0,
        bordersize = 0,
        background = nil,
        VerticalGroup:new{
            align = "center",
            cover,
            VerticalSpan:new{ width = Screen:scaleBySize(2) },
            progress,
            VerticalSpan:new{ width = Screen:scaleBySize(2) },
            title,
            author,
            progress_text,
        },
    }
end

function CoverTile:onTapSelect()
    if self.menu and self.menu.on_book_tap then
        self.menu.on_book_tap(self.entry)
    end
    return true
end

function CoverTile:onHoldSelect()
    if self.menu and self.menu.on_book_hold then
        self.menu.on_book_hold(self.entry)
    end
    return true
end

local CoverMenu = Menu:extend{
    -- Full-screen view, like the file manager's History/BookList, instead of
    -- a rounded popout drawer.
    is_popout = false,
    is_borderless = true,
    covers_fullscreen = true,
    title_bar_fm_style = true,
    nb_cols = 3,
    nb_rows = 2,
    item_margin = nil,
}

local function find_cover_tile(widget, pos)
    if not widget then return nil end
    local child_count = #widget
    for i = 1, child_count do
        local found = find_cover_tile(widget[i], pos)
        if found then return found end
    end
    if widget.entry and widget.dimen and widget.dimen:contains(pos) then
        return widget
    end
    return nil
end

local function add_title_tap(menu)
    menu.ges_events.TitleTap = {
        GestureRange:new{
            ges = "tap",
            range = function()
                return menu.title_bar and menu.title_bar.dimen
            end,
        },
    }
end

function CoverMenu:init()
    Menu.init(self)
    -- A fallback for taps that arrive on the menu itself instead of a tile.
    -- This happens after a popup menu is closed on some devices: the tile
    -- widgets are still painted, but an upper full-screen tap zone can eat
    -- their gesture.  Hit-testing the painted tiles makes selection reliable.
    self.ges_events.CoverTileTapFallback = {
        GestureRange:new{
            ges = "tap",
            range = Geom:new{
                x = 0, y = 0,
                w = Screen:getWidth(),
                h = Screen:getHeight(),
            },
        },
    }
    add_title_tap(self)
end

function CoverMenu:onCoverTileTapFallback(arg, ges)
    local tile = find_cover_tile(self.item_group, ges.pos)
    if tile and tile.onTapSelect then
        return tile:onTapSelect()
    end
end

function CoverMenu:onTitleTap()
    if self.on_title_tap then
        self.on_title_tap()
        return true
    end
end

function CoverMenu:_recalculateDimen()
    local inner_w = self.inner_dimen.w
    local inner_h = self.inner_dimen.h

    local top_height = 0
    if self.title_bar and not self.no_title then
        top_height = self.title_bar:getHeight()
    end
    local bottom_height = 0
    if self.page_info then
        bottom_height = self.page_info:getSize().h + Size.padding.button
    end
    self.available_height = inner_h - top_height - bottom_height

    self.item_margin = Screen:scaleBySize(6)
    self.nb_cols = inner_w >= Screen:scaleBySize(800) and 4 or 3
    self.item_width = math.floor(
        (inner_w - (self.nb_cols + 1) * self.item_margin) / self.nb_cols
    )
    -- Keep the covers recognisable but leave room for two text lines.  A
    -- slightly squat aspect ratio lets two rows fit on a 600x800 Kindle.
    self.cover_w = self.item_width
    self.cover_h = math.floor(self.item_width * 1.35)
    self.progress_h = Screen:scaleBySize(8)

    -- Measure a real tile instead of guessing the height of the text block.
    -- Font metrics differ between Android phones and e-ink devices; a fixed
    -- 60px text area can be too short, letting a cover paint over the progress
    -- line of the previous row.  The probe includes cover, progress bar and
    -- all three text widgets (title, author, percentage).
    local probe = CoverTile:new{
        title = "Ag",
        author = "Ag",
        progress_text = "100%",
        progress = 0,
        width = self.item_width,
        height = 0,
        cover_w = self.cover_w,
        cover_h = self.cover_h,
        progress_h = self.progress_h,
    }
    local content_height = probe[1]:getSize().h
    probe:free()
    -- Leave a little empty space below the percentage as well, so the next
    -- row starts clearly below it, not just one hairline away.
    self.item_height = content_height + Screen:scaleBySize(8)

    -- Bigger row gap than the old 6px.  On small 600x800 screens cap it so
    -- two rows still fit; on phones the scaled value is noticeably larger.
    local preferred_margin = Screen:scaleBySize(22)
    local max_margin_for_two_rows = math.floor(
        (self.available_height - 2 * self.item_height) / 3
    )
    self.row_margin = math.max(
        Screen:scaleBySize(12),
        math.min(preferred_margin, max_margin_for_two_rows)
    )

    -- Count whole rows including the spacer above the first row and below the
    -- last one.  This avoids the old approximate division that could report
    -- one row too many.
    self.nb_rows = 0
    while (self.nb_rows + 1) * self.item_height
            + (self.nb_rows + 2) * self.row_margin <= self.available_height do
        self.nb_rows = self.nb_rows + 1
    end
    self.nb_rows = math.max(1, self.nb_rows)
    self.perpage = math.max(1, self.nb_rows * self.nb_cols)
    self.page_num = math.max(1, math.ceil(#self.item_table / self.perpage))
    if self.page > self.page_num then
        self.page = self.page_num
    end
    self.item_dimen = Geom:new{
        x = 0, y = 0,
        w = self.item_width,
        h = self.item_height,
    }
end

function CoverMenu:_updateItemsBuildUI()
    local idx_offset = (self.page - 1) * self.perpage
    local cur_row
    local line_layout = {}
    local select_number

    for idx = 1, self.perpage do
        local index = idx_offset + idx
        local entry = self.item_table[index]
        if entry == nil then break end
        entry.idx = index
        if index == self.itemnumber then
            select_number = idx
        end

        if idx % self.nb_cols == 1 then
            if idx > 1 then
                table.insert(self.layout, line_layout)
            end
            line_layout = {}
            table.insert(self.item_group, VerticalSpan:new{ width = self.row_margin })
            cur_row = HorizontalGroup:new{}
            table.insert(self.item_group, LeftContainer:new{
                dimen = Geom:new{
                    w = self.inner_dimen.w,
                    h = self.item_height,
                },
                cur_row,
            })
            table.insert(cur_row, HorizontalSpan:new{ width = self.item_margin })
        end

        local tile = CoverTile:new{
            entry = entry,
            menu = self,
            title = entry.title,
            author = entry.author,
            progress_text = entry.progress_text,
            cover_path = entry.cover_path,
            progress = entry.progress,
            width = self.item_width,
            height = self.item_height,
            cover_w = self.cover_w,
            cover_h = self.cover_h,
            progress_h = self.progress_h,
        }
        table.insert(cur_row, tile)
        table.insert(cur_row, HorizontalSpan:new{ width = self.item_margin })
        table.insert(line_layout, tile)
    end

    if next(line_layout) then
        table.insert(self.layout, line_layout)
    end
    table.insert(self.item_group, VerticalSpan:new{ width = self.row_margin })
    return select_number
end

function CoverMenu:updateItems(select_number, no_recalculate_dimen)
    local old_dimen = self.dimen and self.dimen:copy()
    self.layout = {}
    self.item_group:clear()
    self.page_info:resetLayout()
    self.return_button:resetLayout()
    self.content_group:resetLayout()
    if not no_recalculate_dimen then
        self:_recalculateDimen()
    end

    select_number = self:_updateItemsBuildUI() or select_number
    self:updatePageInfo(select_number)
    Menu.mergeTitleBarIntoLayout(self)

    UIManager:setDirty(self.show_parent, function()
        return "ui", old_dimen and old_dimen:combine(self.dimen) or self.dimen
    end)
end

function CoverMenu:refreshCovers()
    self:updateItems(nil, true)
end

function CoverMenu:onLeftButtonTap()
    if self.on_left_button_tap then
        self.on_left_button_tap()
    end
end

-- Plain text list view. It intentionally uses Menu's normal row layout, but
-- keeps the same full-screen frame and title-bar actions as the cover grid.
local ShelfListMenu = Menu:extend{
    is_popout = false,
    is_borderless = true,
    covers_fullscreen = true,
    title_bar_fm_style = true,
}

function ShelfListMenu:init()
    Menu.init(self)
    add_title_tap(self)
end

function ShelfListMenu:onTitleTap()
    if self.on_title_tap then
        self.on_title_tap()
        return true
    end
end

function ShelfListMenu:onLeftButtonTap()
    if self.on_left_button_tap then
        self.on_left_button_tap()
    end
end

function ShelfListMenu:onMenuHold(item)
    if item.hold_callback then
        item.hold_callback(item)
    end
    return true
end

CoverMenu.ListMenu = ShelfListMenu

return CoverMenu
