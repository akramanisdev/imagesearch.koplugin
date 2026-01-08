local https = require("ssl.https")
local http = require("socket.http")
local socket_url = require("socket.url")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local json = require("json")
local logger = require("logger")

local OpenverseClient = {}

local DEFAULT_TIMEOUT = 15
local DEFAULT_MAXTIME = 30
local DEFAULT_RESULTS = 20

-- Helpers (duplicated from wikicommons for self-containment, or could use a util module)
local function build_query_url(base_url, params)
    local query_parts = {}
    for key, value in pairs(params) do
        if value ~= nil and value ~= "" then
            table.insert(query_parts, string.format("%s=%s", 
                socket_url.escape(tostring(key)), 
                socket_url.escape(tostring(value))))
        end
    end
    if #query_parts == 0 then return base_url end
    local separator = base_url:find("?", 1, true) and "&" or "?"
    return base_url .. separator .. table.concat(query_parts, "&")
end

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
        logger.warn("Openverse: Request failed", status_line or status_code)
        return nil, status_line or status_code or "Request failed"
    end
    
    local numeric_code = tonumber(status_code) or 0
    if numeric_code < 200 or numeric_code >= 300 then
        local message = status_line or ("HTTP " .. tostring(status_code))
        logger.warn("Openverse: HTTP error", numeric_code, message)
        return nil, message
    end
    
    return body
end

function OpenverseClient.searchImages(query, opts)
    local settings = opts or {}
    local max_results = settings.max_results or DEFAULT_RESULTS
    
    if not query or query == "" then
        return nil, "Search query cannot be empty"
    end
    
    logger.info("Openverse: Searching for:", query)
    
    -- Openverse API Endpoint
    -- No auth required for low volume
    local url = build_query_url("https://api.openverse.engineering/v1/images/", {
        q = query,
        page_size = max_results,
        format = "json",
        extension = "jpg,jpeg,png,gif", -- Filter unsupported formats
    })
    
    local body, err = fetch(url, true, settings.timeout, settings.maxtime)
    if not body then
        return nil, "Search failed: " .. (err or "unknown error")
    end
    
    local ok, data = pcall(function() return json.decode(body) end)
    if not ok or type(data) ~= "table" then
        logger.warn("Openverse: Failed to decode JSON")
        return nil, "Failed to parse search results"
    end
    
    if not data.results or #data.results == 0 then
        logger.info("Openverse: No results found")
        return {}
    end
    
    -- Map Openverse results to standard format
    local results = {}
    for _, item in ipairs(data.results) do
        table.insert(results, {
            title = item.title or "Untitled",
            description = item.creator and ("By " .. item.creator) or "",
            thumbnail_url = item.thumbnail, -- Openverse provides a direct thumbnail URL
            thumbnail_width = nil, -- Openverse doesn't always perform provide this in listing
            thumbnail_height = nil,
            full_url = item.url,
            full_width = item.width,
            full_height = item.height,
            mime_type = "image/jpeg", -- Assumption, or check item.filetype
        })
    end
    
    logger.info("Openverse: Found", #results, "results")
    return results
end

function OpenverseClient.downloadImage(url, opts)
    -- Reuse generic fetch
    local settings = opts or {}
    local use_https = url:match("^https://") ~= nil
    local data, err = fetch(url, use_https, settings.timeout, settings.maxtime)
    if not data then
        return nil, "Download failed: " .. (err or "unknown")
    end
    return data
end

return OpenverseClient
