local InputContainer = require("ui/widget/container/inputcontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local ImageWidget = require("ui/widget/imagewidget")
local TextWidget = require("ui/widget/textwidget")
local Button = require("ui/widget/button")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Screen = Device.screen
local Geom = require("ui/geometry")
local logger = require("logger")
local _ = require("gettext")
local GestureRange = require("ui/gesturerange")

local ClickableImage = InputContainer:extend{
    file = nil,
    width = 100,
    height = 100,
    callback = nil,
}

function ClickableImage:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self[1] = ImageWidget:new{
        file = self.file,
        width = self.width,
        height = self.height,
        scale_factor = 0,
        file_do_cache = false,
    }
    self.ges_events = {
        Tap = {
            GestureRange:new{
                ges = "tap",
                range = self.dimen,
                func = function()
                    if self.callback then self.callback() end
                    return true
                end,
            }
        }
    }
end

local ThumbnailDialog = InputContainer:extend{
    modal = true,
    fullscreen = true,
    
    -- Pagination state
    current_page = 1,
    items_per_page = 4, -- 2x2 grid
}

function ThumbnailDialog:init()
    self.results = self.results or {}
    self.current_page = 1
    
    -- Load configurabled layout
    self.rows = G_reader_settings:readSetting("imagesearch_rows") or 2
    self.cols = G_reader_settings:readSetting("imagesearch_cols") or 2
    self.items_per_page = self.rows * self.cols
    
    self.cache_manager = self.cache_manager or require("image_cache_manager")
    self.api_client = self.api_client or require("api_client")
    
    self.total_pages = math.ceil(#self.results / self.items_per_page)
    if self.total_pages == 0 then self.total_pages = 1 end
    
    self.width = Screen:getWidth()
    self.height = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    
    -- Title Bar
    self.title_bar = TitleBar:new{
        width = self.width,
        title = string.format(_("Images: %s"), self.query),
        show_parent = self,
        close_callback = function() self:onClose() end,
    }
    
    -- Bottom Navigation Bar
    self.btn_prev = Button:new{
        text = "  <  ",
        enabled = false,
        callback = function() self:prevPage() end,
    }
    self.btn_next = Button:new{
        text = "  >  ",
        enabled = true,
        callback = function() self:nextPage() end,
    }
    
    self.btn_search = Button:new{
        text = _("Search"),
        callback = function()
            self:onClose()
            if self.callback_search then self.callback_search() end
        end,
    }
    
    self.lbl_page = TextWidget:new{
        text = string.format("%d / %d", self.current_page, self.total_pages),
        face = require("ui/font"):getFace("smallinfofont"),
        padding = 10,
    }
    
    self.bottom_bar = HorizontalGroup:new{
        align = "center",
        self.btn_prev,
        self.lbl_page,
        self.btn_next,
    }
    
    -- Calculate heights consistently using getSize() or Safe Fallbacks
    local title_h = 45
    if self.title_bar.getSize then
        title_h = self.title_bar:getSize().h
    end
    
    local bottom_h = 60
    if self.bottom_bar.getSize then
        bottom_h = self.bottom_bar:getSize().h
    end
    
    local content_h = self.height - title_h - bottom_h
    if content_h < 100 then content_h = self.height * 0.7 end -- Sanity check
    
    -- Content Container (Empty initially)
    self.content_container = FrameContainer:new{
        dimen = Geom:new{ 
            w = self.width, 
            h = content_h 
        },
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
    }
    
    -- Root Layout
    local root_group = VerticalGroup:new{
        align = "center",
        self.title_bar,
        self.content_container,
        self.bottom_bar,
    }
    
    self[1] = FrameContainer:new{
        dimen = self.dimen,
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        root_group,
    }
    
    self:refreshPage()
    self:downloadThumbnails()
end

function ThumbnailDialog:refreshPage()
    local start_idx = (self.current_page - 1) * self.items_per_page + 1
    local end_idx = math.min(start_idx + self.items_per_page - 1, #self.results)
    
    local page_items = {}
    for i = start_idx, end_idx do
        table.insert(page_items, self.results[i])
    end
    
    local grid = self:buildGridForItems(page_items)
    self.content_container[1] = grid
    
    -- Update controls
    self.lbl_page:setText(string.format("%d / %d", self.current_page, self.total_pages))
    
    -- Update buttons state
    if self.btn_prev.enableDisable then
        self.btn_prev:enableDisable(self.current_page > 1)
    else
        self.btn_prev.enabled = self.current_page > 1
    end
    
    if self.btn_next.enableDisable then
        self.btn_next:enableDisable(self.current_page < self.total_pages)
    else
        self.btn_next.enabled = self.current_page < self.total_pages
    end
    
    UIManager:setDirty(self, "ui")
    
    -- Download thumbnails for the new page
    self:downloadThumbnails()
end

function ThumbnailDialog:prevPage()
    if self.current_page > 1 then
        self.current_page = self.current_page - 1
        self:refreshPage()
    end
end

function ThumbnailDialog:nextPage()
    if self.current_page < self.total_pages then
        self.current_page = self.current_page + 1
        self:refreshPage()
    end
end

function ThumbnailDialog:buildGridForItems(items)
    local grid_items = {}
    local cols = self.cols or 2
    local padding = 15
    local screen_w = self.width
    local item_w = math.floor((screen_w - (cols + 1) * padding) / cols)
    local item_h = math.floor(item_w * 3 / 4)
    
    for i, result in ipairs(items) do
        local item_container = VerticalGroup:new{
            align = "center",
            padding = 0,
        }
        
        -- Wrapper for Image/Placeholder
        local image_wrapper = FrameContainer:new{
            dimen = Geom:new{ w = item_w, h = item_h },
            padding = 0,
            bordersize = 1,
            background = Blitbuffer.COLOR_WHITE,
        }
        
        -- Check if we have a downloaded file for this result
        local cached_path = self.cache_manager.downloadAndCache and self.cache_manager.getFilenameFromUrl and 
                            self.cache_manager.getCacheDir() and 
                            self.cache_manager.getCacheDir() .. "/" .. self.cache_manager.getFilenameFromUrl(result.thumbnail_url)
        
        -- Check if file exists
        local file_exists = false
        if cached_path then
            local f = io.open(cached_path, "r")
            if f then 
                f:close() 
                file_exists = true 
            end
        end
        
        if file_exists then
            -- Show Image wrapped in Button
            local img_widget = ImageWidget:new{
                file = cached_path,
                width = item_w,
                height = item_h,
                scale_factor = 0,
                file_do_cache = false,
            }
            local btn = Button:new{
                text = "",
                width = item_w,
                height = item_h,
                callback = function() self:onThumbnailTap(result, cached_path) end,
                bordersize = 0,
            }
            btn.text = nil -- Prevent text handling crashes
            btn.label_widget = img_widget
            if btn.label_container then
                btn.label_container[1] = img_widget
            end
            image_wrapper[1] = btn
        else
            -- Show Placeholder
            image_wrapper[1] = Button:new{
                text = _("Loading..."),
                width = item_w,
                height = item_h,
                callback = function() end,
            }
        end
        
        -- Store wrapper reference in result for async updates
        result._image_wrapper = image_wrapper
        result._item_w = item_w
        result._item_h = item_h
        
        table.insert(item_container, image_wrapper)
        
        -- Title
        local title_clean = result.title:gsub("^File:", "")
        local title_short = #title_clean > 25 and title_clean:sub(1, 22) .. "..." or title_clean
        table.insert(item_container, TextWidget:new{
            text = title_short,
            face = require("ui/font"):getFace("smallinfofont"),
            max_width = item_w,
            padding = 5,
        })
        
        table.insert(grid_items, item_container)
    end
    
    -- Build Rows
    local rows = {}
    local row_items = {}
    for i, item in ipairs(grid_items) do
        table.insert(row_items, item)
        if #row_items == cols then
            table.insert(rows, HorizontalGroup:new{ align = "top", gap = padding, table.unpack(row_items) })
            row_items = {}
        end
    end
    if #row_items > 0 then
        table.insert(rows, HorizontalGroup:new{ align = "top", gap = padding, table.unpack(row_items) })
    end
    
    return VerticalGroup:new{ align = "center", padding = padding, gap = padding + 10, table.unpack(rows) }
end

function ThumbnailDialog:downloadThumbnails()
    -- Download thumbnails for current page only
    local start_idx = (self.current_page - 1) * self.items_per_page + 1
    local end_idx = math.min(start_idx + self.items_per_page - 1, #self.results)
    
    for i = start_idx, end_idx do
        local result = self.results[i]
        if result and result.thumbnail_url and not result._downloaded then
            result._downloaded = true  -- Mark as downloading to avoid duplicates
            UIManager:nextTick(function()
                local filepath, err = self.cache_manager.downloadAndCache(result.thumbnail_url, self.api_client)
                if filepath then
                    self:updateThumbnail(result, filepath)
                else
                    logger.warn("ImageSearch: Download failed:", err)
                    result._downloaded = false  -- Allow retry on error
                end
            end)
        end
    end
end

function ThumbnailDialog:updateThumbnail(result, filepath)
    -- Only update if the result has a wrapper (meaning it's potentially visible or was visible)
    if result._image_wrapper then
        local img_widget = ImageWidget:new{
            file = filepath,
            width = result._item_w,
            height = result._item_h,
            scale_factor = 0,
            file_do_cache = false,
        }
        local btn = Button:new{
            text = "",
            width = result._item_w,
            height = result._item_h,
            callback = function() self:onThumbnailTap(result, filepath) end,
            bordersize = 0,
        }
        btn.text = nil -- Prevent text handling crashes
        btn.label_widget = img_widget
        if btn.label_container then
            btn.label_container[1] = img_widget
        end
        
        result._image_wrapper[1] = btn
        UIManager:setDirty(self, "ui")  -- Refresh entire dialog to show new thumbnail
    end
end

function ThumbnailDialog:onThumbnailTap(result, filepath)
    logger.info("ImageSearch: Opening viewer for:", result.title)
    
    local ok, ImageViewer = pcall(require, "image_viewer")
    if not ok then
        logger.err("ImageSearch: Failed to load ImageViewer")
        return
    end
    
    if not result.full_url then
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{
            text = _("Error: No high-res URL available."),
            timeout = 2,
        })
        return
    end
    
    local InfoMessage = require("ui/widget/infomessage")
    local loading_popup = InfoMessage:new{
        text = _("Downloading full image..."),
        timeout = 0, -- Persistent until closed
    }
    UIManager:show(loading_popup)
    
    UIManager:nextTick(function()
        local full_filepath, err = self.cache_manager.downloadAndCache(
            result.full_url,
            self.api_client
        )
        
        UIManager:close(loading_popup)
        
        if full_filepath then
            local viewer = ImageViewer:new{
                file = full_filepath,
                title_text = result.title,
                modal = true,
                fullscreen = true,
            }
            UIManager:show(viewer)
        else
            UIManager:show(InfoMessage:new{
                text = _("Download failed: ") .. (err or "Unknown error"),
                timeout = 3,
            })
        end
    end)
end

function ThumbnailDialog:onClose()
    UIManager:close(self)
    return true
end

ThumbnailDialog.key_events = {
    Close = { { "Back" }, { "Esc" }, { "Menu" } },
    PageBack = { { "Left" } },
    PageFwd = { { "Right" } },
}
function ThumbnailDialog:onPageBack() self:prevPage() return true end
function ThumbnailDialog:onPageFwd() self:nextPage() return true end

return ThumbnailDialog
