--[[--
HTTP client for the self-hosted koreader-server.

Uses the same socket/ltn12 stack as the cloud storage and OPDS plugins,
so it works on Kindle, Android and desktop builds.
]]

local JSON = require("json")
local http = require("socket.http")
local lfs = require("libs/libkoreader-lfs")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local logger = require("logger")

local Client = {}
Client.__index = Client

local JSON_TIMEOUT = 15
local FILE_BLOCK_TIMEOUT = 60
local FILE_TOTAL_TIMEOUT = 1800

function Client:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    o.base_url = Client.normalize_url(o.base_url)
    return o
end

function Client.normalize_url(url)
    url = url or ""
    url = url:gsub("%s+", "")
    if not url:match("^https?://") then
        url = "https://" .. url
    end
    return (url:gsub("/+$", ""))
end

function Client:url(path)
    return self.base_url .. path
end

function Client:headers(extra)
    local headers = { ["Accept"] = "application/json" }
    if self.token then
        headers["Authorization"] = "Bearer " .. self.token
    end
    for key, value in pairs(extra or {}) do
        headers[key] = value
    end
    return headers
end

function Client:_decode(body)
    if not body or body == "" then
        return {}
    end
    local ok, decoded = pcall(JSON.decode, body)
    if ok then
        return decoded
    end
    return { raw = body }
end

--- JSON request. Returns data, code, error_body.
function Client:request(method, path, body, timeout)
    local payload
    if body ~= nil then
        payload = JSON.encode(body)
    end
    local extra
    if payload then
        extra = {
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#payload),
        }
    end
    local chunks = {}
    socketutil:set_timeout(timeout or JSON_TIMEOUT, (timeout or JSON_TIMEOUT) * 2)
    local ok, code, response_headers, status = pcall(function()
        return socket.skip(1, http.request{
            url = self:url(path),
            method = method,
            headers = self:headers(extra),
            source = payload and ltn12.source.string(payload) or nil,
            sink = ltn12.sink.table(chunks),
        })
    end)
    socketutil:reset_timeout()
    if not ok then
        logger.warn("ShelfSync: request failed", path, code)
        return nil, nil, tostring(code)
    end
    if type(code) ~= "number" then
        return nil, nil, tostring(code or status)
    end
    local data = self:_decode(table.concat(chunks))
    if code >= 200 and code < 300 then
        return data, code
    end
    logger.warn("ShelfSync: server error", path, code, data)
    return nil, code, data
end

function Client:login(username, password, device_id)
    return self:request("POST", "/api/v1/auth/token", {
        username = username,
        password = password,
        device_id = device_id,
    })
end

function Client:info()
    return self:request("GET", "/api/v1/info")
end

function Client:list_books()
    local data, code, err = self:request("GET", "/api/v1/books")
    if not data then
        return nil, code, err
    end
    return data.books or {}, code
end

function Client:sync(cursor)
    local path = "/api/v1/sync?cursor=" .. tostring(cursor or 0)
    return self:request("GET", path)
end

function Client:create_book(book)
    return self:request("POST", "/api/v1/books", book)
end

function Client:get_progress(book_id)
    return self:request("GET", "/api/v1/books/" .. book_id .. "/progress", nil, 5)
end

function Client:put_progress(book_id, progress)
    -- Short timeout: this is called from onCloseDocument/onSuspend.
    return self:request("PUT", "/api/v1/books/" .. book_id .. "/progress", progress, 5)
end

function Client:delete_book(book_id)
    return self:request("DELETE", "/api/v1/books/" .. book_id)
end

--- Upload a file as the book payload. Returns data, code, error.
function Client:upload_file(book_id, path, size, progress_cb)
    local file = io.open(path, "rb")
    if not file then
        return nil, nil, "cannot open file"
    end
    local source = ltn12.source.file(file)
    if progress_cb then
        local original = source
        local sent = 0
        source = function()
            local chunk, err = original()
            if chunk then
                sent = sent + #chunk
                progress_cb(sent)
            end
            return chunk, err
        end
    end
    size = size or lfs.attributes(path, "size") or 0
    local chunks = {}
    local headers = self:headers({
        ["Content-Type"] = "application/octet-stream",
        ["Content-Length"] = tostring(size),
    })
    socketutil:set_timeout(FILE_BLOCK_TIMEOUT, FILE_TOTAL_TIMEOUT)
    local ok, code, response_headers, status = pcall(function()
        return socket.skip(1, http.request{
            url = self:url("/api/v1/books/" .. book_id .. "/file"),
            method = "PUT",
            headers = headers,
            source = source,
            sink = ltn12.sink.table(chunks),
        })
    end)
    socketutil:reset_timeout()
    pcall(function() file:close() end)
    if not ok then
        return nil, nil, tostring(code)
    end
    if type(code) ~= "number" then
        return nil, nil, tostring(code or status)
    end
    local data = self:_decode(table.concat(chunks))
    if code >= 200 and code < 300 then
        return data, code
    end
    return nil, code, data
end

--- Download a cover image. Returns true, code, content_type.
function Client:download_cover(book_id, path)
    local file = io.open(path, "wb")
    if not file then
        return nil, nil, "cannot create file"
    end
    socketutil:set_timeout(JSON_TIMEOUT, JSON_TIMEOUT * 2)
    local ok, code, response_headers, status = pcall(function()
        return socket.skip(1, http.request{
            url = self:url("/api/v1/books/" .. book_id .. "/cover"),
            method = "GET",
            headers = self:headers({ ["Accept"] = "image/*" }),
            sink = ltn12.sink.file(file),
        })
    end)
    socketutil:reset_timeout()
    pcall(function() file:close() end)
    if ok and type(code) == "number" and code >= 200 and code < 300 then
        local content_type
        if type(response_headers) == "table" then
            for key, value in pairs(response_headers) do
                if key:lower() == "content-type" then
                    content_type = value
                    break
                end
            end
        end
        return true, code, content_type
    end
    os.remove(path)
    if not ok then
        return nil, nil, tostring(code)
    end
    return nil, code, status
end

--- Download a book file. Returns true, code, error.
function Client:download_file(book_id, path, size, progress_cb)
    local file = io.open(path, "wb")
    if not file then
        return nil, nil, "cannot create file"
    end
    local sink = ltn12.sink.file(file)
    if progress_cb then
        sink = socketutil.chainSinkWithProgressCallback(sink, progress_cb)
    end
    socketutil:set_timeout(FILE_BLOCK_TIMEOUT, FILE_TOTAL_TIMEOUT)
    local ok, code, response_headers, status = pcall(function()
        return socket.skip(1, http.request{
            url = self:url("/api/v1/books/" .. book_id .. "/file"),
            method = "GET",
            headers = self:headers(),
            sink = sink,
        })
    end)
    socketutil:reset_timeout()
    pcall(function() file:close() end)
    if not ok then
        return nil, nil, tostring(code)
    end
    if type(code) ~= "number" then
        return nil, nil, tostring(code or status)
    end
    if code >= 200 and code < 300 then
        return true, code
    end
    return nil, code, status
end

return Client
