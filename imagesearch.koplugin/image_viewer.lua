local ImageViewer = require("ui/widget/imageviewer")
local ButtonTable = require("ui/widget/buttontable")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local Geom = require("ui/geometry")
local _ = require("gettext")
local lfs = require("libs/libkoreader-lfs")

local MyImageViewer = ImageViewer:extend{
    buttons_visible = true, -- Always show buttons initially
    modal = true,
    fullscreen = true,
}

function MyImageViewer:init()
    -- Call parent init to set up everything
    ImageViewer.init(self)
    
    -- Rebuild the button table to include our Save button
    -- We must retain the structure so that self:update() can find 'scale' and 'rotate' buttons
    local buttons = {
        {
            {
                id = "scale",
                text = self._scale_to_fit and _("Original size") or _("Scale"),
                callback = function()
                    self.scale_factor = self._scale_to_fit and 1 or 0
                    self._scale_to_fit = not self._scale_to_fit
                    self._center_x_ratio = 0.5
                    self._center_y_ratio = 0.5
                    self:update()
                end,
            },
            {
                id = "rotate",
                text = self.rotated and _("No rotation") or _("Rotate"),
                callback = function()
                    self.rotated = not self.rotated and true or false
                    self:update()
                end,
            },
            {
                id = "save",
                text = _("Save"),
                callback = function()
                    self:onSaveLocal()
                end,
            },
            {
                id = "close",
                text = _("Close"),
                callback = function()
                    self:onClose()
                end,
            },
        },
    }
    
    -- Replace the button_table with our version
    -- Re-using the dimensions and parent from original (self.width, self.button_padding known from inheritance)
    self.button_table = ButtonTable:new{
        width = self.width - 2 * self.button_padding,
        buttons = buttons,
        zero_sep = true,
        show_parent = self,
    }
    
    -- Update the container wrapper
    self.button_container = CenterContainer:new{
        dimen = Geom:new{
            w = self.width,
            h = self.button_table:getSize().h,
        },
        self.button_table,
    }
    
    -- Force an update to render the new buttons
    self:update()
end

function MyImageViewer:onSaveLocal()
    local candidates = {}
    
    -- 0. Custom Plugin Setting (Highest Priority)
    local custom_dir = G_reader_settings:readSetting("imagesearch_download_dir")
    if custom_dir then table.insert(candidates, custom_dir) end
    
    -- 1. Standard Download Directory (if set)
    local download_dir = G_reader_settings:readSetting("download_dir")
    if download_dir then table.insert(candidates, download_dir) end
    
    -- 2. Home Directory subfolder
    local home_dir = G_reader_settings:readSetting("home_dir")
    if home_dir then table.insert(candidates, home_dir .. "/ImageSearch") end
    
    -- 3. Common Device Paths
    table.insert(candidates, "/mnt/onboard/ImageSearch") -- Kobo/Kindle
    table.insert(candidates, "/sdcard/ImageSearch")      -- Android
    table.insert(candidates, lfs.currentdir() .. "/ImageSearch") -- Desktop/Fallback
    table.insert(candidates, "/tmp/ImageSearch")         -- Last resort
    
    local target_dir
    local errors = {}
    local logger = require("logger")
    
    for _, path in ipairs(candidates) do
        local mode = lfs.attributes(path, "mode")
        if mode == "directory" then
            target_dir = path
            break
        elseif not mode then
            -- Check if parent exists before trying to create
            local parent = path:match("(.+)/[^/]+$")
            if parent and lfs.attributes(parent, "mode") == "directory" then
                local ok, err = lfs.mkdir(path)
                if ok then
                    target_dir = path
                    break
                else
                    table.insert(errors, path .. ": " .. tostring(err))
                    logger.warn("ImageSearch: Failed to create", path, err)
                end
            else
                -- Parent doesn't exist, skip silently (or log debug)
                -- table.insert(errors, path .. ": parent missing")
            end
        end
    end
    
    if not target_dir then
        -- Build helpful error message
        local err_msg = _("Could not find writable directory.\nAttempts:\n")
        for _, e in ipairs(errors) do
            err_msg = err_msg .. "• " .. e .. "\n"
        end
        if #errors == 0 then
            err_msg = err_msg .. _("No valid parent directories found.")
        end
        
        UIManager:show(InfoMessage:new{ 
            text = err_msg,
            timeout = 10,
        })
        return
    end
    
    logger.info("ImageSearch: Saving to", target_dir)
    
    local filename = self.file:match("[^/]+$")
    local target_path = target_dir .. "/" .. filename
    
    local src_f, src_err = io.open(self.file, "rb")
    if not src_f then
         UIManager:show(InfoMessage:new{ text = _("Error opening source: ") .. tostring(src_err) })
         return
    end
    
    local dst_f, dst_err = io.open(target_path, "wb")
    if not dst_f then
        src_f:close()
        UIManager:show(InfoMessage:new{ text = _("Error saving to ") .. target_path .. _("\n") .. tostring(dst_err) })
        return
    end
    
    local content = src_f:read("*all")
    dst_f:write(content)
    dst_f:close()
    src_f:close()
    
    UIManager:show(InfoMessage:new{
        text = _("Saved to:\n") .. target_path,
        timeout = 3,
    })
end

return MyImageViewer
