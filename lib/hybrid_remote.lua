-- lib/hybrid_remote.lua
-- Remote record retrieval for OPDS feeds and Komga API.

local logger = require("logger")
local Dedup = require("lib/hybrid_dedup")

local M = {}

-- ---------------------------------------------------------------------------
-- Shared Safety, Validation, Format & Atomic I/O Helpers
-- ---------------------------------------------------------------------------

local DEFAULT_MAX_DOWNLOAD_BYTES = 1024 * 1024 * 1024 -- 1 GiB

local function sanitizeLog(val)
    if val == nil then return "nil" end
    return tostring(val):gsub("[%z\r\n]+", " ")
end

local function safeCall(context, fn, ...)
    local ok, r1, r2, r3, r4 = pcall(fn, ...)
    if not ok then
        logger.warn(string.format("[Hybrid] %s failed: %s", sanitizeLog(context), sanitizeLog(r1)))
        return false, r1
    end
    return true, r1, r2, r3, r4
end

local function asTable(v) return type(v) == "table" and v or nil end
local function asString(v) return type(v) == "string" and v or nil end
local function asNumber(v)
    if type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge then
        return v
    end
    return nil
end
local function asScalar(v)
    return asString(v) or asNumber(v)
end

local function copyTableShallow(t)
    local out = {}
    if type(t) == "table" then
        for k, v in pairs(t) do out[k] = v end
    end
    return out
end

local function validateKomgaId(raw_id)
    if raw_id == nil then return nil end
    local t = type(raw_id)
    local s
    if t == "string" then
        s = raw_id
    elseif t == "number" and asNumber(raw_id) and math.floor(raw_id) == raw_id then
        s = tostring(raw_id)
    else
        return nil
    end
    if s == "" or #s > 128 or not s:match("^[%w%-_]+$") then
        return nil
    end
    return s
end

local function validateTypeLabel(label)
    if label == "series" or label == "book" then
        return label
    end
    return nil
end

local function sanitizePathComponent(raw, fallback)
    if type(raw) ~= "string" or raw == "" then return fallback end
    if raw:find("%z") or raw:find("%.%.") or raw:lower():find("%%2e%%2e") or raw:match("^%.+$") then
        return fallback
    end
    local clean = raw:gsub("[/\\?%%*:|\"<>]", "_"):gsub("%z", ""):gsub("^%.+", "_"):gsub("%.%.+", "_")
    if clean == "" or clean == "_" or clean == "." or clean == ".." then
        return fallback
    end
    return clean
end

local function normalizeAbsPath(p)
    if type(p) ~= "string" or p == "" or p:find("%z") then return nil end
    if p:find("/%.%./") or p:find("/%.%.$") or p:find("^%.%./") or p == ".." then
        return nil
    end
    local norm = p:gsub("//+", "/")
    if #norm > 1 then norm = norm:gsub("/+$", "") end
    return norm
end

local function isPathWithinRoot(candidate_path, root_dir)
    local norm_cand = normalizeAbsPath(candidate_path)
    local norm_root = normalizeAbsPath(root_dir)
    if not norm_cand or not norm_root then return false end
    if norm_cand == norm_root then return true end
    return norm_cand:sub(1, #norm_root + 1) == norm_root .. "/"
end

local function parseHttpUrl(url)
    if type(url) ~= "string" or url == "" or url:find("[%z\r\n]") then return nil end
    local scheme, rest = url:match("^([%a][%w+.-]*)://(.+)$")
    if not scheme then return nil end
    scheme = scheme:lower()
    if scheme ~= "http" and scheme ~= "https" then return nil end
    local authority = rest:match("^([^/?#]+)")
    if not authority or authority == "" or authority:find("\\", 1, true) then return nil end
    -- Strip optional userinfo (match last @)
    local hostport = authority:match("^.*@([^@]+)$") or authority
    local host, port_str
    if hostport:sub(1, 1) == "[" then
        host, port_str = hostport:match("^(%b[]):?(%d*)$")
    else
        host, port_str = hostport:match("^([^:]+):?(%d*)$")
    end
    if not host or host == "" then return nil end
    local port = tonumber(port_str) or (scheme == "https" and 443 or 80)
    return { scheme = scheme, host = host:lower(), port = port }
end

local function isAllowedHttpUrl(url)
    return parseHttpUrl(url) ~= nil
end

local function isSameHost(url_a, url_b)
    local a = parseHttpUrl(url_a)
    local b = parseHttpUrl(url_b)
    if not (a and b) then return false end
    return a.host == b.host
end

local function isSameOriginForAuth(target_url, base_url)
    local t = parseHttpUrl(target_url)
    local b = parseHttpUrl(base_url)
    if not (t and b) then return false end
    if b.scheme == "https" and t.scheme ~= "https" then return false end
    return t.scheme == b.scheme and t.host == b.host and t.port == b.port
end

local FORMATS = {
    ["application/zip"] = "CBZ",
    ["application/x-cbz"] = "CBZ",
    ["application/x-zip-compressed"] = "CBZ",
    ["application/epub+zip"] = "EPUB",
    ["application/pdf"] = "PDF",
    ["application/x-cbr"] = "CBR",
    ["application/x-rar-compressed"] = "CBR",
    ["application/x-rar"] = "CBR",
}

local function deriveFormat(media_type, filename, title)
    if media_type and FORMATS[media_type] then
        return FORMATS[media_type]
    end
    for _, str in ipairs({ filename, title }) do
        if type(str) == "string" then
            local ext = str:match("%.([a-zA-Z0-9]+)$")
            if ext then
                local u = ext:upper()
                if u == "CBZ" or u == "ZIP" then return "CBZ" end
                if u == "CBR" or u == "RAR" then return "CBR" end
                if u == "EPUB" then return "EPUB" end
                if u == "PDF" then return "PDF" end
                if u == "MOBI" or u == "AZW3" or u == "FB2" or u == "TXT" then return u end
            end
        end
    end
    return "CBZ"
end

local function copyFileChunked(src_path, dst_path, chunk_size)
    chunk_size = chunk_size or 65536
    local rf, rerr = io.open(src_path, "rb")
    if not rf then return false, "Failed to open source: " .. tostring(rerr) end
    local wf, werr = io.open(dst_path, "wb")
    if not wf then
        pcall(rf.close, rf)
        return false, "Failed to open destination: " .. tostring(werr)
    end
    local copy_ok = true
    local copy_err = nil
    while true do
        local chunk = rf:read(chunk_size)
        if not chunk then break end
        local ok_w, err_w = wf:write(chunk)
        if not ok_w then
            copy_ok = false
            copy_err = "Write failed: " .. tostring(err_w)
            break
        end
    end
    pcall(rf.close, rf)
    local ok_c, err_c = wf:close()
    if copy_ok and not ok_c then
        copy_ok = false
        copy_err = "Close failed: " .. tostring(err_c)
    end
    if not copy_ok then
        pcall(os.remove, dst_path)
        return false, copy_err
    end
    return true
end

local function resolveCaBundle()
    local file_candidates = {
        "/etc/ssl/certs/ca-certificates.crt",
        "/etc/ssl/cert.pem",
    }
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if ok_ds and DataStorage and DataStorage.getDataDir then
        local dd = DataStorage:getDataDir()
        if type(dd) == "string" and dd ~= "" then
            table.insert(file_candidates, 1, dd .. "/data/ca-bundle.crt")
        end
    end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    for _, path in ipairs(file_candidates) do
        local is_file = false
        if ok_lfs and lfs and lfs.attributes then
            local ok_a, mode = pcall(lfs.attributes, path, "mode")
            is_file = ok_a and mode == "file"
        else
            local f = io.open(path, "rb")
            if f then f:close(); is_file = true end
        end
        if is_file then return path, nil end
    end
    if ok_lfs and lfs and lfs.attributes then
        local ok_a, mode = pcall(lfs.attributes, "/system/etc/security/cacerts", "mode")
        if ok_a and mode == "directory" then
            return nil, "/system/etc/security/cacerts"
        end
    end
    return nil, nil
end

-- ---------------------------------------------------------------------------
-- OPDS Provider
-- ---------------------------------------------------------------------------

function M.getOpdsRecords(source)
    local ok_w, OpdsWindow = pcall(require, "lib/bookshelf_opds_window")
    if not (ok_w and OpdsWindow) then return {}, false end

    local server_id = source.opds_id or source.id
    local feed_url = source.feed_url
    if not feed_url and server_id then
        local ok_s, OpdsSource = pcall(require, "lib/bookshelf_opds_source")
        local server = ok_s and OpdsSource and OpdsSource.getServer(server_id)
        feed_url = server and server.url
    end
    if not (server_id and feed_url) then return {}, false end

    local win = OpdsWindow.load(server_id, feed_url)
    if type(win) ~= "table" then return {}, true end
    local count = tonumber(win.count) or 0
    local records = {}

    if count > 0 then
        local page = OpdsWindow.slice(win, 0, count) or {}
        for i = 1, #page do
            local rec = page[i]
            rec.source_kind = "hybrid"
            rec.is_remote = not rec.downloaded
            rec.label = rec.label or rec.title or rec.series_name
            rec.title = rec.title or rec.label or rec.series_name
            rec.display_title = rec.display_title or rec.title
            rec.series_name = rec.series_name or rec.label or rec.title
            if not rec.is_folder and not rec.is_opds_nav and not rec.format then
                local mt = rec.media_type or (rec.opds and rec.opds.media_type)
                local fmt = deriveFormat(mt, rec.filename or rec.filepath, rec.title)
                rec.format = fmt
                rec.ext = fmt:lower()
                rec.extension = fmt:lower()
            end
            records[#records + 1] = rec
        end
    end

    local needs_fetch = not win.complete or (count == 0 and (tonumber(win.fetched_at) or 0) == 0)

    -- Attach covers / decoration if available
    local ok_c, OpdsCovers = pcall(require, "lib/bookshelf_opds_covers")
    if ok_c and OpdsCovers then
        for _, rec in ipairs(records) do
            local cp = OpdsCovers.cachedPath(rec)
            rec.cover_image_path = cp
            if cp then rec.has_cover = true end
            if (rec.is_opds_nav or rec.kind == "folder") and not rec.first_book then
                rec.first_book = {
                    filepath = rec.filepath,
                    cover_image_path = cp,
                    title = rec.title or rec.label,
                    author = rec.author,
                    has_cover = cp ~= nil,
                }
            end
        end
    end

    return records, needs_fetch
end

function M.getOpdsFolderRecords(source, folder_path)
    local folder_name = type(folder_path) == "string"
        and folder_path:gsub("/+$", ""):match("([^/]+)$") or nil
    local folder_key = Dedup.nameKey(folder_name)
    if not folder_key then return {}, false end

    local ok_w, OpdsWindow = pcall(require, "lib/bookshelf_opds_window")
    if not (ok_w and OpdsWindow) then return {}, false end

    local root_records, root_needs_fetch = M.getOpdsRecords(source)
    local records = {}
    local needs_fetch = root_needs_fetch == true

    for _, nav in ipairs(root_records) do
        local nav_key = (nav.is_opds_nav or nav.is_folder) and Dedup.nameKey(nav.label or nav.name or nav.title)
        local child_feed_url = nav.opds and nav.opds.feed_url
        if Dedup.nameKeysMatch(nav_key, folder_key) and type(child_feed_url) == "string" then
            local server_id = source.opds_id or source.id
            local child = OpdsWindow.load(server_id, child_feed_url)
            if type(child) == "table" then
                local child_count = tonumber(child.count) or 0
                if child_count > 0 then
                    local page = OpdsWindow.slice(child, 0, child_count) or {}
                    for i = 1, #page do
                        local rec = page[i]
                        rec.source_kind = "hybrid"
                        rec.is_remote = not rec.downloaded
                        rec.label = rec.label or rec.title or rec.series_name
                        rec.title = rec.title or rec.label or rec.series_name
                        rec.display_title = rec.display_title or rec.title
                        rec.series_name = rec.series_name or rec.label or rec.title
                        records[#records + 1] = rec
                    end
                end
                if not child.complete or (child_count == 0 and (tonumber(child.fetched_at) or 0) == 0) then
                    needs_fetch = true
                end
            else
                needs_fetch = true
            end
        end
    end

    return records, needs_fetch
end

-- ---------------------------------------------------------------------------
-- Komga Native Provider
-- ---------------------------------------------------------------------------

local function liveModule(name)
    for _, mod in ipairs({ "apps/filemanager/filemanager", "apps/reader/readerui" }) do
        local ok, m = pcall(require, mod)
        local found = ok and m and m.instance and m.instance[name]
        if found then return found end
    end
end

local function usable(plugin)
    return plugin and plugin.settings and plugin.api and plugin.sync and plugin.cache and plugin
end

local function getUpvalueByName(fn, target_name)
    if type(fn) ~= "function" then return nil end
    if type(debug) ~= "table" or type(debug.getupvalue) ~= "function" then return nil end
    local i = 1
    while true do
        local ok, name, val = pcall(debug.getupvalue, fn, i)
        if not ok or not name then break end
        if name == target_name then return val end
        i = i + 1
    end
    return nil
end

local function extractFromKomgaSpec()
    local ok_s, Sources = pcall(require, "lib/bookshelf_sources")
    local komga_spec = ok_s and Sources and Sources.get and Sources.get("komga")
    if not (komga_spec and komga_spec.fetch) then return nil end
    local liveFn = getUpvalueByName(komga_spec.fetch, "livePlugin")
    if type(liveFn) == "function" then
        local p = getUpvalueByName(liveFn, "registered_plugin") or liveFn()
        if usable(p) then return p end
    end
    return nil
end

local function getKomgaPlugin()
    local ok_b, Bridge = pcall(require, "lib/bridge_menu_patch")
    if not ok_b or not (Bridge and (Bridge.getKomgaPlugin or Bridge.getKokomgaPlugin)) then
        local ok_pl, PluginLoader = pcall(require, "pluginloader")
        local loaded = ok_pl and PluginLoader and PluginLoader.loaded_plugins or nil
        Bridge = loaded and loaded["kokomga_bookshelf_bridge"]
    end
    if Bridge then
        local fn = Bridge.getKomgaPlugin or Bridge.getKokomgaPlugin
        if fn then
            local kp = fn()
            if usable(kp) then return kp end
        end
    end

    local ext = extractFromKomgaSpec()
    if usable(ext) then return ext end

    local live = liveModule("kokomga")
    if usable(live) then return live end

    local ok_p, PluginLoader = pcall(require, "pluginloader")
    local loaded = ok_p and PluginLoader and PluginLoader.loaded_plugins or nil
    local p = loaded and loaded["kokomga"]
    if usable(p) then return p end

    for k, v in pairs(package.loaded) do
        if type(k) == "string" and k:find("kokomga") and usable(v) then
            return v
        end
    end

    return live or p or nil
end

local function patchApiTable(target)
    if type(target) ~= "table" or type(target.get_books_for_series) ~= "function" then return false end
    if target._bridge_sort_patched then return true end
    target._bridge_sort_patched = true

    local orig_get_books = target.get_books_for_series
    target.get_books_for_series = function(self, series_id, filters, page, size)
        local ok_res, res, err = pcall(orig_get_books, self, series_id, filters, page, size)
        if ok_res and res then
            -- Retry without sort ONLY if server explicitly rejected sort (HTTP 400 / sort error)
            local is_sort_err = type(res) == "table" and (res.status == 400 or res.code == 400)
                and (tostring(res.error or res.message or ""):lower():find("sort") ~= nil)
            if not is_sort_err then
                return res, err
            end
        elseif ok_res and not res and filters and filters.sort then
            local err_s = tostring(err or ""):lower()
            if not (err_s:find("400") or err_s:find("sort")) then
                return res, err
            end
        elseif not ok_res then
            error(res, 0)
        end

        if filters and filters.sort then
            local clean = {}
            for k, v in pairs(filters) do clean[k] = v end
            clean.sort = nil
            return orig_get_books(self, series_id, clean, page, size)
        end
        return res, err
    end
    return true
end

local function ensureKomgaApiPatched()
    for k, v in pairs(package.loaded) do
        if type(k) == "string" and k:find("core/api") and type(v) == "table" then
            patchApiTable(v)
        end
    end
    local komga = getKomgaPlugin()
    if komga and komga.api then
        patchApiTable(komga.api)
        patchApiTable(getmetatable(komga.api))
    end
end

M.ensureKomgaApiPatched = ensureKomgaApiPatched

local function trimBook(book)
    if type(book) ~= "table" then return nil end
    local valid_id = validateKomgaId(book.id)
    if not valid_id then return nil end
    local md = asTable(book.metadata) or {}
    local media = asTable(book.media) or {}
    local progress = asTable(book.readProgress)
    local authors = {}
    for _, a in ipairs(asTable(md.authors) or asTable(book.authors) or {}) do
        local name = asTable(a) and asString(a.name) or (type(a) == "string" and a or nil)
        local role = asTable(a) and asString(a.role) or nil
        if name and name ~= "" then
            authors[#authors + 1] = { name = name, role = role }
        end
    end
    return {
        id = valid_id,
        name = asString(book.name),
        seriesId = validateKomgaId(book.seriesId),
        seriesTitle = asString(book.seriesTitle),
        oneshot = book.oneshot == true,
        lastModified = asString(book.lastModified),
        media = { mediaType = asString(media.mediaType), pagesCount = asNumber(media.pagesCount) },
        number = asScalar(book.number or md.number),
        numberSort = asNumber(book.numberSort or md.numberSort),
        metadata = {
            title = asString(md.title),
            number = asScalar(md.number or book.number),
            numberSort = asNumber(md.numberSort or book.numberSort),
            summary = asString(md.summary),
        },
        authors = authors,
        readProgress = progress and {
            page = asNumber(progress.page),
            completed = progress.completed == true,
        } or nil,
    }
end

local function trimBooks(content, limit)
    local items = {}
    for _, book in ipairs(content or {}) do
        local item = asTable(book) and trimBook(book)
        if item and item.id then items[#items + 1] = item end
        if limit and #items >= limit then break end
    end
    return items
end

local function trimSeries(series)
    if type(series) ~= "table" then return nil end
    local valid_id = validateKomgaId(series.id)
    if not valid_id then return nil end
    local md = asTable(series.metadata) or {}
    return {
        id = valid_id,
        title = asString(md.title) or asString(series.name),
        summary = asString(md.summary),
        lastModified = asString(series.lastModified),
        booksCount = asNumber(series.booksCount),
        booksReadCount = asNumber(series.booksReadCount),
        booksUnreadCount = asNumber(series.booksUnreadCount),
        booksInProgressCount = asNumber(series.booksInProgressCount),
    }
end

local function seriesStatus(dto)
    local total = dto.booksCount
    local read = dto.booksReadCount or 0
    if total and total > 0 and read >= total then return "finished" end
    if read > 0 or (dto.booksInProgressCount or 0) > 0 then return "reading" end
    return "unread"
end

local function createKomgaApiFallback()
    local ok_ds, DataStorage = pcall(require, "datastorage")
    local ok_ls, LuaSettings = pcall(require, "luasettings")
    if not (ok_ds and DataStorage and ok_ls and LuaSettings) then return nil end
    local ok_s_file, s = safeCall("createKomgaApiFallback.open", LuaSettings.open, LuaSettings, DataStorage:getSettingsDir() .. "/kokomga.lua")
    local url = ok_s_file and s and s:readSetting("server_url")
    local key = ok_s_file and s and s:readSetting("api_key")
    local auth_h = ok_s_file and s and s:readSetting("auth_header")
    if isAllowedHttpUrl(url) and ((key and key ~= "") or (auth_h and auth_h ~= "")) then
        local candidates = {
            "kokomga/core/api",
            "plugins/kokomga.koplugin/core/api",
            "core/api",
        }
        for _, mod_name in ipairs(candidates) do
            local ok_m, api_cls = pcall(require, mod_name)
            if ok_m and type(api_cls) == "table" and type(api_cls.new) == "function" then
                local ok_a, new_api = safeCall("createKomgaApiFallback.new", api_cls.new, api_cls, url, key or "")
                if ok_a and new_api then
                    if auth_h and auth_h ~= "" then new_api.auth_header = auth_h end
                    patchApiTable(new_api)
                    patchApiTable(getmetatable(new_api))
                    return new_api
                end
            end
        end
    end
    return nil
end

local function getKomgaApi()
    local komga = getKomgaPlugin()
    local api = komga and komga.api
    if not api then
        api = createKomgaApiFallback()
    end
    if api then
        patchApiTable(api)
        patchApiTable(getmetatable(api))
    end
    return api
end

local _cover_path_cache = {}
local _dir_entries_cache = {}
local _dir_exists_cache = {}
local _series_title_to_id = nil
local _mem_all_series = {}

function M.clearCoverPathCache()
    _cover_path_cache = {}
    _dir_entries_cache = {}
    _dir_exists_cache = {}
    _series_title_to_id = nil
    _mem_all_series = {}
end

function M.clearAllSeriesCache(lib_key)
    if lib_key then
        _mem_all_series[lib_key] = nil
    else
        _mem_all_series = {}
    end
end

function M.purgeDeletedSeries(series_id, series_title)
    if M.invalidateSeriesMemo then M.invalidateSeriesMemo() end
    if not series_id and not series_title then return false end
    local sid_str = series_id and validateKomgaId(series_id) or nil
    if series_id and not sid_str then
        logger.warn("[Hybrid] purgeDeletedSeries rejected invalid series_id: " .. sanitizeLog(series_id))
        return false, "invalid_series_id"
    end
    _mem_all_series = {}
    local title_key = series_title and Dedup.nameKey(series_title) or nil

    logger.info(string.format("[Hybrid] Purging deleted series from caches: id=%s title=%s", sanitizeLog(sid_str), sanitizeLog(series_title)))

    -- 1. Persistent cache in kokomga_bookshelf.lua
    local flush_ok = true
    local flush_err = nil
    local ok_persist, err_persist = safeCall("purgeDeletedSeries.persist", function()
        local DataStorage = require("datastorage")
        local LuaSettings = require("luasettings")
        local s = LuaSettings:open(DataStorage:getSettingsDir() .. "/kokomga_bookshelf.lua")
        if not s then return end

        local modified = false

        -- A. series table
        local series_entries = s:readSetting("series")
        if series_entries and sid_str and series_entries[sid_str] then
            series_entries[sid_str] = nil
            s:saveSetting("series", series_entries)
            modified = true
        end

        -- B. lists table (active_queue, all_series, keep_reading, on_deck, etc.)
        local lists = s:readSetting("lists")
        if lists then
            -- B1. active_queue
            local aq = lists["active_queue"]
            if aq and aq.items then
                local by_s = aq.items.by_series
                if by_s and sid_str and by_s[sid_str] then
                    by_s[sid_str] = nil
                    modified = true
                end
                if by_s and title_key then
                    for k, v in pairs(by_s) do
                        if v and v.seriesTitle and Dedup.nameKeysMatch(Dedup.nameKey(v.seriesTitle), title_key) then
                            by_s[k] = nil
                            modified = true
                        end
                    end
                end
                local s_order = aq.items.series_order
                if s_order then
                    local new_order = {}
                    for _, sid in ipairs(s_order) do
                        if tostring(sid) ~= sid_str then
                            new_order[#new_order + 1] = sid
                        else
                            modified = true
                        end
                    end
                    aq.items.series_order = new_order
                end
            end

            -- B2. Other lists
            for list_name, list_entry in pairs(lists) do
                if list_name ~= "active_queue" and list_entry and list_entry.items and type(list_entry.items) == "table" then
                    local new_items = {}
                    local list_mod = false
                    for _, item in ipairs(list_entry.items) do
                        local match = false
                        if sid_str and (tostring(item.id) == sid_str or tostring(item.seriesId) == sid_str) then
                            match = true
                        elseif title_key and (item.title or item.name) and Dedup.nameKeysMatch(Dedup.nameKey(item.title or item.name), title_key) then
                            match = true
                        end
                        if match then
                            list_mod = true
                        else
                            new_items[#new_items + 1] = item
                        end
                    end
                    if list_mod then
                        list_entry.items = new_items
                        modified = true
                    end
                end
            end

            if modified then
                s:saveSetting("lists", lists)
            end
        end

        -- C. pages table (all_series|0, all_series|1, etc.)
        local pages = s:readSetting("pages")
        if pages then
            local pages_mod = false
            for pkey, pentry in pairs(pages) do
                if pentry and pentry.items and type(pentry.items) == "table" then
                    local new_items = {}
                    local p_mod = false
                    for _, item in ipairs(pentry.items) do
                        local match = false
                        if sid_str and (tostring(item.id) == sid_str or tostring(item.seriesId) == sid_str) then
                            match = true
                        elseif title_key and (item.title or item.name) and Dedup.nameKeysMatch(Dedup.nameKey(item.title or item.name), title_key) then
                            match = true
                        end
                        if match then
                            p_mod = true
                        else
                            new_items[#new_items + 1] = item
                        end
                    end
                    if p_mod then
                        pentry.items = new_items
                        if pentry.total and pentry.total > 0 then
                            pentry.total = math.max(0, pentry.total - 1)
                        end
                        pages_mod = true
                    end
                end
            end
            if pages_mod then
                s:saveSetting("pages", pages)
                modified = true
            end
        end

        -- D. all_series table
        local all_s = s:readSetting("all_series")
        if all_s then
            local as_mod = false
            for lib_key, lentry in pairs(all_s) do
                if lentry and lentry.items and type(lentry.items) == "table" then
                    local new_items = {}
                    local l_mod = false
                    for _, item in ipairs(lentry.items) do
                        local match = false
                        if sid_str and (tostring(item.id) == sid_str or tostring(item.seriesId) == sid_str) then
                            match = true
                        elseif title_key and (item.title or item.name) and Dedup.nameKeysMatch(Dedup.nameKey(item.title or item.name), title_key) then
                            match = true
                        end
                        if match then
                            l_mod = true
                        else
                            new_items[#new_items + 1] = item
                        end
                    end
                    if l_mod then
                        lentry.items = new_items
                        as_mod = true
                    end
                end
            end
            if as_mod then
                s:saveSetting("all_series", all_s)
                modified = true
            end
        end

        if modified then
            local ok_f, err_f = s:flush()
            if ok_f == false then
                flush_ok = false
                flush_err = err_f or "flush failed"
            end
        end
    end)

    -- 2. In-memory caches in hybrid_remote
    if _series_title_to_id then
        if title_key then _series_title_to_id[title_key] = nil end
        if sid_str then
            for k, v in pairs(_series_title_to_id) do
                if tostring(v) == sid_str then _series_title_to_id[k] = nil end
            end
        end
    end
    M.clearCoverPathCache()

    -- 3. Cover files on disk (aligned with DataStorage:getDataDir()/komga_covers)
    if sid_str then
        safeCall("purgeDeletedSeries.removeCovers", function()
            local DataStorage = require("datastorage")
            local dirs = {}
            if DataStorage and DataStorage.getDataDir then
                local dd = DataStorage:getDataDir()
                if dd then dirs[#dirs + 1] = dd .. "/komga_covers" end
            end
            if DataStorage and DataStorage.getSettingsDir then
                local sd = DataStorage:getSettingsDir()
                if sd then dirs[#dirs + 1] = sd .. "/cache/komga_covers" end
            end
            for _, cover_dir in ipairs(dirs) do
                for _, ext in ipairs({ ".jpg", ".jpeg", ".png" }) do
                    local target = cover_dir .. "/series_" .. sid_str .. ext
                    if isPathWithinRoot(target, cover_dir) then
                        os.remove(target)
                    end
                end
            end
        end)
    end

    -- 4. In-memory caches in hybrid_spec
    local ok_sp, HybridSpec = pcall(require, "lib/hybrid_spec")
    if ok_sp and HybridSpec and HybridSpec.clearCachesForSeries then
        HybridSpec.clearCachesForSeries(sid_str, title_key)
    end

    -- 5. Notify bookshelf
    local ok_src, Sources = pcall(require, "lib/bookshelf_sources")
    if ok_src and Sources and Sources.changed then
        Sources.changed("hybrid")
    end

    if not ok_persist then
        return false, err_persist
    end
    if not flush_ok then
        return false, flush_err
    end
    return true
end

function M.lookupSeriesIdByTitle(title)
    if type(title) ~= "string" or title == "" then return nil end
    local title_key = Dedup.nameKey(title)
    if not title_key then return nil end

    if not _series_title_to_id then
        local loaded_map = {}
        local ok_load = safeCall("lookupSeriesIdByTitle.load", function()
            local DataStorage = require("datastorage")
            local LuaSettings = require("luasettings")
            local s = LuaSettings:open(DataStorage:getSettingsDir() .. "/kokomga_bookshelf.lua")
            if s then
                local pages = s:readSetting("pages") or {}
                for _, page in pairs(pages) do
                    local items = page and page.items
                    if items then
                        for _, item in ipairs(items) do
                            local valid_id = item and validateKomgaId(item.id)
                            if valid_id and item.title then
                                local k = Dedup.nameKey(item.title)
                                if k and not loaded_map[k] then
                                    loaded_map[k] = valid_id
                                end
                            end
                        end
                    end
                end
            end
        end)
        if not ok_load then
            return nil
        end
        _series_title_to_id = loaded_map
    end

    if _series_title_to_id[title_key] then
        return _series_title_to_id[title_key]
    end

    local collapsed = title_key:gsub("%s+", "")
    for k, sid in pairs(_series_title_to_id) do
        if k:gsub("%s+", "") == collapsed or Dedup.nameKeysMatch(title_key, k) then
            return sid
        end
    end
    return nil
end

function M.getKomgaCoverPath(type_label, id, title, fallback_id)
    type_label = validateTypeLabel(type_label)
    if not type_label then return nil end
    if id ~= nil then
        id = validateKomgaId(id)
        if not id then return nil end
    end
    if fallback_id ~= nil then
        fallback_id = validateKomgaId(fallback_id)
    end
    if not id and type_label == "series" and title then
        id = M.lookupSeriesIdByTitle(title)
    end

    local cache_key = tostring(type_label) .. ":" .. tostring(id or "") .. ":" .. tostring(title or "") .. ":" .. tostring(fallback_id or "")
    local cached = _cover_path_cache[cache_key]
    if cached ~= nil then
        return cached or nil
    end

    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    local now_ts = os.time()
    local function getDirEntries(dir)
        if not (ok_lfs and lfs and lfs.dir and lfs.attributes) then return nil end
        local de = _dir_exists_cache[dir]
        if de and (now_ts - de.ts) < 60 and not de.ok then
            return false
        end
        local cached_dir = _dir_entries_cache[dir]
        if cached_dir and (now_ts - cached_dir.ts) < 30 then
            return cached_dir.set
        end
        local ok_m, mode = pcall(lfs.attributes, dir, "mode")
        if not (ok_m and mode == "directory") then
            _dir_exists_cache[dir] = { ok = false, ts = now_ts }
            return false
        end
        _dir_exists_cache[dir] = { ok = true, ts = now_ts }
        local set = {}
        local ok_iter = pcall(function()
            for entry in lfs.dir(dir) do
                if entry ~= "." and entry ~= ".." then
                    set[entry] = true
                end
            end
        end)
        if not ok_iter then return nil end
        _dir_entries_cache[dir] = { set = set, ts = now_ts }
        return set
    end

    local function exists(p)
        if type(p) ~= "string" or p == "" then return false end
        local dir, fname = p:match("^(.*)/([^/]+)$")
        if dir and fname then
            local entries = getDirEntries(dir)
            if entries == false then return false end
            if type(entries) == "table" then
                return entries[fname] == true
            end
        end
        if ok_lfs and lfs and lfs.attributes then
            local ok_a, m = pcall(lfs.attributes, p, "mode")
            return ok_a and m == "file"
        end
        local f = io.open(p, "rb")
        if f then f:close(); return true end
        return false
    end

    local dirs = {}
    local seen_dirs = {}
    local function addDir(d)
        if d and not seen_dirs[d] then
            seen_dirs[d] = true
            dirs[#dirs + 1] = d
        end
    end
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if ok_ds and DataStorage and DataStorage.getDataDir then
        local dd = DataStorage:getDataDir()
        if dd then
            addDir(dd .. "/komga_covers")
            addDir(dd .. "/komga")
        end
    end
    addDir("/sdcard/koreader/komga_covers")
    addDir("/storage/emulated/0/koreader/komga_covers")

    local exts = { ".jpg", ".jpeg", ".png" }

    -- 1. Check primary cover cache file
    if id then
        for _, d in ipairs(dirs) do
            for _, ext in ipairs(exts) do
                local p = d .. "/" .. tostring(type_label) .. "_" .. tostring(id) .. ext
                if exists(p) then
                    _cover_path_cache[cache_key] = p
                    return p
                end
            end
        end
    end

    -- 2. If series title is known, check local series folder cover
    if (type_label == "series" or not id) and type(title) == "string" and title ~= "" then
        if title:find("%z") or title:find("%.%.") or title:lower():find("%%2e%%2e") or title:match("^%.+$") then
            return nil
        end
        local sanitized = title:gsub("[:?*\"<>/|\\]", "_")
        local local_roots = {
            "/sdcard/koreader/komga",
            "/storage/emulated/0/koreader/komga",
        }
        if ok_ds and DataStorage and DataStorage.getDataDir then
            local dd = DataStorage:getDataDir()
            if dd then local_roots[#local_roots + 1] = dd .. "/komga" end
        end
        for _, root in ipairs(local_roots) do
            local candidates = {
                root .. "/" .. sanitized .. "/.cover.jpg",
            }
            for _, lp in ipairs(candidates) do
                if exists(lp) then
                    _cover_path_cache[cache_key] = lp
                    return lp
                end
            end
        end
    end

    -- 3. Fallback checks:
    -- If series cover was requested, but missing, check fallback_id (active_book id)
    if type_label == "series" and fallback_id then
        for _, d in ipairs(dirs) do
            for _, ext in ipairs(exts) do
                local p = d .. "/book_" .. tostring(fallback_id) .. ext
                if exists(p) then
                    _cover_path_cache[cache_key] = p
                    return p
                end
            end
        end
    end

    -- If book cover was requested, but missing, check fallback_id (series id)
    if type_label == "book" and fallback_id then
        for _, d in ipairs(dirs) do
            for _, ext in ipairs(exts) do
                local p = d .. "/series_" .. tostring(fallback_id) .. ext
                if exists(p) then
                    _cover_path_cache[cache_key] = p
                    return p
                end
            end
        end
    end

    _cover_path_cache[cache_key] = false
    return nil
end
local getKomgaCoverPath = M.getKomgaCoverPath

local function bookDtoToRecord(dto, fallback_label, fallback_summary, downloaded)
    if type(dto) ~= "table" then return nil end
    downloaded = downloaded or Dedup.getDownloadedMap()
    local md = asTable(dto.metadata) or {}
    local title = md.title or dto.name or "?"
    local id_str = validateKomgaId(dto.id) or (dto.id ~= nil and tostring(dto.id) or nil)
    local rec_key = id_str and ("komga://book/" .. id_str) or "komga://book/"
    local local_path = id_str and (downloaded[rec_key] or downloaded[id_str]) or nil

    if local_path and not Dedup.fileExists(local_path) then
        local_path = nil
    end

    -- 1. Pure server progress (never overwritten by local sidecar)
    local progress = asTable(dto.readProgress)
    local media = asTable(dto.media)
    local page_count = (media and asNumber(media.pagesCount)) or 0
    local current_page = (progress and asNumber(progress.page)) or 0
    local srv_completed = (progress and progress.completed == true) or false
    local srv_pct = (srv_completed and 1.0)
        or (page_count > 0 and current_page > 0 and math.min(current_page / page_count, 0.99))
        or 0
    local srv_status = (srv_completed and "finished")
        or ((progress and current_page > 0) and "reading" or "unread")

    -- 2. Local KOReader progress (BookList cache -> DocSettings)
    local loc_completed = false
    local loc_pct = 0
    local loc_status = "unread"
    if local_path then
        local l_st, l_pct = Dedup.checkLocalReadingProgress(local_path)
        if l_st == "finished" then
            loc_completed = true
            loc_status = "finished"
            loc_pct = 1.0
        elseif l_st == "reading" then
            loc_status = "reading"
            loc_pct = asNumber(tonumber(l_pct)) or 0
        end
    end

    -- 3. Reconcile (server, local, SyncQueue)
    local status = srv_status
    local pct = srv_pct
    if loc_completed or srv_completed then
        status = "finished"
        pct = 1.0
    elseif loc_pct > srv_pct then
        status = "reading"
        pct = loc_pct
    elseif loc_status == "reading" and status == "unread" then
        status = "reading"
        pct = math.max(srv_pct, loc_pct)
    end

    if id_str then
        local q = Dedup.scopedSyncQueue()
        local queued = asTable(q) and asTable(q[id_str]) or nil
        if queued then
            local queued_completed = (queued.completed == true)
            if queued.action == "delete" then
                -- Offline mark-unread overrides cached server/local progress until flushed; never prune on render
                status = "unread"
                pct = 0
            elseif queued_completed then
                status = "finished"
                pct = 1.0
            elseif srv_completed then
                -- Pure server is finished while queued item is not -> prune stale queue item
                Dedup.deferSyncQueueRemove(id_str)
            elseif asNumber(queued.page) and page_count > 0 then
                local queued_pct = math.min(queued.page / page_count, 0.99)
                if queued_pct > srv_pct then
                    status = "reading"
                    pct = math.max(queued_pct, loc_pct)
                else
                    -- Pure server is further or equal -> prune stale queue item
                    Dedup.deferSyncQueueRemove(id_str)
                end
            end
        end
    end

    local authors_arr = {}
    if dto.authors then
        for _, a in ipairs(dto.authors) do
            local name = type(a) == "table" and a.name or a
            if name then authors_arr[#authors_arr + 1] = name end
        end
    elseif md.authors then
        for _, a in ipairs(md.authors) do
            local name = type(a) == "table" and a.name or a
            if name then authors_arr[#authors_arr + 1] = name end
        end
    end

    local media_type = dto.media and dto.media.mediaType
    local fmt = deriveFormat(media_type, dto.name, title)

    local cp = getKomgaCoverPath("book", dto.id, title, dto.seriesId)

    return {
        filepath = local_path or rec_key,
        filename = dto.name or title,
        title = title,
        display_title = title,
        label = title,
        author = authors_arr[1] or "",
        authors = #authors_arr > 0 and authors_arr or nil,
        series_name = dto.seriesTitle or fallback_label,
        series_num = md.number and tostring(md.number) or nil,
        description = (md.summary and md.summary ~= "" and md.summary) or fallback_summary,
        book_pct = pct,
        percent_finished = pct,
        status = status,
        _status = status,
        read_status = status,
        is_completed = (status == "finished"),
        format = fmt,
        ext = fmt:lower(),
        extension = fmt:lower(),
        added_time = 0,
        last_read_time = 0,
        last_opened = 0,
        attr = { mode = "file", size = 0, modification = 0 },
        cover_image_path = cp,
        has_cover = (cp ~= nil) or (local_path ~= nil),
        downloaded = local_path ~= nil,
        is_remote = local_path == nil,
        is_komga = true,
        source_kind = "hybrid",
        kind = "book",
        komga_book_id = dto.id,
        komga_id = dto.id,
        komga_dto = dto,
        page_count = (dto.media and dto.media.pagesCount and dto.media.pagesCount > 0 and dto.media.pagesCount) or 200,
    }
end

local MAX_COVER_RETRIES = 3
local COVER_RETRY_COOLDOWN = 60
local MAX_ATTEMPTED_CACHE = 2000

local _komga_covers_queue = {}
local _komga_covers_attempts = {}
local _komga_covers_attempts_count = 0
local _komga_queue_running = false
local _repaint_scheduled = false
local _repaint_timer = nil
local _cover_meta_dirty = false

local function flushCoverMetadata(plugin)
    if not _cover_meta_dirty then return end
    _cover_meta_dirty = false
    plugin = plugin or getKomgaPlugin()
    if plugin and plugin.saveSettings then
        safeCall("flushCoverMetadata.saveSettings", plugin.saveSettings, plugin)
    end
end

local function isModalOrMenuOpen(UIManager)
    if not UIManager then return false end
    if UIManager._widget_list and type(UIManager._widget_list) == "table" then
        local count = #UIManager._widget_list
        if count > 1 then
            for i = count, 2, -1 do
                local w = UIManager._widget_list[i]
                if w then
                    local name = (w.name or ""):lower()
                    local cls = (w.class or ""):lower()
                    if w.is_menu or w.modal or w.dim_background
                            or name:find("menu") or name:find("dialog")
                            or cls:find("menu") or cls:find("dialog") then
                        return true
                    end
                end
            end
        end
    end
    if UIManager.getTopWidget then
        local top = UIManager:getTopWidget()
        if top then
            local name = (top.name or ""):lower()
            local cls = (top.class or ""):lower()
            if top.is_menu or top.modal or top.dim_background
                    or name:find("menu") or name:find("dialog")
                    or cls:find("menu") or cls:find("dialog") then
                return true
            end
        end
    end
    return false
end

local function scheduleRepaint(immediate)
    if _repaint_scheduled and not immediate then return end
    local ok_ui, UIManager = pcall(require, "ui/uimanager")
    if _repaint_scheduled and immediate and _repaint_timer and ok_ui and UIManager and UIManager.unschedule then
        pcall(UIManager.unschedule, UIManager, _repaint_timer)
        _repaint_timer = nil
        _repaint_scheduled = false
    end
    local delay = immediate and 0.1 or 1.5
    _repaint_scheduled = true
    if ok_ui and UIManager and UIManager.scheduleIn then
        local cb
        cb = function()
            _repaint_timer = nil
            -- If a menu or modal dialog is currently open, defer repaint so we do not
            -- rebuild the shelf underneath the active popup and cause flashing
            if isModalOrMenuOpen(UIManager) then
                _repaint_scheduled = false
                scheduleRepaint(false)
                return
            end

            _repaint_scheduled = false
            flushCoverMetadata()
            M.clearCoverPathCache()
            local ok_s, Sources = pcall(require, "lib/bookshelf_sources")
            if ok_s and Sources and Sources.changed then
                safeCall("scheduleRepaint.Sources.changed", Sources.changed, "hybrid")
            end
        end
        _repaint_timer = UIManager:scheduleIn(delay, cb) or cb
    else
        _repaint_scheduled = false
        flushCoverMetadata()
        M.clearCoverPathCache()
        local ok_s, Sources = pcall(require, "lib/bookshelf_sources")
        if ok_s and Sources and Sources.changed then
            safeCall("scheduleRepaint.Sources.changed", Sources.changed, "hybrid")
        end
    end
end

local _covers_downloaded_in_batch = 0
local processNextCover

local function abortCoverQueue(_reason)
    -- Clear queued/in-flight markers so aborted covers remain retryable after reconnect
    for _, item in ipairs(_komga_covers_queue) do
        if item and item.key and _komga_covers_attempts[item.key] and _komga_covers_attempts[item.key].state == "queued" then
            _komga_covers_attempts[item.key] = nil
            _komga_covers_attempts_count = math.max(0, _komga_covers_attempts_count - 1)
        end
    end
    _komga_covers_queue = {}
    _komga_queue_running = false
    flushCoverMetadata()
    if _covers_downloaded_in_batch > 0 then
        _covers_downloaded_in_batch = 0
        scheduleRepaint(true)
    end
end

local function finishCoverStep(downloaded, job_key)
    if job_key then
        local rec = _komga_covers_attempts[job_key]
        if rec then
            if downloaded then
                rec.state = "ok"
            else
                rec.state = "failed"
                rec.count = (rec.count or 0) + 1
                rec.last_ts = os.time()
            end
        end
    end
    if downloaded then
        _covers_downloaded_in_batch = _covers_downloaded_in_batch + 1
    end
    if #_komga_covers_queue > 0 then
        if downloaded and (_covers_downloaded_in_batch % 20) == 0 then
            flushCoverMetadata()
            scheduleRepaint(false)
        end
        local ok_ui, UIManager = pcall(require, "ui/uimanager")
        if ok_ui and UIManager and UIManager.scheduleIn then
            UIManager:scheduleIn(0.15, processNextCover)
        else
            abortCoverQueue("no_uimanager")
        end
    else
        _komga_queue_running = false
        flushCoverMetadata()
        if _covers_downloaded_in_batch > 0 then
            _covers_downloaded_in_batch = 0
            scheduleRepaint(true)
        end
    end
end

local function canAttemptCover(key)
    local rec = _komga_covers_attempts[key]
    if not rec then return true end
    if rec.state == "ok" or rec.state == "queued" then return false end
    if rec.state == "failed" then
        if (rec.count or 0) >= MAX_COVER_RETRIES then return false end
        return (os.time() - (rec.last_ts or 0)) >= COVER_RETRY_COOLDOWN
    end
    return true
end

local function markCoverQueued(key)
    if not _komga_covers_attempts[key] then
        if _komga_covers_attempts_count >= MAX_ATTEMPTED_CACHE then
            _komga_covers_attempts = {}
            _komga_covers_attempts_count = 0
        end
        _komga_covers_attempts[key] = { count = 0, last_ts = os.time(), state = "queued" }
        _komga_covers_attempts_count = _komga_covers_attempts_count + 1
    else
        _komga_covers_attempts[key].state = "queued"
        _komga_covers_attempts[key].last_ts = os.time()
    end
end

processNextCover = function()
    if #_komga_covers_queue == 0 then
        _komga_queue_running = false
        flushCoverMetadata()
        if _covers_downloaded_in_batch > 0 then
            _covers_downloaded_in_batch = 0
            scheduleRepaint(true)
        end
        return
    end

    local ok_net, NetworkMgr = pcall(require, "ui/network/manager")
    if ok_net and NetworkMgr and NetworkMgr.isConnected and not NetworkMgr:isConnected() then
        abortCoverQueue("offline")
        return
    end

    local ok_h, Health = pcall(require, "lib/bridge_health")
    if ok_h and Health and Health.isServerReachable and not Health.isServerReachable() then
        abortCoverQueue("unreachable")
        return
    end

    local plugin = getKomgaPlugin()
    if not (plugin and plugin.cache and plugin.cache.cacheThumbnail) then
        abortCoverQueue("no_plugin")
        return
    end

    local m = table.remove(_komga_covers_queue, 1)
    if not m then
        finishCoverStep(false, nil)
        return
    end

    local valid_type = validateTypeLabel(m.type_label)
    local valid_id = validateKomgaId(m.id)
    if not (valid_type and valid_id) then
        logger.warn(string.format("[Hybrid] processNextCover rejected invalid cover job: type=%s id=%s", sanitizeLog(m.type_label), sanitizeLog(m.id)))
        finishCoverStep(false, m.key)
        return
    end

    local ok_step, step_err = pcall(function()
        local ok_ah, AsyncHttp = pcall(require, "lib/bridge_async_http")
        local api = plugin.api
        local base_url = api and api.base_url
        if ok_ah and AsyncHttp and AsyncHttp.isAvailable and AsyncHttp.isAvailable()
                and AsyncHttp.downloadAsync and isAllowedHttpUrl(base_url) then
            local ok_ds, DataStorage = pcall(require, "datastorage")
            if ok_ds and DataStorage then
                safeCall("processNextCover.ensureStructure", plugin.cache.ensureStructure, plugin.cache)
                local covers_dir = DataStorage:getDataDir() .. "/komga_covers"
                local cache_key = valid_type .. "_" .. valid_id
                local dest_path = covers_dir .. "/" .. cache_key .. ".jpg"
                if not isPathWithinRoot(dest_path, covers_dir) then
                    finishCoverStep(false, m.key)
                    return
                end
                local endpoint_type = (valid_type == "series") and "series" or "books"
                local url = tostring(base_url):gsub("/+$", "") .. "/api/v1/" .. endpoint_type .. "/" .. valid_id .. "/thumbnail"
                local headers = {}
                if api.get_headers then
                    local ok_hdr, h = safeCall("processNextCover.get_headers", api.get_headers, api)
                    if ok_hdr and type(h) == "table" then
                        for k, v in pairs(h) do headers[k] = v end
                    end
                end
                local ok_ba, BridgeAuth = pcall(require, "lib/bridge_auth")
                if ok_ba and BridgeAuth and BridgeAuth.getAuthHeaders then
                    local ok_ex, extra = safeCall("processNextCover.getAuthHeaders", BridgeAuth.getAuthHeaders, url)
                    if ok_ex and type(extra) == "table" then
                        for k, v in pairs(extra) do
                            if not headers[k] then headers[k] = v end
                        end
                    end
                end
                -- Thumbnail endpoints serve images; the API's JSON Accept header yields HTTP 406.
                headers["accept"] = nil
                headers["Accept"] = "image/*"
                local launched = AsyncHttp.downloadAsync({
                    url = url,
                    headers = headers,
                    tmp_path = dest_path .. ".tmp",
                    dest_path = dest_path,
                    connect_timeout = 2,
                    max_time = 8,
                }, function(ok, code, _, err_msg)
                    if ok then
                        local meta_cache = plugin.settings and plugin.settings.library_metadata_cache
                        if meta_cache and meta_cache.covers then
                            meta_cache.covers[cache_key] = m.lastModified
                            _cover_meta_dirty = true
                        end
                    else
                        logger.warn(string.format("[Hybrid] cover async download failed for %s: code=%s err=%s",
                            sanitizeLog(cache_key), sanitizeLog(code), sanitizeLog(err_msg)))
                    end
                    finishCoverStep(ok == true, m.key)
                end)
                if launched then
                    return
                end
            end
        end

        local ok, path = safeCall("processNextCover.cacheThumbnail", plugin.cache.cacheThumbnail, plugin.cache,
            valid_type, valid_id, m.lastModified, true)
        finishCoverStep(ok and path ~= nil, m.key)
    end)

    if not ok_step then
        logger.err("[Hybrid] processNextCover unexpected error: " .. sanitizeLog(step_err))
        finishCoverStep(false, m.key)
    end
end

function M.scheduleKomgaCovers(records)
    if not records or #records == 0 then return end
    local ok_net, NetworkMgr = pcall(require, "ui/network/manager")
    if ok_net and NetworkMgr and NetworkMgr.isConnected and not NetworkMgr:isConnected() then
        return
    end

    local ok_h, Health = pcall(require, "lib/bridge_health")
    if ok_h and Health and Health.isServerReachable and not Health.isServerReachable() then
        return
    end

    local komga = getKomgaPlugin()
    if not (komga and komga.cache and komga.cache.cacheThumbnail) then return end

    local added = 0
    for _, rec in ipairs(records) do
        if rec and (rec.is_komga or rec.komga_book_id or rec.komga_series_id or rec.komga_dto or rec.active_book or rec.is_folder or rec.kind == "folder") then
            local is_series = rec.is_folder or rec.is_opds_nav or (rec.komga_series_id ~= nil and rec.komga_book_id == nil)
            local type_label = is_series and "series" or "book"
            local id = is_series and (rec.komga_series_id or (rec.komga_dto and rec.komga_dto.id))
                or (rec.komga_book_id or (rec.komga_dto and rec.komga_dto.id))
            if not id and is_series and M.lookupSeriesIdByTitle then
                id = M.lookupSeriesIdByTitle(rec.title or rec.label or rec.series_name)
            end
            local valid_id = validateKomgaId(id)
            if valid_id and not getKomgaCoverPath(type_label, valid_id) then
                local key = type_label .. "_" .. valid_id
                if canAttemptCover(key) then
                    markCoverQueued(key)
                    _komga_covers_queue[#_komga_covers_queue + 1] = {
                        key = key,
                        type_label = type_label,
                        id = valid_id,
                        lastModified = rec.komga_dto and rec.komga_dto.lastModified,
                    }
                    added = added + 1
                    if added >= 6 then break end
                end
            end
            -- Also queue active_book cover if present on series record
            if rec.active_book and rec.active_book.id and added < 6 then
                local b_id = validateKomgaId(rec.active_book.id)
                if b_id and not getKomgaCoverPath("book", b_id) then
                    local key = "book_" .. b_id
                    if canAttemptCover(key) then
                        markCoverQueued(key)
                        _komga_covers_queue[#_komga_covers_queue + 1] = {
                            key = key,
                            type_label = "book",
                            id = b_id,
                            lastModified = rec.active_book.lastModified,
                        }
                        added = added + 1
                        if added >= 6 then break end
                    end
                end
            end
        end
    end

    if not _komga_queue_running and #_komga_covers_queue > 0 then
        _komga_queue_running = true
        local ok_ui, UIManager = pcall(require, "ui/uimanager")
        if ok_ui and UIManager and UIManager.scheduleIn then
            UIManager:scheduleIn(0.1, processNextCover)
        else
            _komga_queue_running = false
        end
    end
end

function M.getActiveQueue(source)
    local cached_entry = nil
    local fetched_at = 0
    pcall(function()
        local DataStorage = require("datastorage")
        local LuaSettings = require("luasettings")
        local s = LuaSettings:open(DataStorage:getSettingsDir() .. "/kokomga_bookshelf.lua")
        if s then
            local lists = s:readSetting("lists") or {}
            local e = lists["active_queue"]
            if e and e.items then
                cached_entry = e.items
                fetched_at = tonumber(e.fetched_at) or 0
            end
        end
    end)

    local ttl = 180 -- 3 minutes TTL
    local is_cache_stale = (not cached_entry) or ((os.time() - fetched_at) > ttl)
    local ok_bh, BridgeHealth = pcall(require, "lib/bridge_health")
    local can_fetch = true
    if ok_bh and BridgeHealth then
        if BridgeHealth.isCircuitBreakerActive and BridgeHealth.isCircuitBreakerActive() then
            can_fetch = false
        elseif BridgeHealth.isServerReachable and not BridgeHealth.isServerReachable() then
            can_fetch = false
        end
    end

    if is_cache_stale and can_fetch then
        local komga = getKomgaPlugin()
        local api = (komga and komga.api) or getKomgaApi()
        if api then
            local in_progress = {}
            local ondeck = {}

            -- 1. In-progress books
            local ok_ip, resp_ip = safeCall("getActiveQueue.get_books", api.get_books, api,
                { read_status = "IN_PROGRESS", sort = "readProgress.readDate,desc" }, 0, 100)
            local ip_valid = ok_ip and type(resp_ip) == "table" and not resp_ip.error
            local content_ip = ip_valid and (resp_ip.content or (resp_ip[1] and resp_ip))
            if content_ip then
                for _, b in ipairs(content_ip) do
                    local tb = asTable(b) and trimBook(b)
                    if tb and tb.id and tb.seriesId then
                        in_progress[#in_progress + 1] = tb
                    end
                end
            end

            -- 2. On Deck books
            local ok_od, resp_od = safeCall("getActiveQueue.get_books_ondeck", api.get_books_ondeck, api, 0, 100)
            local od_valid = ok_od and type(resp_od) == "table" and not resp_od.error
            local content_od = od_valid and (resp_od.content or (resp_od[1] and resp_od))
            if content_od then
                for _, b in ipairs(content_od) do
                    local tb = asTable(b) and trimBook(b)
                    if tb and tb.id and tb.seriesId then
                        ondeck[#ondeck + 1] = tb
                    end
                end
            end

            if ip_valid and od_valid then
                -- Group by seriesId: in-progress takes precedence over on-deck
                local series_map = {}
                local series_order = {}
                local series_source = {}

                for _, b in ipairs(in_progress) do
                    local sid = tostring(b.seriesId)
                    if not series_map[sid] then
                        series_map[sid] = b
                        series_order[#series_order + 1] = sid
                        series_source[sid] = "in_progress"
                    else
                        -- Multiple in-progress books for the same series: pick highest sequence number
                        local cur_num = Dedup.extractChapterNumber(series_map[sid]) or -1
                        local new_num = Dedup.extractChapterNumber(b) or -1
                        if new_num > cur_num then
                            series_map[sid] = b
                        end
                    end
                end

                for _, b in ipairs(ondeck) do
                    local sid = tostring(b.seriesId)
                    if not series_map[sid] then
                        series_map[sid] = b
                        series_order[#series_order + 1] = sid
                        series_source[sid] = "ondeck"
                    elseif series_source[sid] == "ondeck" then
                        -- Multiple on-deck books for the same series: pick highest sequence number
                        local cur_num = Dedup.extractChapterNumber(series_map[sid]) or -1
                        local new_num = Dedup.extractChapterNumber(b) or -1
                        if new_num > cur_num then
                            series_map[sid] = b
                        end
                    end
                end

                local items = {
                    by_series = series_map,
                    series_order = series_order,
                }

                cached_entry = items
                safeCall("getActiveQueue.persist", function()
                    local DataStorage = require("datastorage")
                    local LuaSettings = require("luasettings")
                    local s = LuaSettings:open(DataStorage:getSettingsDir() .. "/kokomga_bookshelf.lua")
                    if s then
                        local lists = s:readSetting("lists") or {}
                        lists["active_queue"] = { fetched_at = os.time(), items = items }
                        s:saveSetting("lists", lists)
                        s:flush()
                    end
                end)
            else
                logger.warn("[Hybrid] getActiveQueue skipping cache overwrite due to API error; preserving previous cache")
            end
        end
    end

    return cached_entry or { by_series = {}, series_order = {} }
end

function M.getActiveBookForSeries(source, series_id, series_label)
    local queue = M.getActiveQueue(source)
    if not queue or not queue.by_series then return nil end

    if series_id and queue.by_series[tostring(series_id)] then
        return queue.by_series[tostring(series_id)]
    end

    if series_label and series_label ~= "" then
        local label_key = Dedup.nameKey(series_label)
        if label_key then
            for sid, book_dto in pairs(queue.by_series) do
                local title_key = Dedup.nameKey(book_dto.seriesTitle or "")
                if title_key and Dedup.nameKeysMatch(label_key, title_key) then
                    return book_dto
                end
            end
        end
    end

    return nil
end

function M.getActiveSeriesRecords(source, is_spine)
    local queue = M.getActiveQueue(source)
    if not queue or not queue.series_order or #queue.series_order == 0 then
        return {}, 0
    end

    local downloaded = Dedup.getDownloadedMap()
    local records = {}
    for _, series_id in ipairs(queue.series_order) do
        local book_dto = queue.by_series[series_id]
        if book_dto then
            local series_title = book_dto.seriesTitle or book_dto.name or series_id
            local cp = getKomgaCoverPath("series", series_id, series_title, book_dto.id)
            if not cp and book_dto.id then
                cp = getKomgaCoverPath("book", book_dto.id, book_dto.name, series_id)
            end

            local kid_str = tostring(book_dto.id)
            local downloaded_path = (kid_str and (downloaded["komga://book/" .. kid_str] or downloaded[kid_str]))

            if is_spine then
                local rec = bookDtoToRecord(book_dto, series_title, nil, downloaded)
                rec.shelf_section = series_title
                rec.shelf_section_path = "komga://series/" .. tostring(series_id)
                rec.series_name = series_title
                rec.is_folder = false
                rec.is_series = false
                rec.kind = "book"
                rec.source_kind = "hybrid"
                rec.is_remote = not rec.downloaded
                rec.active_book = book_dto
                rec.page_count = (book_dto.media and book_dto.media.pagesCount and book_dto.media.pagesCount > 0 and book_dto.media.pagesCount) or 200
                records[#records + 1] = rec
            else
                local has_cover = (cp ~= nil) or (downloaded_path ~= nil)
                local filepath = downloaded_path or ("komga://series/" .. tostring(series_id))

                local rec = {
                    id = series_id,
                    komga_series_id = series_id,
                    komga_id = series_id,
                    title = series_title,
                    label = series_title,
                    series_name = series_title,
                    display_title = series_title,
                    kind = "folder",
                    is_folder = true,
                    is_opds_nav = false,
                    source_kind = "hybrid",
                    source_nav = true,
                    path = "komga://series/" .. tostring(series_id),
                    filepath = filepath,
                    cover_image_path = cp,
                    has_cover = has_cover,
                    page_count = (book_dto and book_dto.media and book_dto.media.pagesCount and book_dto.media.pagesCount > 0 and book_dto.media.pagesCount) or 200,
                    is_series = true,
                    first_book = {
                        filepath = filepath,
                        cover_image_path = cp,
                        title = series_title,
                        has_cover = has_cover,
                        page_count = (book_dto and book_dto.media and book_dto.media.pagesCount and book_dto.media.pagesCount > 0 and book_dto.media.pagesCount) or 200,
                    },
                    active_book = book_dto,
                }
                records[#records + 1] = rec
            end
        end
    end

    M.scheduleKomgaCovers(records)
    return records, #records
end

local function getLibraryKey(source)
    local lib_ids = source and source.library_id
    if not lib_ids then return "all" end
    if type(lib_ids) == "string" then return lib_ids ~= "" and lib_ids or "all" end
    if type(lib_ids) == "table" then
        local t = {}
        for _, id in ipairs(lib_ids) do
            if type(id) == "string" and id ~= "" then t[#t + 1] = id end
        end
        table.sort(t)
        if #t > 0 then return table.concat(t, ",") end
    end
    return "all"
end

function M.getAllSeries(source, force_refresh)
    ensureKomgaApiPatched()
    local lib_key = getLibraryKey(source)
    local now = os.time()
    local ttl = 180 -- 3 minutes TTL

    local ok_ds, DataStorage = pcall(require, "datastorage")
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    local settings_path = ok_ds and DataStorage and (DataStorage:getSettingsDir() .. "/kokomga_bookshelf.lua")
    local disk_mtime = (settings_path and ok_lfs and lfs and lfs.attributes) and lfs.attributes(settings_path, "modification") or 0

    local mem = _mem_all_series[lib_key]
    if not force_refresh and mem and mem.mtime == disk_mtime and (now - (mem.fetched_at or 0) < ttl) and mem.items and #mem.items > 0 then
        return mem.items
    end

    local cached_entry = nil
    local fetched_at = 0

    if not force_refresh then
        pcall(function()
            local LuaSettings = require("luasettings")
            local s = LuaSettings:open(settings_path)
            if s then
                local all_s = s:readSetting("all_series") or {}
                local entry = all_s[lib_key]
                if entry and entry.items then
                    cached_entry = entry.items
                    fetched_at = tonumber(entry.fetched_at) or 0
                    _mem_all_series[lib_key] = { fetched_at = fetched_at, items = cached_entry, mtime = disk_mtime }
                end
            end
        end)
    end

    local is_cache_stale = (not cached_entry or #cached_entry == 0) or ((now - fetched_at) > ttl)
    if force_refresh then is_cache_stale = true end

    local ok_bh, BridgeHealth = pcall(require, "lib/bridge_health")
    local can_fetch = true
    if ok_bh and BridgeHealth then
        if BridgeHealth.isCircuitBreakerActive and BridgeHealth.isCircuitBreakerActive() then
            can_fetch = false
        elseif BridgeHealth.isServerReachable and not BridgeHealth.isServerReachable() then
            can_fetch = false
        end
    end

    if is_cache_stale and can_fetch then
        local komga = getKomgaPlugin()
        local api = (komga and komga.api) or getKomgaApi()
        if api and type(api.query_series) == "function" then
            local lib_param = (source and source.library_id)
            if type(lib_param) == "string" and lib_param ~= "" then
                lib_param = { lib_param }
            elseif type(lib_param) ~= "table" then
                lib_param = nil
            end

            local all_items = {}
            local page = 0
            local page_size = 500
            local has_more = true
            local fetch_complete = true

            while has_more and page < 20 do
                local ok_res, resp = safeCall("getAllSeries.query_series", api.query_series, api, {
                    library_id = lib_param,
                    sort = "metadata.titleSort,asc",
                    page = page,
                    size = page_size,
                })
                if not ok_res or type(resp) ~= "table" or resp.error then
                    fetch_complete = false
                    logger.warn(string.format("[Hybrid] getAllSeries aborted at page %d; preserving previous cache", page))
                    break
                end

                local content = resp.content or (resp[1] and resp)
                if content and type(content) == "table" then
                    for _, s in ipairs(content) do
                        local ts = asTable(s) and trimSeries(s)
                        if ts and ts.id then
                            all_items[#all_items + 1] = ts
                        end
                    end
                end

                if resp.last == true then
                    has_more = false
                elseif not content or #content < page_size then
                    has_more = false
                else
                    page = page + 1
                end
            end

            if fetch_complete and not has_more and (#all_items > 0 or page > 0) then
                cached_entry = all_items
                _mem_all_series[lib_key] = { fetched_at = os.time(), items = all_items }
                safeCall("getAllSeries.persist", function()
                    local DataStorage = require("datastorage")
                    local LuaSettings = require("luasettings")
                    local s = LuaSettings:open(DataStorage:getSettingsDir() .. "/kokomga_bookshelf.lua")
                    if s then
                        local all_s = s:readSetting("all_series") or {}
                        all_s[lib_key] = { fetched_at = os.time(), items = all_items, total = #all_items }
                        s:saveSetting("all_series", all_s)

                        -- Clean up any cached series in "series" section that were deleted from server
                        local series_cache = s:readSetting("series")
                        if series_cache and type(series_cache) == "table" then
                            local live_ids = {}
                            for _, item in ipairs(all_items) do
                                live_ids[tostring(item.id)] = true
                            end
                            local modified_series = false
                            for sid in pairs(series_cache) do
                                if not live_ids[tostring(sid)] and lib_key == "all" then
                                    series_cache[sid] = nil
                                    modified_series = true
                                end
                            end
                            if modified_series then
                                s:saveSetting("series", series_cache)
                            end
                        end

                        s:flush()
                        if _mem_all_series[lib_key] then
                            _mem_all_series[lib_key].mtime = (ok_lfs and lfs and lfs.attributes and settings_path) and lfs.attributes(settings_path, "modification") or os.time()
                        end
                    end
                end)
            end
        end
    end

    return cached_entry or {}
end

function M.getAllSeriesRecords(source, is_spine, force_refresh)
    local series_list = M.getAllSeries(source, force_refresh)
    if not series_list or #series_list == 0 then
        -- Fallback: check if stock kokomga has anything in pages if all_series was empty (e.g. offline first run)
        local ok_s, Sources = pcall(require, "lib/bookshelf_sources")
        local komga_spec = ok_s and Sources and Sources.get and Sources.get("komga")
        if komga_spec and komga_spec.fetch then
            local komga_source = {
                kind = "komga",
                list = source.komga_list or "all_series",
                library_id = source.library_id,
                library_names = source.library_names,
                read_status = source.read_status,
                status = source.status,
                sort = source.sort,
            }
            local recs, total = komga_spec.fetch(komga_source, nil, 0, 100000)
            if recs and #recs > 0 then
                return recs, total or #recs
            end
        end
        return {}, 0
    end

    local records = {}
    for _, item in ipairs(series_list) do
        local title = item.title or "?"
        local st = seriesStatus(item)
        local total = item.booksCount
        local has_total = type(total) == "number" and total > 0
        local finished = item.booksReadCount
        if type(finished) ~= "number" and has_total and type(item.booksUnreadCount) == "number" then
            finished = total - item.booksUnreadCount
        end

        local cp = getKomgaCoverPath("series", item.id, title)
        local rec = {
            id = item.id,
            komga_series_id = item.id,
            komga_id = item.id,
            title = title,
            label = title,
            series_name = title,
            display_title = title,
            kind = "folder",
            is_folder = true,
            is_opds_nav = false,
            source_kind = "hybrid",
            source_nav = true,
            path = "komga://series/" .. tostring(item.id),
            filepath = "komga://series/" .. tostring(item.id),
            book_count = has_total and total or nil,
            finished_count = has_total and finished or nil,
            finished_total = has_total and total or nil,
            status = st,
            read_status = st,
            summary = item.summary,
            komga_series_summary = item.summary,
            cover_image_path = cp,
            has_cover = (cp ~= nil),
            is_remote = true,
            is_series = true,
            first_book = {
                filepath = "komga://series/" .. tostring(item.id),
                cover_image_path = cp,
                title = title,
                has_cover = (cp ~= nil),
                page_count = 200,
            },
        }
        records[#records + 1] = rec
    end

    M.scheduleKomgaCovers(records)
    return records, #records
end

local function isHttp404(ok_res, resp, err)
    if ok_res and type(resp) == "table" then
        if resp.status == 404 or resp.code == 404 then return true end
        if type(resp.error) == "string" and resp.error:lower() == "not found" then return true end
    end
    if not resp and type(err) == "string" then
        local low = err:lower()
        if low:find("404") or low:find("not found") then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Series cache memo + cache-first async refresh (ANR fix for large series)
-- ---------------------------------------------------------------------------
local SERIES_MEM_TTL = 30
local _series_mem = { mtime = nil, series = nil, ts = 0 }

function M.invalidateSeriesMemo()
    _series_mem = { mtime = nil, series = nil, ts = 0 }
end

-- Parsed `series` table of kokomga_bookshelf.lua, memoized by file mtime (+30s TTL)
-- so a drill does not re-open/parse the whole settings file every time.
local function readSeriesCacheTable()
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if not (ok_ds and DataStorage) then return {} end
    local path = DataStorage:getSettingsDir() .. "/kokomga_bookshelf.lua"
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    local mt = (ok_lfs and lfs and lfs.attributes) and lfs.attributes(path, "modification") or nil
    local now = os.time()
    if mt and _series_mem.series and _series_mem.mtime == mt and (now - _series_mem.ts) < SERIES_MEM_TTL then
        return _series_mem.series
    end
    local series = {}
    safeCall("fetchAndMapSeriesBooks.readCache", function()
        local LuaSettings = require("luasettings")
        local s = LuaSettings:open(path)
        local entries = s and s:readSetting("series")
        if type(entries) == "table" then series = entries end
    end)
    if mt then _series_mem = { mtime = mt, series = series, ts = now } end
    return series
end

function M.hasCachedSeries(series_id)
    local e = readSeriesCacheTable()[tostring(series_id)]
    return type(e) == "table" and type(e.items) == "table" and #e.items > 0
end

local function seriesItemsSignature(items)
    local parts = {}
    for i, b in ipairs(items or {}) do
        local rp = type(b) == "table" and type(b.readProgress) == "table" and b.readProgress or {}
        parts[i] = tostring(b.id) .. ":" .. tostring(rp.page or 0) .. ":" .. tostring(rp.completed == true)
    end
    return table.concat(parts, "|")
end

local SERIES_REFRESH_BACKOFF = 60
local _series_refresh_inflight = {}
local _series_refresh_failed = {}

local function persistSeriesItems(series_id, items)
    safeCall("fetchAndMapSeriesBooks.persist", function()
        local DataStorage = require("datastorage")
        local LuaSettings = require("luasettings")
        local s = LuaSettings:open(DataStorage:getSettingsDir() .. "/kokomga_bookshelf.lua")
        if s then
            local entries = s:readSetting("series") or {}
            entries[series_id] = { fetched_at = os.time(), items = items }
            s:saveSetting("series", entries)
            s:flush()
        end
    end)
    M.invalidateSeriesMemo()
end

-- Returns true when a refresh is running/backed-off (caller must serve cache, not block);
-- false when async is unavailable (caller falls back to the synchronous fetch).
local function scheduleSeriesRefresh(series_id, series_title, old_items)
    if _series_refresh_inflight[series_id] then return true end
    local failed_at = _series_refresh_failed[series_id]
    if failed_at and (os.time() - failed_at) < SERIES_REFRESH_BACKOFF then return true end

    local ok_ah, AsyncHttp = pcall(require, "lib/bridge_async_http")
    if not (ok_ah and AsyncHttp and AsyncHttp.isAvailable and AsyncHttp.isAvailable() and AsyncHttp.requestAsync) then
        return false
    end
    local ok_js, json = pcall(require, "json")
    if not (ok_js and json and json.decode) then return false end

    local komga = getKomgaPlugin()
    local api = (komga and komga.api) or getKomgaApi()
    local base_url = api and api.base_url
    if not (api and isAllowedHttpUrl(base_url)) then return false end

    local headers = {}
    if api.get_headers then
        local ok_hdr, h = safeCall("scheduleSeriesRefresh.get_headers", api.get_headers, api)
        if ok_hdr and type(h) == "table" then
            for k, v in pairs(h) do headers[k] = v end
        end
    end
    local ok_ba, BridgeAuth = pcall(require, "lib/bridge_auth")
    local url = tostring(base_url):gsub("/+$", "") .. "/api/v1/series/" .. series_id
        .. "/books?sort=metadata.numberSort%2Casc&page=0&size=1000"
    if ok_ba and BridgeAuth and BridgeAuth.getAuthHeaders then
        local ok_ex, extra = safeCall("scheduleSeriesRefresh.getAuthHeaders", BridgeAuth.getAuthHeaders, url)
        if ok_ex and type(extra) == "table" then
            for k, v in pairs(extra) do
                if not headers[k] then headers[k] = v end
            end
        end
    end

    _series_refresh_inflight[series_id] = true
    local started = AsyncHttp.requestAsync({
        url = url,
        headers = headers,
        connect_timeout = 3,
        max_time = 25,
    }, function(ok, code, body, err_msg)
        _series_refresh_inflight[series_id] = nil
        if ok and type(body) == "string" and body ~= "" then
            local ok_d, resp = pcall(json.decode, body)
            local content = ok_d and type(resp) == "table" and (resp.content or (resp[1] and resp)) or nil
            if type(content) == "table" and #content > 0 then
                local new_items = trimBooks(content, 1000)
                local changed = seriesItemsSignature(new_items) ~= seriesItemsSignature(old_items)
                persistSeriesItems(series_id, new_items)
                if changed then
                    local ok_sp, spec = pcall(require, "lib/hybrid_spec")
                    if ok_sp and spec and spec.clearCachesForSeries then
                        pcall(spec.clearCachesForSeries, series_id)
                    end
                    scheduleRepaint(true)
                end
                return
            end
            _series_refresh_failed[series_id] = os.time()
            return
        end
        if tonumber(code) == 404 then
            M.purgeDeletedSeries(series_id, series_title)
            M.invalidateSeriesMemo()
            scheduleRepaint(true)
            return
        end
        _series_refresh_failed[series_id] = os.time()
        logger.warn(string.format("[Hybrid] async series refresh failed for %s: code=%s err=%s",
            sanitizeLog(series_id), sanitizeLog(code), sanitizeLog(err_msg)))
    end)
    if not started then
        _series_refresh_inflight[series_id] = nil
        return false
    end
    return true
end

local function fetchAndMapSeriesBooks(opts)
    local series_id = validateKomgaId(opts and opts.series_id)
    if not series_id then return { books = {}, purged = false } end
    local series_title = opts.series_title
    local series_summary = opts.series_summary
    local allow_network = opts.allow_network
    local check_spine_light = opts.check_spine_light == true

    ensureKomgaApiPatched()

    local cached_items = nil
    local fetched_at = 0
    do
        local e = readSeriesCacheTable()[series_id]
        if type(e) == "table" and type(e.items) == "table" and #e.items > 0 then
            cached_items = e.items
            fetched_at = tonumber(e.fetched_at) or 0
        end
    end

    local ttl = 180 -- 3 minutes TTL
    local is_cache_stale = (not cached_items or #cached_items == 0) or ((os.time() - fetched_at) > ttl)
    local ok_bh, BridgeHealth = pcall(require, "lib/bridge_health")
    local can_fetch = true
    if ok_bh and BridgeHealth then
        if BridgeHealth.isCircuitBreakerActive and BridgeHealth.isCircuitBreakerActive() then
            can_fetch = false
        elseif BridgeHealth.isServerReachable and not BridgeHealth.isServerReachable() then
            can_fetch = false
        end
    end

    if allow_network == false then
        can_fetch = false
    end

    if check_spine_light then
        local ok_r, Repo = pcall(require, "lib/bookshelf_book_repository")
        if (Repo and Repo.spine_light == true) and (not cached_items or #cached_items == 0) and allow_network ~= true then
            can_fetch = false
        end
    end

    local refreshed_async = false
    if is_cache_stale and can_fetch and cached_items and #cached_items > 0 then
        -- Cache-first: render what we have now; refresh in background (no UI-thread network).
        refreshed_async = scheduleSeriesRefresh(series_id, series_title, cached_items) == true
    end

    if is_cache_stale and can_fetch and not refreshed_async then
        local komga = getKomgaPlugin()
        local api = (komga and komga.api) or getKomgaApi()
        if api and type(api.get_books_for_series) == "function" then
            local ok_res, resp, api_err = safeCall("fetchAndMapSeriesBooks.get_books_for_series",
                api.get_books_for_series, api, series_id, { sort = "metadata.numberSort,asc" }, 0, 1000)
            local content = ok_res and type(resp) == "table" and (resp.content or (resp[1] and resp)) or nil
            if content and #content > 0 then
                if #content >= 1000 then
                    logger.warn(string.format("[Hybrid] series %s hit 1000-book pagination cap", sanitizeLog(series_id)))
                end
                cached_items = trimBooks(content, 1000)
                persistSeriesItems(series_id, cached_items)
            elseif isHttp404(ok_res, resp, api_err) then
                M.purgeDeletedSeries(series_id, series_title)
                return { books = {}, purged = true }
            end
        end
    end

    if not cached_items or #cached_items == 0 then
        return { books = {}, purged = false }
    end

    local downloaded = Dedup.getDownloadedMap()
    local books = {}
    for _, dto in ipairs(cached_items) do
        local rec = bookDtoToRecord(dto, series_title, series_summary, downloaded)
        if rec then
            rec.is_remote = not rec.downloaded
            rec.source_kind = "hybrid"
            local cp = rec.cover_image_path or getKomgaCoverPath("book", rec.komga_book_id or rec.komga_id, rec.title, series_id)
            if not cp and series_id then
                cp = getKomgaCoverPath("series", series_id, series_title)
            end
            if cp then
                rec.cover_image_path = cp
                rec.has_cover = true
            elseif rec.downloaded then
                rec.has_cover = true
            end
            rec.label = rec.label or rec.title
            rec.series_name = rec.series_name or series_title
            rec.display_title = rec.display_title or rec.title
            rec.page_count = (dto.media and dto.media.pagesCount and dto.media.pagesCount > 0 and dto.media.pagesCount) or 200
            books[#books + 1] = rec
        end
    end
    M.scheduleKomgaCovers(books)
    return { books = books, purged = false }
end

function M.getKomgaSeriesBooks(series_id, series_title, series_summary, allow_network)
    local res = fetchAndMapSeriesBooks({
        series_id = series_id,
        series_title = series_title,
        series_summary = series_summary,
        allow_network = allow_network,
        check_spine_light = true,
    })
    return res.books
end

function M.expandSeriesToBooks(source, series_entry, sort_priority, local_folder_path)
    local series_title = series_entry.title or series_entry.label or series_entry.series_name or "Unknown Series"
    local series_id = series_entry.komga_series_id or series_entry.id
    if not series_id and type(series_entry.path) == "string" then
        series_id = series_entry.path:match("^komga://series/(.+)$")
    end
    if not series_id and type(series_entry.filepath) == "string" then
        series_id = series_entry.filepath:match("^komga://series/(.+)$")
    end

    -- A. Local member books (if local directory exists)
    local local_books = {}
    local ok_r, Repo = pcall(require, "lib/bookshelf_book_repository")
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    local function is_dir(p)
        if not p or type(p) ~= "string" or not p:find("^/") then return false end
        if ok_lfs and lfs and lfs.attributes then
            return lfs.attributes(p, "mode") == "directory"
        end
        return false
    end

    local safe_series_dir = sanitizePathComponent(series_title, nil)
    local folder_path = nil
    if is_dir(series_entry.path) then
        folder_path = series_entry.path
    elseif is_dir(series_entry.filepath) then
        folder_path = series_entry.filepath
    elseif series_entry.filepath and type(series_entry.filepath) == "string" and series_entry.filepath:find("^/") then
        local parent = series_entry.filepath:match("(.+)/[^/]+$")
        if is_dir(parent) then folder_path = parent end
    elseif safe_series_dir and local_folder_path and type(local_folder_path) == "string" and local_folder_path:find("^/") then
        local candidate = local_folder_path:gsub("/+$", "") .. "/" .. safe_series_dir
        if isPathWithinRoot(candidate, local_folder_path) and is_dir(candidate) then
            folder_path = candidate
        end
    elseif safe_series_dir and source and source.local_folder and type(source.local_folder) == "string" then
        local candidate = source.local_folder:gsub("/+$", "") .. "/" .. safe_series_dir
        if isPathWithinRoot(candidate, source.local_folder) and is_dir(candidate) then
            folder_path = candidate
        end
    end

    if folder_path and ok_r and Repo and Repo.getAll then
        local_books = Repo.getAll(folder_path, 10000, 0, sort_priority, nil) or {}
    end

    -- 1. Check if Next Book mode:
    if source and source.remote_mode == "next_book" then
        local active_dto = series_entry.active_book
        if not active_dto and series_id then
            active_dto = M.getActiveBookForSeries(source, series_id, series_title)
        end
        if not active_dto and series_title then
            active_dto = M.getActiveBookForSeries(source, nil, series_title)
        end

        local remote_books = {}
        if active_dto then
            local downloaded = Dedup.getDownloadedMap()
            local rec = bookDtoToRecord(active_dto, series_title, nil, downloaded)
            rec.is_remote = not rec.downloaded
            rec.source_kind = "hybrid"
            rec.page_count = (active_dto.media and active_dto.media.pagesCount and active_dto.media.pagesCount > 0 and active_dto.media.pagesCount) or 200
            remote_books = { rec }
        end

        local merged_books = {}
        if #local_books > 0 and #remote_books > 0 then
            merged_books = Dedup.mergeRecords(local_books, remote_books, active_dto)
        elseif #local_books > 0 then
            merged_books = local_books
            if active_dto then
                for _, b in ipairs(merged_books) do
                    Dedup.syncLocalChapterStatus(b, active_dto)
                end
            end
        elseif #remote_books > 0 then
            merged_books = remote_books
        else
            return {}
        end

        for i = 1, #merged_books do
            local b = merged_books[i]
            b.shelf_section = series_title
            b.shelf_section_path = folder_path or series_entry.path or series_entry.filepath or ("komga://series/" .. tostring(series_id or ""))
            b.series_name = b.series_name or series_title
            b.filepath = b.filepath or b.path or b.fp or b.shelf_section_path
            b.is_folder = false
            b.is_series = false
            b.kind = "book"
            b.source_kind = "hybrid"
            if b.is_remote == nil then
                b.is_remote = (type(b.filepath) == "string" and b.filepath:find("^%a+://") ~= nil)
            end
            b.page_count = (b.page_count and b.page_count > 0 and b.page_count) or 200
        end

        return merged_books
    end

    -- 2. All Chapters mode:

    -- B. Remote member books
    local remote_books = {}
    if series_id then
        remote_books = M.getKomgaSeriesBooks(series_id, series_title, series_entry.series_summary) or {}
    end

    -- C. Deduplicate
    local merged_books = {}
    if #local_books > 0 and #remote_books > 0 then
        merged_books = Dedup.mergeRecords(local_books, remote_books)
    elseif #local_books > 0 then
        merged_books = local_books
    elseif #remote_books > 0 then
        merged_books = remote_books
    end

    -- Fallback if neither local nor remote books were loaded (only use real active_book DTO; never synthesize .jpg placeholder)
    if #merged_books == 0 then
        if series_entry.active_book then
            local downloaded = Dedup.getDownloadedMap()
            local rec = bookDtoToRecord(series_entry.active_book, series_title, nil, downloaded)
            if rec then merged_books = { rec } end
        else
            return {}
        end
    end

    -- Tag every book with section metadata and guarantee filepath
    for i = 1, #merged_books do
        local b = merged_books[i]
        b.shelf_section = series_title
        b.shelf_section_path = folder_path or series_entry.path or series_entry.filepath or ("komga://series/" .. tostring(series_id or ""))
        b.series_name = b.series_name or series_title
        b.filepath = b.filepath or b.path or b.fp or b.shelf_section_path
        b.is_folder = false
        b.is_series = false
        b.kind = "book"
        b.source_kind = "hybrid"
        if b.is_remote == nil then
            b.is_remote = (type(b.filepath) == "string" and b.filepath:find("^%a+://") ~= nil)
        end
        b.page_count = (b.page_count and b.page_count > 0 and b.page_count) or 200
    end

    return merged_books
end

function M.getKomgaRecords(source, drill, is_spine)
    ensureKomgaApiPatched()

    -- Next Book mode interception
    if source and source.remote_mode == "next_book" then
        if not drill then
            return M.getActiveSeriesRecords(source, false)
        end
        if drill.kind == "komga_series" or drill.kind == "series" or drill.series_id or drill.komga_series_id or (type(drill.path) == "string" and drill.path:find("^komga://series/")) then
            local series_id = drill.series_id or drill.komga_series_id or (type(drill.path) == "string" and drill.path:match("^komga://series/(.+)$"))
            local active_dto = M.getActiveBookForSeries(source, series_id, drill.label)
            if active_dto then
                local downloaded = Dedup.getDownloadedMap()
                local rec = bookDtoToRecord(active_dto, drill.label or active_dto.seriesTitle, drill.series_summary, downloaded)
                rec.is_remote = not rec.downloaded
                rec.source_kind = "hybrid"
                local cp = rec.cover_image_path or getKomgaCoverPath("book", rec.komga_book_id or rec.komga_id, rec.title, series_id)
                if not cp and series_id then
                    cp = getKomgaCoverPath("series", series_id, drill.label)
                end
                if cp then
                    rec.cover_image_path = cp
                    rec.has_cover = true
                elseif rec.downloaded then
                    rec.has_cover = true
                end
                rec.label = rec.label or rec.title
                rec.series_name = rec.series_name or drill.label or active_dto.seriesTitle
                rec.display_title = rec.display_title or rec.title
                rec.active_book = active_dto
                M.scheduleKomgaCovers({ rec })
                return { rec }, 1
            else
                return {}, 0
            end
        end
    end

    -- 1. Drilling down into a series/collection (delegates to shared fetchAndMapSeriesBooks)
    if drill and (drill.kind == "komga_series" or drill.kind == "series" or drill.series_id or drill.komga_series_id or (type(drill.path) == "string" and drill.path:find("^komga://series/"))) then
        local series_id = drill.series_id or drill.komga_series_id or (type(drill.path) == "string" and drill.path:match("^komga://series/(.+)$"))
        local res = fetchAndMapSeriesBooks({
            series_id = series_id,
            series_title = drill.label,
            series_summary = drill.series_summary,
            allow_network = true,
            check_spine_light = false,
        })
        if res.purged then
            return {}, 0
        end
        if res.books and #res.books > 0 then
            return res.books, #res.books
        end
    end

    local ok_sq, SyncQueue = pcall(require, "lib/bridge_sync_queue")
    if ok_sq and SyncQueue and SyncQueue.hasPending and SyncQueue.hasPending() then
        local komga = getKomgaPlugin()
        local api = (komga and komga.api) or getKomgaApi()
        if api then
            SyncQueue.flush(api, function(ok, stats_or_err)
                if ok and type(stats_or_err) == "table" and ((stats_or_err.pushed or 0) > 0 or (stats_or_err.pruned or 0) > 0) then
                    logger.info(string.format("[Hybrid] SyncQueue flush completed (%d pushed, %d pruned); active_queue refreshed",
                        stats_or_err.pushed or 0, stats_or_err.pruned or 0))
                elseif not ok then
                    logger.warn("[Hybrid] SyncQueue flush failed: " .. sanitizeLog(stats_or_err))
                end
            end)
        end
    end

    local ok_s, Sources = pcall(require, "lib/bookshelf_sources")
    if not (ok_s and Sources and Sources.get) then return {}, 0 end

    local komga_spec = Sources.get("komga")
    if not (komga_spec and komga_spec.fetch) then return {}, 0 end

    local komga_source = {
        kind = "komga",
        list = source.komga_list or "all_series",
        library_id = source.library_id,
        library_names = source.library_names,
        read_status = source.read_status,
        status = source.status,
        sort = source.sort,
    }

    if drill then
        -- Query via komga_spec.fetch with limit 1000
        local records, total = komga_spec.fetch(komga_source, drill, 0, 1000)
        records = records or {}
        local series_id = drill.series_id or drill.komga_series_id
        for i = 1, #records do
            local rec = records[i]
            rec.is_remote = not rec.downloaded
            rec.source_kind = "hybrid"
            local cp = rec.cover_image_path or getKomgaCoverPath("book", rec.komga_book_id or rec.komga_id, rec.title, series_id)
            if not cp and series_id then
                cp = getKomgaCoverPath("series", series_id, drill.label)
            end
            if cp then
                rec.cover_image_path = cp
                rec.has_cover = true
            elseif rec.downloaded then
                rec.has_cover = true
            end
            rec.label = rec.label or rec.title
            rec.series_name = rec.series_name or drill.label
            rec.display_title = rec.display_title or rec.title
            if not rec.is_folder and not rec.is_opds_nav and not rec.format then
                local mt = rec.komga_dto and rec.komga_dto.media and rec.komga_dto.media.mediaType
                local fmt = deriveFormat(mt, rec.filename or rec.filepath, rec.title)
                rec.format = fmt
                rec.ext = fmt:lower()
                rec.extension = fmt:lower()
            end
        end
        M.scheduleKomgaCovers(records)
        return records, total or #records
    end

    -- 2. Root all_series query:
    -- Use active all_series cache from kokomga_bookshelf.lua with 3-minute TTL and offline fallback.
    local records, total = M.getAllSeriesRecords(source, is_spine, false)
    records = records or {}
    total = tonumber(total) or #records

    for i = 1, #records do
        local r = records[i]
        r.source_kind = "hybrid"
        r.is_remote = not r.downloaded
        if r.is_folder or r.is_opds_nav or r.komga_series_id or (type(r.filepath) == "string" and r.filepath:find("^komga://series/")) or r.kind == "folder" or r.kind == "opds_nav" then
            r.kind = "folder"
            r.is_folder = true
            r.is_opds_nav = false
            r.source_nav = true
            r.label = r.label or r.title or r.series_name
            r.title = r.title or r.label or r.series_name
            r.series_name = r.series_name or r.title or r.label
            r.display_title = r.display_title or r.title
            r.komga_series_id = r.komga_series_id or (type(r.filepath) == "string" and r.filepath:match("^komga://series/(.+)$"))
            r.path = r.filepath or ("komga://series/" .. tostring(r.komga_series_id))
            local cp = r.cover_image_path or getKomgaCoverPath("series", r.komga_series_id or r.komga_id, r.title or r.label)
            r.is_series = true
            r.page_count = r.page_count or 200
            if cp then
                r.cover_image_path = cp
                r.has_cover = true
                r.first_book = {
                    filepath = r.path,
                    cover_image_path = cp,
                    title = r.title or r.label,
                    has_cover = true,
                    page_count = r.page_count or 200,
                }
            else
                r.first_book = r.first_book or {
                    filepath = r.path,
                    title = r.title or r.label,
                    has_cover = false,
                    page_count = r.page_count or 200,
                }
            end
        end
    end

    return records, total
end

function M.getKomgaFolderRecords(source, folder_path)
    local folder_name = type(folder_path) == "string"
        and folder_path:gsub("/+$", ""):match("([^/]+)$") or nil
    local folder_key = Dedup.nameKey(folder_name)
    if not folder_key then return {}, false end

    if source and source.remote_mode == "next_book" then
        local active_dto = M.getActiveBookForSeries(source, nil, folder_name)
        if active_dto then
            local downloaded = Dedup.getDownloadedMap()
            local rec = bookDtoToRecord(active_dto, folder_name, nil, downloaded)
            rec.is_remote = not rec.downloaded
            rec.source_kind = "hybrid"
            local sid = rec.komga_dto and rec.komga_dto.seriesId
            local cp = rec.cover_image_path or getKomgaCoverPath("book", rec.komga_book_id or rec.komga_id, rec.title, sid)
            if not cp and sid then
                cp = getKomgaCoverPath("series", sid, folder_name)
            end
            if cp then
                rec.cover_image_path = cp
                rec.has_cover = true
            elseif rec.downloaded then
                rec.has_cover = true
            end
            rec.label = rec.label or rec.title
            rec.series_name = rec.series_name or folder_name
            rec.display_title = rec.display_title or rec.title
            rec.active_book = active_dto
            M.scheduleKomgaCovers({ rec })
            return { rec }, 1
        else
            return {}, 0
        end
    end

    -- Fetch top level to find matching series
    local series_list = M.getKomgaRecords(source, nil)
    local matched_series = nil
    for _, s in ipairs(series_list) do
        local s_key = Dedup.nameKey(s.title or s.komga_series_title or s.label)
        if Dedup.nameKeysMatch(s_key, folder_key) then
            matched_series = s
            break
        end
    end

    if not matched_series or not (matched_series.komga_series_id or matched_series.komga_id) then
        return {}, false
    end

    local series_id = matched_series.komga_series_id or matched_series.komga_id
    local drill = {
        kind = "komga_series",
        label = matched_series.title or folder_name,
        series_id = series_id,
    }

    local books, total = M.getKomgaRecords(source, drill)
    return books, false
end

function M.getOpdsDrillRecords(source, drill)
    local feed_url = drill and drill.feed_url
    local server_key = (drill and drill.server_key) or (source and (source.opds_id or source.id))
    if not (feed_url and server_key) then return {}, 0 end
    if not isAllowedHttpUrl(feed_url) then
        logger.warn("[Hybrid] getOpdsDrillRecords rejected invalid feed_url: " .. sanitizeLog(feed_url))
        return {}, 0
    end

    local ok_w, OpdsWindow = pcall(require, "lib/bookshelf_opds_window")
    if not (ok_w and OpdsWindow) then return {}, 0 end

    local win = OpdsWindow.load(server_key, feed_url)
    if type(win) ~= "table" then return {}, 0 end
    local count = tonumber(win.count) or 0

    if count == 0 and not win.complete then
        local ok_f, OpdsFeed = pcall(require, "lib/bookshelf_opds_feed")
        local ok_s, OpdsSource = pcall(require, "lib/bookshelf_opds_source")
        if ok_f and OpdsFeed and ok_s and OpdsSource then
            local server = OpdsSource.getServer(server_key)
            if not server and source and (source.opds_id or source.id) then
                server = OpdsSource.getServer(source.opds_id or source.id)
            end
            local base_url = (server and server.url) or (source and source.feed_url)
            if not base_url or not isSameHost(feed_url, base_url) then
                logger.warn("[Hybrid] getOpdsDrillRecords blocked unverified or cross-host OPDS fetch: " .. sanitizeLog(feed_url))
                return {}, 0
            end
            local user, pass = nil, nil
            if server and base_url and isSameOriginForAuth(feed_url, base_url) then
                user = server.username
                pass = server.password
            end
            local ok_req, res = safeCall("getOpdsDrillRecords.fetch", OpdsFeed.fetch, feed_url, user, pass)
            local body = (type(res) == "table" and res.body) or (type(res) == "string" and res) or nil
            if ok_req and body and body ~= "" then
                local ok_p, cat = safeCall("getOpdsDrillRecords.parse", OpdsFeed.parse, body)
                if ok_p and cat then
                    local ok_m, mapped = safeCall("getOpdsDrillRecords.mapEntries", OpdsFeed.mapEntries, cat, feed_url, server_key)
                    if ok_m and mapped then
                        OpdsWindow.appendPage(win, mapped)
                        win.fetched_at = os.time()
                        win.complete = mapped.next_url == nil
                        safeCall("getOpdsDrillRecords.save", OpdsWindow.save, server_key, feed_url, win)
                        count = tonumber(win.count) or 0
                    end
                end
            end
        end
    end

    local records = {}
    if count > 0 then
        local page = OpdsWindow.slice(win, 0, count)
        local ok_c, OpdsCovers = pcall(require, "lib/bookshelf_opds_covers")
        for i = 1, #page do
            local rec = page[i]
            if ok_c and OpdsCovers then
                rec.cover_image_path = OpdsCovers.cachedPath(rec)
                if rec.cover_image_path then rec.has_cover = true end
            end
            rec.source_kind = "hybrid"
            rec.is_remote = not rec.downloaded
            rec.label = rec.label or rec.title or rec.series_name
            rec.title = rec.title or rec.label or rec.series_name
            rec.display_title = rec.display_title or rec.title
            rec.series_name = rec.series_name or (drill and drill.label) or rec.label or rec.title
            if not rec.is_folder and not rec.is_opds_nav and not rec.format then
                local mt = rec.media_type or (rec.opds and rec.opds.media_type)
                local fmt = deriveFormat(mt, rec.filename or rec.filepath, rec.title)
                rec.format = fmt
                rec.ext = fmt:lower()
                rec.extension = fmt:lower()
            end
            records[#records + 1] = rec
        end
    end

    return records, count
end

-- ---------------------------------------------------------------------------
-- Unified Remote Resolver
-- ---------------------------------------------------------------------------

function M.fetchRemote(source, folder_path, drill, is_spine)
    -- 1. If drilling into an OPDS series or subcatalog feed
    if drill and (drill.kind == "opds_nav" or drill.feed_url) then
        return M.getOpdsDrillRecords(source, drill)
    end

    -- 2. If drilling into a Komga series
    if drill and (drill.kind == "komga_series" or drill.series_id or drill.komga_series_id or (type(drill.path) == "string" and drill.path:find("^komga://series/"))) then
        return M.getKomgaRecords(source, drill, is_spine)
    end

    -- 3. If drilling into a local filesystem folder on a hybrid shelf
    if drill and drill.kind == "folder" and folder_path then
        local remote_kind = source.remote_kind or (source.opds_id and "opds") or "komga"
        if remote_kind == "opds" then
            return M.getOpdsFolderRecords(source, folder_path)
        else
            return M.getKomgaFolderRecords(source, folder_path)
        end
    end

    -- 4. Hybrid shelf root (drill == nil)
    local remote_kind = source.remote_kind or (source.opds_id and "opds") or "komga"
    if remote_kind == "opds" then
        return M.getOpdsRecords(source)
    else
        return M.getKomgaRecords(source, nil, false)
    end
end

-- ---------------------------------------------------------------------------
-- Komga Book Download & Read Progress Management
-- ---------------------------------------------------------------------------

function M.toKomgaBookDto(book)
    if not book then return nil end
    if book.komga_dto and type(book.komga_dto) == "table" then
        return book.komga_dto
    end
    local book_id = book.komga_book_id or book.komga_id
        or (type(book.filepath) == "string" and book.filepath:match("^komga://book/(.+)$"))
        or book.id
    local ext = (book.ext or (book.format and book.format:lower()) or "cbz"):lower()
    local mediaType = "application/zip"
    if ext == "pdf" then mediaType = "application/pdf"
    elseif ext == "epub" then mediaType = "application/epub+zip"
    elseif ext == "cbr" then mediaType = "application/x-rar"
    end
    return {
        id = book_id,
        name = book.title or book.display_title or book.filename or book_id,
        seriesTitle = book.series_name,
        media = { mediaType = mediaType },
        metadata = {
            title = book.title or book.display_title,
            number = book.series_num or book.number,
            authors = book.author and { { name = book.author } } or nil,
        },
    }
end

function M.resolveDownloadDestination(book)
    local ok_u, util = pcall(require, "util")
    local komga = getKomgaPlugin()
    local series_title = book.series_name or (book.komga_dto and book.komga_dto.seriesTitle) or "Komga"
    local dto = book.komga_dto or M.toKomgaBookDto(book)

    if komga and komga.sync and komga.sync.getBookLocalPath then
        local local_path, _ = komga.sync:getBookLocalPath(dto, series_title)
        if local_path and local_path ~= "" then
            return local_path
        end
    end

    local base_dir = nil
    if komga and komga.getDownloadDir then
        base_dir = komga:getDownloadDir()
    end
    if not base_dir or base_dir == "" then
        pcall(function()
            local DataStorage = require("datastorage")
            local LuaSettings = require("luasettings")
            local s = LuaSettings:open(DataStorage:getSettingsDir() .. "/kokomga.lua")
            if s then
                local d = s:readSetting("download_dir")
                if d and d ~= "" then base_dir = d end
            end
        end)
    end
    if not base_dir or base_dir == "" then
        local ok_hd, HomeDir = pcall(require, "lib/bookshelf_home_dir")
        base_dir = (ok_hd and HomeDir and HomeDir.get and HomeDir.get())
            or (G_reader_settings and G_reader_settings:readSetting("home_dir"))
            or "/sdcard/koreader"
    end

    if ok_u and util and util.getSafeFilename then
        series_title = util.getSafeFilename(series_title)
    else
        series_title = series_title:gsub("[/\\?%%*:|\"<>]", "_")
    end
    series_title = series_title:gsub("%z", ""):gsub("^%.+", "_"):gsub("%.%.+", "_")
    if series_title == "" or series_title == "_" then series_title = "unknown_series" end

    local dest_dir = base_dir:gsub("/+$", "") .. "/" .. series_title
    pcall(function()
        if ok_u and util and util.makePath then
            util.makePath(dest_dir .. "/")
        else
            local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
            if ok_lfs and lfs and lfs.mkdir then
                lfs.mkdir(dest_dir)
            end
        end
    end)

    local filename = book.filename
    if not filename or filename == "" or filename:find("^%a+://") then
        local ext = (book.ext or (book.format and book.format:lower()) or "cbz")
        filename = (book.title or book.display_title or "book") .. "." .. ext
    end
    if ok_u and util and util.getSafeFilename then
        filename = util.getSafeFilename(filename, dest_dir)
    else
        filename = filename:gsub("[/\\?%%*:|\"<>]", "_")
    end
    filename = filename:gsub("%z", ""):gsub("^%.+", "_"):gsub("%.%.+", "_")
    if filename == "" or filename == "_" then filename = "download.bin" end

    return dest_dir .. "/" .. filename
end

function M.downloadKomgaBook(book, opts_or_dest, on_success_callback, on_failure_callback)
    local ok_h, Health = pcall(require, "lib/bridge_health")
    if ok_h and Health and Health.isServerReachable and not Health.isServerReachable() then
        local err_msg = "Komga server unreachable"
        if on_failure_callback then on_failure_callback(err_msg) end
        return nil, err_msg
    end

    local is_legacy = type(opts_or_dest) == "string" and type(on_success_callback) ~= "function"
    local komga = getKomgaPlugin()
    local target_dto = M.toKomgaBookDto(book)
    local book_id = validateKomgaId(target_dto and target_dto.id)
    if not book_id then
        local err_msg = "Invalid or missing Komga book ID"
        if on_failure_callback then on_failure_callback(err_msg) end
        return nil, err_msg
    end
    local series_title = book.series_name or (target_dto and target_dto.seriesTitle) or "Komga"

    -- Primary: Delegate directly to Kokomga's native download mechanism
    if not is_legacy and komga and (komga.downloadBook or (komga.sync and komga.sync.downloadBook)) then
        local dl_fn = (komga.downloadBook and function(...) return komga:downloadBook(...) end)
            or (komga.sync and komga.sync.downloadBook and function(...) return komga.sync:downloadBook(...) end)

        return dl_fn(target_dto, series_title, function(local_path)
            M.registerDownloadedBook(book, local_path)
            if on_success_callback then
                on_success_callback(local_path)
            end
        end, function(err)
            if on_failure_callback then
                on_failure_callback(err)
            end
        end, false)
    end

    -- Fallback: Asynchronous or direct download via Komga API
    local dest_path = (type(opts_or_dest) == "string" and opts_or_dest) or M.resolveDownloadDestination(book)
    local tmp_path = dest_path .. ".part"

    local api = (komga and komga.api) or getKomgaApi()
    if api and api.download_book then
        local ok_call, ok_dl, dl_err = safeCall("downloadKomgaBook.api.download_book", api.download_book, api, book_id, tmp_path)
        if ok_call and ok_dl then
            local ok_ren = os.rename(tmp_path, dest_path)
            if not ok_ren then
                local ok_cp, cp_err = copyFileChunked(tmp_path, dest_path, 65536)
                pcall(os.remove, tmp_path)
                if not ok_cp then
                    if on_failure_callback then on_failure_callback(tostring(cp_err)) end
                    return nil, cp_err
                end
            end
            M.registerDownloadedBook(book, dest_path)
            if on_success_callback then on_success_callback(dest_path) end
            return dest_path
        else
            pcall(os.remove, tmp_path)
            local err_msg = not ok_call and tostring(ok_dl) or tostring(dl_err)
            if on_failure_callback then on_failure_callback(err_msg) end
            return nil, err_msg
        end
    end

    if not api or not isAllowedHttpUrl(api.base_url) then
        if on_failure_callback then on_failure_callback("Komga API unavailable") end
        return nil, "Komga API unavailable"
    end

    local url = tostring(api.base_url):gsub("/+$", "") .. "/api/v1/books/" .. book_id .. "/file"
    local headers = copyTableShallow(api.get_headers and api:get_headers() or nil)
    headers["Accept"] = nil
    headers["User-Agent"] = "KOReader-Bookshelf"

    local ok_ah, AsyncHttp = pcall(require, "lib/bridge_async_http")
    if (on_success_callback or on_failure_callback) and ok_ah and AsyncHttp and AsyncHttp.isAvailable and AsyncHttp.isAvailable() then
        local started = AsyncHttp.downloadAsync({
            url = url,
            headers = headers,
            tmp_path = tmp_path,
            dest_path = dest_path,
            connect_timeout = 5,
            max_time = 120,
        }, function(ok, code, _, err_msg)
            if ok then
                M.registerDownloadedBook(book, dest_path)
                if on_success_callback then on_success_callback(dest_path) end
            else
                local msg = err_msg or ("HTTP Error " .. tostring(code))
                if on_failure_callback then on_failure_callback(msg) end
            end
        end)
        if started then
            return nil
        end
    end

    local http = require("socket.http")
    local https = require("ssl.https")
    local socketutil = require("socketutil")

    local file, open_err = io.open(tmp_path, "wb")
    if not file then
        local err_msg = "Failed to open destination: " .. tostring(open_err)
        if on_failure_callback then on_failure_callback(err_msg) end
        return nil, err_msg
    end

    local bytes_written = 0
    local write_err = nil
    local function progress_sink(chunk, err)
        if err then
            write_err = tostring(err)
            return nil, write_err
        end
        if chunk and #chunk > 0 then
            bytes_written = bytes_written + #chunk
            if bytes_written > DEFAULT_MAX_DOWNLOAD_BYTES then
                write_err = "Download exceeds maximum size limit"
                return nil, write_err
            end
            local ok_w, err_w = file:write(chunk)
            if not ok_w then
                write_err = "Write failed: " .. tostring(err_w)
                return nil, write_err
            end
        end
        return 1
    end

    pcall(function()
        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT or 30, socketutil.FILE_TOTAL_TIMEOUT or 300)
    end)

    local ca_bundle, ca_path = resolveCaBundle()
    local cur_url = url
    local cur_headers = copyTableShallow(headers)
    local ok_req, res, code, res_headers, status
    for hop = 1, 6 do
        local parsed = parseHttpUrl(cur_url)
        if not parsed then
            ok_req, res, code, status = false, nil, 0, "Invalid redirect URL"
            break
        end
        local request_params = {
            url = cur_url,
            method = "GET",
            headers = cur_headers,
            sink = progress_sink,
            timeout = 120,
            redirect = false,
        }
        if parsed.scheme == "https" then
            request_params.verify = "peer"
            if ca_bundle then request_params.cafile = ca_bundle end
            if ca_path then request_params.capath = ca_path end
            ok_req, res, code, res_headers, status = safeCall("downloadKomgaBook.https.request", https.request, request_params)
        else
            ok_req, res, code, res_headers, status = safeCall("downloadKomgaBook.http.request", http.request, request_params)
        end
        if not ok_req then break end
        local num_code = tonumber(code) or 0
        if (num_code == 301 or num_code == 302 or num_code == 303 or num_code == 307 or num_code == 308)
                and type(res_headers) == "table" and hop < 6 then
            local loc = res_headers["location"] or res_headers["Location"]
            if not isAllowedHttpUrl(loc) then
                ok_req, res, code, status = false, nil, 0, "Invalid redirect location"
                break
            end
            local next_parsed = parseHttpUrl(loc)
            if parsed.scheme == "https" and next_parsed.scheme ~= "https" then
                ok_req, res, code, status = false, nil, 0, "Blocked HTTPS to HTTP redirect"
                break
            end
            if not isSameOriginForAuth(loc, cur_url) then
                cur_headers["Authorization"] = nil
                cur_headers["authorization"] = nil
                cur_headers["X-API-Key"] = nil
                cur_headers["x-api-key"] = nil
            end
            cur_url = loc
        else
            break
        end
    end

    pcall(function() socketutil:reset_timeout() end)
    local ok_close, close_err = file:close()

    if not ok_req then
        pcall(os.remove, tmp_path)
        local err_msg = "Download request failed: " .. tostring(res)
        if on_failure_callback then on_failure_callback(err_msg) end
        return nil, err_msg
    end

    if write_err or not ok_close then
        pcall(os.remove, tmp_path)
        local err_msg = write_err or ("Failed to flush downloaded file: " .. tostring(close_err))
        if on_failure_callback then on_failure_callback(err_msg) end
        return nil, err_msg
    end

    code = tonumber(code) or 0
    if not res or code < 200 or code >= 300 then
        pcall(os.remove, tmp_path)
        local err_msg = "HTTP Error " .. tostring(code) .. " (" .. tostring(status) .. ")"
        if on_failure_callback then on_failure_callback(err_msg) end
        return nil, err_msg
    end

    local ok_ren = os.rename(tmp_path, dest_path)
    if not ok_ren then
        local ok_cp, cp_err = copyFileChunked(tmp_path, dest_path, 65536)
        pcall(os.remove, tmp_path)
        if not ok_cp then
            local err_msg = "Failed to save file: " .. tostring(cp_err or dest_path)
            if on_failure_callback then on_failure_callback(err_msg) end
            return nil, err_msg
        end
    end

    M.registerDownloadedBook(book, dest_path)
    if on_success_callback then on_success_callback(dest_path) end
    return dest_path
end

function M.registerDownloadedBook(book, local_path)
    if not (book and local_path) then return end
    local book_id = book.komga_book_id or book.komga_id or (type(book.filepath) == "string" and book.filepath:match("^komga://book/(.+)$"))
    local rec_key = "komga://book/" .. tostring(book_id or "")

    pcall(function()
        local ok_s, Store = pcall(require, "lib/bookshelf_settings_store")
        if ok_s and Store and Store.read and Store.save then
            local map = Store.read("opds_downloads") or {}
            map[rec_key] = local_path
            if type(book.filepath) == "string" and book.filepath ~= rec_key then
                map[book.filepath] = local_path
            end
            Store.save("opds_downloads", map)
        end
    end)

    pcall(function()
        local komga = getKomgaPlugin()
        if komga and komga.getOpdsDownloadsPath then
            local ok_ls, LuaSettings = pcall(require, "luasettings")
            if ok_ls and LuaSettings then
                local kokomga_dl = LuaSettings:open(komga:getOpdsDownloadsPath())
                if kokomga_dl then
                    local downloads = kokomga_dl:readSetting("downloads") or {}
                    downloads[rec_key] = local_path
                    if type(book.filepath) == "string" and book.filepath ~= rec_key then
                        downloads[book.filepath] = local_path
                    end
                    kokomga_dl:saveSetting("downloads", downloads)
                    kokomga_dl:flush()
                end
            end
        end
    end)

    pcall(function()
        local ok_r, Repo = pcall(require, "lib/bookshelf_book_repository")
        if ok_r and Repo and Repo.invalidateWalkCache then
            Repo.invalidateWalkCache()
        end
    end)
    if Dedup and Dedup.invalidateDownloadedMap then
        Dedup.invalidateDownloadedMap()
    end
end

function M.deleteDownloadedBook(book, local_path)
    if type(local_path) ~= "string" or local_path == "" then return false, "invalid_path" end
    local norm_path = normalizeAbsPath(local_path)
    if not norm_path then
        logger.warn("[Hybrid] deleteDownloadedBook rejected unsafe path: " .. sanitizeLog(local_path))
        return false, "unsafe_path"
    end

    -- Verify path is either inside an allowed download/data root or explicitly registered in downloads map
    local allowed_roots = {}
    local komga = getKomgaPlugin()
    if komga and komga.getDownloadDir then
        local ok_d, d = pcall(komga.getDownloadDir, komga)
        if ok_d and type(d) == "string" and d ~= "" then allowed_roots[#allowed_roots + 1] = d end
    end
    local ok_hd, HomeDir = pcall(require, "lib/bookshelf_home_dir")
    if ok_hd and HomeDir and HomeDir.get then
        local d = HomeDir.get()
        if type(d) == "string" and d ~= "" then allowed_roots[#allowed_roots + 1] = d end
    end
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if ok_ds and DataStorage and DataStorage.getDataDir then
        local dd = DataStorage:getDataDir()
        if type(dd) == "string" and dd ~= "" then allowed_roots[#allowed_roots + 1] = dd end
    end

    local in_allowed_root = false
    for _, r in ipairs(allowed_roots) do
        if isPathWithinRoot(norm_path, r) then
            in_allowed_root = true
            break
        end
    end
    if not in_allowed_root then
        local dm = Dedup and Dedup.getDownloadedMap and Dedup.getDownloadedMap() or {}
        for _, p in pairs(dm) do
            if p == local_path or normalizeAbsPath(p) == norm_path then
                in_allowed_root = true
                break
            end
        end
    end
    if not in_allowed_root then
        logger.warn("[Hybrid] deleteDownloadedBook rejected path outside allowed roots: " .. sanitizeLog(local_path))
        return false, "path_outside_root"
    end

    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok_lfs and lfs and lfs.attributes and lfs.attributes(norm_path, "mode") == "file" then
        local ok_rm, rm_err = os.remove(norm_path)
        if not ok_rm then
            logger.warn("[Hybrid] deleteDownloadedBook failed to remove file: " .. sanitizeLog(rm_err))
            return false, rm_err
        end
    end
    local sidecar = norm_path:gsub("%.%w+$", ".cover.jpg")
    if sidecar ~= norm_path and sidecar:match("%.cover%.jpg$") then
        pcall(os.remove, sidecar)
    end

    local book_id = book and validateKomgaId(
        book.komga_book_id or book.komga_id
        or (type(book.filepath) == "string" and book.filepath:match("^komga://book/(.+)$"))
    ) or nil
    local rec_key = book_id and ("komga://book/" .. book_id) or nil

    safeCall("deleteDownloadedBook.store", function()
        local ok_s, Store = pcall(require, "lib/bookshelf_settings_store")
        if ok_s and Store and Store.read and Store.save then
            local map = Store.read("opds_downloads") or {}
            if rec_key then map[rec_key] = nil end
            if book and type(book.filepath) == "string" then map[book.filepath] = nil end
            Store.save("opds_downloads", map)
        end
    end)

    safeCall("deleteDownloadedBook.kokomga_dl", function()
        if komga and komga.getOpdsDownloadsPath then
            local ok_ls, LuaSettings = pcall(require, "luasettings")
            if ok_ls and LuaSettings then
                local kokomga_dl = LuaSettings:open(komga:getOpdsDownloadsPath())
                if kokomga_dl then
                    local downloads = kokomga_dl:readSetting("downloads") or {}
                    if rec_key then downloads[rec_key] = nil end
                    if book and type(book.filepath) == "string" then downloads[book.filepath] = nil end
                    kokomga_dl:saveSetting("downloads", downloads)
                    kokomga_dl:flush()
                end
            end
        end
    end)

    safeCall("deleteDownloadedBook.invalidateRepo", function()
        local ok_r, Repo = pcall(require, "lib/bookshelf_book_repository")
        if ok_r and Repo and Repo.invalidateWalkCache then
            Repo.invalidateWalkCache()
        end
    end)

    if Dedup and Dedup.invalidateDownloadedMap then
        Dedup.invalidateDownloadedMap()
    end

    return true
end

local function invalidateProgressCaches(clear_disk_active_queue)
    _mem_all_series = {}
    if clear_disk_active_queue then
        safeCall("invalidateProgressCaches.clearActiveQueue", function()
            local DataStorage = require("datastorage")
            local LuaSettings = require("luasettings")
            local s = LuaSettings:open(DataStorage:getSettingsDir() .. "/kokomga_bookshelf.lua")
            if s then
                local lists = s:readSetting("lists")
                if lists and lists["active_queue"] then
                    lists["active_queue"] = nil
                    s:saveSetting("lists", lists)
                    s:flush()
                end
            end
        end)
    end
    local ok_sp, HybridSpec = pcall(require, "lib/hybrid_spec")
    if ok_sp and HybridSpec and HybridSpec.clearSeriesCache then
        safeCall("invalidateProgressCaches.clearSeriesCache", HybridSpec.clearSeriesCache)
    end
end

local function isTransientTransportError(err, is_unreachable)
    if is_unreachable then return true end
    if err == nil then return true end
    local s = tostring(err):lower()
    local patterns = {
        "timeout", "timed out", "unreachable", "refused", "closed",
        "reset", "broken pipe", "network is down", "no route",
        "host not found", "502", "503", "504",
    }
    for _, pat in ipairs(patterns) do
        if s:find(pat, 1, true) then return true end
    end
    return false
end

function M.setKomgaReadProgress(book_id, completed)
    local valid_id = validateKomgaId(book_id)
    if not valid_id then
        return false, "invalid_book_id"
    end
    book_id = valid_id

    local ok_sq, SyncQueue = pcall(require, "lib/bridge_sync_queue")
    local ok_h, Health = pcall(require, "lib/bridge_health")
    local reachable = true
    if ok_h and Health and Health.isServerReachable then
        reachable = Health.isServerReachable()
    end

    local function enqueueOffline(reason)
        if ok_sq and SyncQueue and SyncQueue.enqueue then
            local ok_enq, enq_res = safeCall("setKomgaReadProgress.enqueue", SyncQueue.enqueue,
                completed and "progress" or "delete", book_id, { completed = completed })
            if ok_enq and enq_res ~= false then
                invalidateProgressCaches(false)
                return false, "queued", reason
            end
        end
        return false, reason
    end

    if not reachable then
        return enqueueOffline("offline")
    end

    local komga = getKomgaPlugin()
    local api = (komga and komga.api) or getKomgaApi()
    if not api then
        return enqueueOffline("no_api")
    end

    local ok_call, success, err, is_unreachable
    if completed then
        if type(api.patch_read_progress) == "function" then
            ok_call, success, err, is_unreachable = safeCall("setKomgaReadProgress.patch_read_progress",
                api.patch_read_progress, api, book_id, nil, true)
        elseif type(api.request) == "function" then
            ok_call, success, err, is_unreachable = safeCall("setKomgaReadProgress.patch",
                api.request, api, "/api/v1/books/" .. book_id .. "/read-progress", "PATCH", { completed = true })
        else
            return enqueueOffline("no_api_method")
        end
    else
        if type(api.request) == "function" then
            ok_call, success, err, is_unreachable = safeCall("setKomgaReadProgress.delete",
                api.request, api, "/api/v1/books/" .. book_id .. "/read-progress", "DELETE")
        else
            return enqueueOffline("no_api_method")
        end
    end

    if not ok_call then
        err = success
        success = false
        is_unreachable = true
    end

    if not success then
        if isTransientTransportError(err, is_unreachable) then
            if ok_h and Health and Health.tripCircuitBreaker then
                safeCall("setKomgaReadProgress.tripCircuitBreaker", Health.tripCircuitBreaker, err)
            end
            return enqueueOffline(tostring(err or "transport_error"))
        end
        return false, err
    end

    if ok_sq and SyncQueue and SyncQueue.remove then
        safeCall("setKomgaReadProgress.remove", SyncQueue.remove, book_id)
    end
    invalidateProgressCaches(true)
    return true
end

M.bookDtoToRecord = bookDtoToRecord

return M
