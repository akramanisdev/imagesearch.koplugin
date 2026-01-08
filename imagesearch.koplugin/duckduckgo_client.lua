local https = require("ssl.https")
local http = require("socket.http")
local socket_url = require("socket.url")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local json = require("json")
local logger = require("logger")

local DuckDuckGoClient = {}

local DEFAULT_TIMEOUT = 15
local DEFAULT_MAXTIME = 30

-- Helpers
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
    local headers = {
        ["User-Agent"] = "Mozilla/5.0 (X11; Linux x86_64; rv:109.0) Gecko/20100101 Firefox/115.0",
        ["Accept"] = "application/json, text/javascript, */*; q=0.01",
        ["Accept-Language"] = "en-US,en;q=0.5",
        ["Referer"] = "https://duckduckgo.com/",
        ["Authority"] = "duckduckgo.com",
    }
    
    local ok, status_code, _, status_line = request_module.request {
        url = url,
        method = "GET",
        headers = headers,
        sink = ltn12.sink.table(response_chunks),
    }
    socketutil:reset_timeout()
    
    local body = table.concat(response_chunks)
    
    if not ok then
        logger.warn("DDG: Request failed", status_line or status_code)
        return nil, status_line or status_code or "Request failed"
    end
    
    return body
end

function DuckDuckGoClient.searchImages(query, opts)
    local settings = opts or {}
    -- DDG doesn't strictly respect 'max_results' in the initial call (returns batches), 
    -- but we can slice the result.
    
    if not query or query == "" then
        return nil, "Search query cannot be empty"
    end
    
    logger.info("DDG: Step 1 - Fetching VQD token for:", query)
    
    -- Step 1: Get VQD Token
    local vqd_url = build_query_url("https://duckduckgo.com/", {
        q = query,
        t = "h_",
        iax = "images",
        ia = "images",
    })
    
    local vqd_body, vqd_err = fetch(vqd_url, true, 10, 20)
    if not vqd_body then
        return nil, "Failed to connect to DuckDuckGo: " .. (vqd_err or "unknown")
    end
    
    -- Extract vqd='...'
    local vqd = vqd_body:match("vqd=['\"]([^'\"]+)['\"]")
    if not vqd then
        logger.warn("DDG: Could not find VQD token")
        return nil, "Failed to initialize search (VQD missing)"
    end
    
    logger.info("DDG: Got VQD token:", vqd)
    
    -- Step 2: Fetch JSON
    local search_url = build_query_url("https://duckduckgo.com/i.js", {
        l = "us-en",
        o = "json",
        q = query,
        vqd = vqd,
        f = ",,,",
        p = "1",
    })
    
    local json_body, json_err = fetch(search_url, true, settings.timeout, settings.maxtime)
    if not json_body then
        return nil, "Search request failed: " .. (json_err or "unknown")
    end
    
    local ok, data = pcall(function() return json.decode(json_body) end)
    if not ok or type(data) ~= "table" then
        logger.warn("DDG: Failed to decode JSON. Body sample:", json_body:sub(1, 500))
        return nil, "Failed to parse search results"
    end
    
    if not data.results or #data.results == 0 then
        logger.info("DDG: No results found")
        return {}
    end
    
    -- Map results
    local results = {}
    for _, item in ipairs(data.results) do
        -- DDG results: item.image (full), item.thumbnail (thumb), item.title, item.url (page)
        table.insert(results, {
            title = item.title or "Untitled",
            description = item.source or "",
            thumbnail_url = item.thumbnail, 
            thumbnail_width = nil, -- DDG returns these but often for the FULL image, safe to leave nil
            thumbnail_height = nil,
            full_url = item.image,
            full_width = item.width,
            full_height = item.height,
            mime_type = "image/jpeg", -- Assumption
        })
    end
    
    logger.info("DDG: Found", #results, "results")
    return results
end

function DuckDuckGoClient.downloadImage(url, opts)
    -- Reuse generic fetch
    local settings = opts or {}
    local use_https = url:match("^https://") ~= nil
    local data, err = fetch(url, use_https, settings.timeout, settings.maxtime)
    if not data then
        return nil, "Download failed: " .. (err or "unknown")
    end
    return data
end

return DuckDuckGoClient
