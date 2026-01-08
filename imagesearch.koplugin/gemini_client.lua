local https = require("ssl.https")
local ltn12 = require("ltn12")
local json = require("json")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")
local CacheManager = require("image_cache_manager")

local GeminiClient = {}

-- Configurable Model Name (Default to gemini-2.5-flash-image)
-- User can override this in settings if needed.
local DEFAULT_MODEL = "gemini-2.5-flash-image"

-- URL depends on the model, so we construct it dynamically
local BASE_URL = "https://generativelanguage.googleapis.com/v1beta/models/"
local API_METHOD = ":generateContent"

-- OPTIONAL: Paste your API Key here to avoid typing it on the device
local HARDCODED_API_KEY = "" -- Paste your API Key here for easy setup

-- Pure Lua Base64 decoder since 'mime' is not always available
-- Uses 'bit' library for LuaJIT compatibility (KOReader standard)
local bit = require("bit")
local b64chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local b64map = {}
for i = 1, 64 do b64map[string.byte(b64chars, i)] = i - 1 end

local function b64decode(data)
    local out = {}
    local len = #data
    local pad = 0
    if string.sub(data, -2) == '==' then pad = 2
    elseif string.sub(data, -1) == '=' then pad = 1 end
    
    for i = 1, len - pad, 4 do
        local c1 = b64map[string.byte(data, i)]
        local c2 = b64map[string.byte(data, i+1)]
        local c3 = b64map[string.byte(data, i+2)]
        local c4 = b64map[string.byte(data, i+3)]
        
        if not (c1 and c2 and c3 and c4) then break end
        
        local b = bit.bor(bit.lshift(c1, 18), bit.lshift(c2, 12), bit.lshift(c3, 6), c4)
        
        table.insert(out, string.char(bit.band(bit.rshift(b, 16), 0xFF)))
        if i + 2 <= len - pad then 
            table.insert(out, string.char(bit.band(bit.rshift(b, 8), 0xFF))) 
        end
        if i + 3 <= len - pad then 
            table.insert(out, string.char(bit.band(b, 0xFF))) 
        end
    end
    return table.concat(out)
end

function GeminiClient.getApiKey()
    return (HARDCODED_API_KEY and HARDCODED_API_KEY ~= "") and HARDCODED_API_KEY or nil
end

function GeminiClient.generateImage(prompt, apiKey)
    -- Use hardcoded key if set, otherwise use the one passed from settings
    local key = (HARDCODED_API_KEY and HARDCODED_API_KEY ~= "") and HARDCODED_API_KEY or apiKey

    if not key or key == "" then
        return nil, "API Key is missing. Set it in settings or edit gemini_client.lua"
    end
    if not prompt or prompt == "" then
        return nil, "Prompt cannot be empty."
    end

    logger.info("Gemini: Generating image for prompt:", prompt)

    -- Correct payload structure for gemini-2.5-flash-image
    local payload = {
        contents = {
            {
                role = "user",
                parts = {
                    { text = prompt }
                }
            }
        },
        generationConfig = {
            responseModalities = { "TEXT", "IMAGE" }
        },
        -- Safety settings to allow creative freedom (copied from assistant plugin)
        safetySettings = {
            { category = "HARM_CATEGORY_SEXUALLY_EXPLICIT", threshold = "BLOCK_NONE" },
            { category = "HARM_CATEGORY_HATE_SPEECH", threshold = "BLOCK_NONE" },
            { category = "HARM_CATEGORY_HARASSMENT", threshold = "BLOCK_NONE" },
            { category = "HARM_CATEGORY_DANGEROUS_CONTENT", threshold = "BLOCK_NONE" }
        }
    }

    local json_payload = json.encode(payload)
    local response_chunks = {}
    
    -- Use header for API key instead of URL param (best practice from assistant plugin)
    local model = G_reader_settings:readSetting("gemini_model")
    if not model or model == "" then
        model = DEFAULT_MODEL
    end
    
    local url = BASE_URL .. model .. API_METHOD

    local ok, status_code, _, status_line = https.request {
        url = url,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#json_payload),
            ["x-goog-api-key"] = key
        },
        source = ltn12.source.string(json_payload),
        sink = ltn12.sink.table(response_chunks),
    }

    if not ok or status_code ~= 200 then
        -- Try to decode error body if possible
        local body = table.concat(response_chunks)
        logger.warn("Gemini: API request failed", status_code, status_line)
        logger.warn("Gemini: Error Body:", body:sub(1, 500))
        
        if status_code == 429 then
            return nil, "Rate limit reached (Too Many Requests). Please wait a moment."
        end
        
        return nil, "API Error: " .. (status_line or status_code or "Unknown")
    end

    local body = table.concat(response_chunks)
    local decoded_ok, response_data = pcall(function() return json.decode(body) end)
    
    if not decoded_ok or type(response_data) ~= "table" then
        return nil, "Failed to parse API response"
    end

    -- Extract image data
    -- Structure: candidates[0].content.parts[0].inlineData.data (Base64)
    local image_data_b64 = nil
    if response_data.candidates and response_data.candidates[1] and
       response_data.candidates[1].content and
       response_data.candidates[1].content.parts then
        
        for _, part in ipairs(response_data.candidates[1].content.parts) do
            if part.inlineData and part.inlineData.data then
                image_data_b64 = part.inlineData.data
                break
            end
        end
    end

    if not image_data_b64 then
        logger.warn("Gemini: No image data found. Response:", json.encode(response_data):sub(1,200))
        return nil, "No image generated"
    end

    -- Decode Base64 using pure Lua decoder
    local decode_ok, image_data = pcall(b64decode, image_data_b64)
    if not decode_ok or not image_data then
         return nil, "Failed to decode image data"
    end

    -- Save to Cache
    local filename = "ai_" .. os.time() .. "_" .. math.random(1000, 9999) .. ".jpg"
    local cache_dir = CacheManager.getCacheDir()
    local full_path = cache_dir .. "/" .. filename

    local f = io.open(full_path, "wb")
    if not f then
        return nil, "Failed to save image to cache"
    end
    f:write(image_data)
    f:close()

    logger.info("Gemini: Image saved to", full_path)
    
    return {
        {
            title = prompt,
            description = "Generated by Nano Banana AI",
            thumbnail_url = "file://" .. full_path,
            full_url = "file://" .. full_path,
            is_local = true,
            local_path = full_path
        }
    }
end

GeminiClient.DEFAULT_MODEL = DEFAULT_MODEL

return GeminiClient
