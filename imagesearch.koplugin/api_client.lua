local logger = require("logger")
local socketutil = require("socketutil")

local ApiClient = {}

function ApiClient.getProvider()
    -- Default to duckduckgo if not set
    local provider_name = G_reader_settings:readSetting("imagesearch_provider") or "duckduckgo"
    
    local ok, provider = pcall(require, provider_name .. "_client")
    if not ok then
        logger.warn("ImageSearch: Failed to load provider", provider_name, provider)
        -- Fallback to wikicommons
        return require("wikicommons_client")
    end
    
    return provider
end

function ApiClient.searchImages(query, opts)
    local provider = ApiClient.getProvider()
    return provider.searchImages(query, opts)
end

function ApiClient.downloadImage(url, opts)
    -- Download logic might be provider specific if headers are needed,
    -- allowing provider to handle it.
    local provider = ApiClient.getProvider()
    if provider.downloadImage then
        return provider.downloadImage(url, opts)
    end
    
    -- Generic fallback if provider doesn't implement own download
    -- (Reuse the fetch logic from wikicommons or move generic fetch to a util)
    -- For now, wikicommons_client has a good generic downloader, we can proxy to it
    -- if the current provider doesn't support it, but cleaner to assume they do.
    local wikicommons = require("wikicommons_client")
    return wikicommons.downloadImage(url, opts)
end

return ApiClient
