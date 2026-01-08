local https = require("ssl.https")
local http = require("socket.http")
local socket_url = require("socket.url")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local json = require("json")
local logger = require("logger")

local WikiCommonsApi = {}

local DEFAULT_TIMEOUT = 15
local DEFAULT_MAXTIME = 30
local DEFAULT_RESULTS = 5

-- Build URL with query parameters
local function build_query_url(base_url, params)
    local query_parts = {}
    for key, value in pairs(params) do
        if value ~= nil and value ~= "" then
            table.insert(query_parts, string.format("%s=%s", 
                socket_url.escape(tostring(key)), 
                socket_url.escape(tostring(value))))
        end
    end
    if #query_parts == 0 then
        return base_url
    end
    local separator = base_url:find("?", 1, true) and "&" or "?"
    return base_url .. separator .. table.concat(query_parts, "&")
end

-- Fetch URL with timeout
local function fetch(url, use_https, timeout, maxtime)
    local response_chunks = {}
    socketutil:set_timeout(timeout or DEFAULT_TIMEOUT, maxtime or DEFAULT_MAXTIME)
    
    local request_module = use_https and https or http
    local ok, status_code, _, status_line = request_module.request {
        url = url,
        method = "GET",
        headers = {
            ["User-Agent"] = "KOReader/ImageSearch Plugin",
            ["Accept"] = "application/json",
        },
        sink = ltn12.sink.table(response_chunks),
    }
    socketutil:reset_timeout()
    
    local body = table.concat(response_chunks)
    
    if not ok then
        logger.warn("ImageSearch: Request failed", status_line or status_code)
        return nil, status_line or status_code or "Request failed"
    end
    
    local numeric_code = tonumber(status_code) or 0
    if numeric_code < 200 or numeric_code >= 300 then
        local message = status_line or ("HTTP " .. tostring(status_code))
        logger.warn("ImageSearch: HTTP error", numeric_code, message)
        return nil, message
    end
    
    return body
end

-- Search for images on Wikimedia Commons
function WikiCommonsApi.searchImages(query, opts)
    local settings = opts or {}
    local max_results = settings.max_results or DEFAULT_RESULTS
    
    if not query or query == "" then
        return nil, "Search query cannot be empty"
    end
    
    logger.info("ImageSearch: Searching for:", query)
    
    -- Step 1: Search for files matching the query
    local search_url = build_query_url("https://commons.wikimedia.org/w/api.php", {
        action = "query",
        format = "json",
        list = "search",
        srsearch = query,
        srnamespace = "6", -- File namespace
        srlimit = max_results,
        srprop = "timestamp",
    })
    
    local search_body, search_err = fetch(search_url, true, settings.timeout, settings.maxtime)
    if not search_body then
        return nil, "Search failed: " .. (search_err or "unknown error")
    end
    
    -- Parse search results
    local ok, search_data = pcall(function()
        return json.decode(search_body)
    end)
    
    if not ok or type(search_data) ~= "table" then
        logger.warn("ImageSearch: Failed to decode search response")
        return nil, "Failed to parse search results"
    end
    
    if not search_data.query or not search_data.query.search then
        logger.info("ImageSearch: No results found for:", query)
        return {}
    end
    
    local search_results = search_data.query.search
    if #search_results == 0 then
        logger.info("ImageSearch: No results found for:", query)
        return {}
    end
    
    -- Step 2: Get image info for each result
    local titles = {}
    for i, result in ipairs(search_results) do
        if i <= max_results then
            table.insert(titles, result.title)
        end
    end
    
    local titles_param = table.concat(titles, "|")
    local imageinfo_url = build_query_url("https://commons.wikimedia.org/w/api.php", {
        action = "query",
        format = "json",
        titles = titles_param,
        prop = "imageinfo",
        iiprop = "url|size|mime|extmetadata",
        iiurlwidth = "200", -- Thumbnail size
    })
    
    local info_body, info_err = fetch(imageinfo_url, true, settings.timeout, settings.maxtime)
    if not info_body then
        logger.warn("ImageSearch: Image info request failed:", info_err)
        return nil, "Failed to get image information: " .. (info_err or "unknown error")
    end
    
    -- Parse image info
    local ok2, info_data = pcall(function()
        return json.decode(info_body)
    end)
    
    if not ok2 or type(info_data) ~= "table" then
        logger.warn("ImageSearch: Failed to decode image info response")
        return nil, "Failed to parse image information"
    end
    
    if not info_data.query or not info_data.query.pages then
        logger.warn("ImageSearch: No image info returned")
        return nil, "No image information available"
    end
    
    -- Extract results
    local results = {}
    for page_id, page_data in pairs(info_data.query.pages) do
        if type(page_data) == "table" and page_data.imageinfo and #page_data.imageinfo > 0 then
            local img_info = page_data.imageinfo[1]
            local title = page_data.title or "Untitled"
            
            -- Get description from metadata if available
            local description = ""
            if img_info.extmetadata and img_info.extmetadata.ImageDescription then
                local desc_data = img_info.extmetadata.ImageDescription
                if type(desc_data) == "table" and desc_data.value then
                    description = desc_data.value:gsub("<[^>]+>", ""):sub(1, 200)
                end
            end
            
            table.insert(results, {
                title = title,
                description = description,
                thumbnail_url = img_info.thumburl or img_info.url,
                thumbnail_width = img_info.thumbwidth or img_info.width,
                thumbnail_height = img_info.thumbheight or img_info.height,
                full_url = img_info.url,
                full_width = img_info.width,
                full_height = img_info.height,
                mime_type = img_info.mime,
            })
        end
    end
    
    logger.info("ImageSearch: Found", #results, "results for:", query)
    return results
end

-- Download image from URL
function WikiCommonsApi.downloadImage(url, opts)
    local settings = opts or {}
    
    if not url or url == "" then
        return nil, "Image URL cannot be empty"
    end
    
    logger.info("ImageSearch: Downloading image from:", url)
    
    -- Determine if HTTPS
    local use_https = url:match("^https://") ~= nil
    
    local image_data, err = fetch(url, use_https, settings.timeout, settings.maxtime)
    if not image_data then
        logger.warn("ImageSearch: Image download failed:", err)
        return nil, "Failed to download image: " .. (err or "unknown error")
    end
    
    logger.info("ImageSearch: Downloaded", #image_data, "bytes")
    return image_data
end

return WikiCommonsApi
