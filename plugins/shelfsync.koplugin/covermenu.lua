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
local Menu = require("ui/widget/menu")
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
    local subtitle = TextWidget:new{
        text = self.subtitle or "",
        face = Font:getFace("infont", Screen:scaleBySize(13)),
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        max_width = self.width,
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
            VerticalSpan:new{ width = Screen:scaleBySize(3) },
            title,
            subtitle,
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
    is_popout = true,
    is_borderless = false,
    title_bar_fm_style = true,
    nb_cols = 3,
    nb_rows = 2,
    item_margin = nil,
}

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
    self.text_height = Screen:scaleBySize(44)
    self.item_height = self.cover_h + self.text_height + Screen:scaleBySize(4)

    self.nb_rows = math.max(
        1,
        math.floor(
            (self.available_height - self.item_margin)
                / (self.item_height + self.item_margin)
        )
    )
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
            table.insert(self.item_group, VerticalSpan:new{ width = self.item_margin })
            cur_row = HorizontalGroup:new{}
            table.insert(self.item_group, CenterContainer:new{
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
            subtitle = entry.subtitle,
            cover_path = entry.cover_path,
            width = self.item_width,
            height = self.item_height,
            cover_w = self.cover_w,
            cover_h = self.cover_h,
        }
        table.insert(cur_row, tile)
        table.insert(cur_row, HorizontalSpan:new{ width = self.item_margin })
        table.insert(line_layout, tile)
    end

    if next(line_layout) then
        table.insert(self.layout, line_layout)
    end
    table.insert(self.item_group, VerticalSpan:new{ width = self.item_margin })
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

return CoverMenu
