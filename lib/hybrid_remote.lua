-- lib/hybrid_remote.lua
-- Remote record retrieval for OPDS feeds and Komga API.

local logger = require("logger")
local Dedup = require("lib/hybrid_dedup")

local M = {}

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
    local count = tonumber(win.count) or 0
    local records = {}

    if count > 0 then
        local page = OpdsWindow.slice(win, 0, count)
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

    local root_records, _ = M.getOpdsRecords(source)
    local records = {}
    local needs_fetch = false

    for _, nav in ipairs(root_records) do
        local nav_key = (nav.is_opds_nav or nav.is_folder) and Dedup.nameKey(nav.label or nav.name or nav.title)
        local child_feed_url = nav.opds and nav.opds.feed_url
        if Dedup.nameKeysMatch(nav_key, folder_key) and type(child_feed_url) == "string" then
            local server_id = source.opds_id or source.id
            local child = OpdsWindow.load(server_id, child_feed_url)
            local child_count = tonumber(child.count) or 0
            if child_count > 0 then
                local page = OpdsWindow.slice(child, 0, child_count)
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
    local i = 1
    while true do
        local name, val = debug.getupvalue(fn, i)
        if not name then break end
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
    if not (target and target.get_books_for_series) then return false end
    if target._bridge_sort_patched then return true end
    target._bridge_sort_patched = true

    local orig_get_books = target.get_books_for_series
    target.get_books_for_series = function(self, series_id, filters, page, size)
        if filters and filters.sort then
            local clean = {}
            for k, v in pairs(filters) do clean[k] = v end
            clean.sort = nil
            local ok_res, res = pcall(orig_get_books, self, series_id, clean, page, size)
            if ok_res and res then return res end
        end
        return orig_get_books(self, series_id, filters, page, size)
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

local function asTable(v) return type(v) == "table" and v or nil end
local function asString(v) return type(v) == "string" and v or nil end
local function asNumber(v) return type(v) == "number" and v or nil end
local function asScalar(v)
    local t = type(v)
    if t == "string" or t == "number" then return v end
end

local function trimBook(book)
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
        id = asString(book.id),
        name = asString(book.name),
        seriesId = asString(book.seriesId),
        seriesTitle = asString(book.seriesTitle),
        oneshot = book.oneshot == true,
        lastModified = asString(book.lastModified),
        media = { mediaType = asString(media.mediaType), pagesCount = asNumber(media.pagesCount) },
        metadata = {
            title = asString(md.title),
            number = asScalar(md.number),
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

local function createKomgaApiFallback()
    local DataStorage = require("datastorage")
    local LuaSettings = require("luasettings")
    local ok_s_file, s = pcall(LuaSettings.open, LuaSettings, DataStorage:getSettingsDir() .. "/kokomga.lua")
    local url = ok_s_file and s and s:readSetting("server_url")
    local key = ok_s_file and s and s:readSetting("api_key")
    local auth_h = ok_s_file and s and s:readSetting("auth_header")
    if url and url ~= "" and ((key and key ~= "") or (auth_h and auth_h ~= "")) then
        pcall(require, "kokomga/core/api")
        pcall(require, "plugins/kokomga.koplugin/core/api")
        pcall(require, "core/api")
        for k, v in pairs(package.loaded) do
            if type(k) == "string" and k:find("core/api") and type(v) == "table" and v.new then
                local ok_a, new_api = pcall(v.new, v, url, key or "")
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
local _series_title_to_id = nil

function M.clearCoverPathCache()
    _cover_path_cache = {}
    _series_title_to_id = nil
end

function M.lookupSeriesIdByTitle(title)
    if type(title) ~= "string" or title == "" then return nil end
    local title_key = Dedup.nameKey(title)
    if not title_key then return nil end

    if not _series_title_to_id then
        _series_title_to_id = {}
        pcall(function()
            local DataStorage = require("datastorage")
            local LuaSettings = require("luasettings")
            local s = LuaSettings:open(DataStorage:getSettingsDir() .. "/kokomga_bookshelf.lua")
            if s then
                local pages = s:readSetting("pages") or {}
                for _, page in pairs(pages) do
                    local items = page and page.items
                    if items then
                        for _, item in ipairs(items) do
                            if item.id and item.title then
                                local k = Dedup.nameKey(item.title)
                                if k and not _series_title_to_id[k] then
                                    _series_title_to_id[k] = tostring(item.id)
                                end
                            end
                        end
                    end
                end
            end
        end)
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
    if not type_label then return nil end
    if not id and type_label == "series" and title then
        id = M.lookupSeriesIdByTitle(title)
    end

    local cache_key = tostring(type_label) .. ":" .. tostring(id or "") .. ":" .. tostring(title or "") .. ":" .. tostring(fallback_id or "")
    local cached = _cover_path_cache[cache_key]
    if cached ~= nil then
        return cached or nil
    end

    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    local function exists(p)
        if type(p) ~= "string" or p == "" then return false end
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
                root .. "/" .. title .. "/.cover.jpg",
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

local function bookDtoToRecord(dto, fallback_label, fallback_summary, downloaded)
    downloaded = downloaded or Dedup.getDownloadedMap()
    local md = dto.metadata or {}
    local title = md.title or dto.name or "?"
    local id_str = tostring(dto.id)
    local rec_key = "komga://book/" .. id_str
    local local_path = downloaded[rec_key] or downloaded[id_str]

    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if local_path and ok_lfs and lfs and lfs.attributes and lfs.attributes(local_path, "mode") ~= "file" then
        local_path = nil
    end

    local progress = dto.readProgress
    local pct = (progress and progress.completed and 1)
        or (progress and progress.page and dto.media and dto.media.pagesCount and math.min(progress.page / dto.media.pagesCount, 0.99))
        or 0
    local status = (progress and progress.completed and "finished")
        or ((progress and progress.page) and "reading" or "unread")

    if local_path then
        local ok_ds, DocSettings = pcall(require, "docsettings")
        if ok_ds and DocSettings and DocSettings.open then
            local ok_o, ds = pcall(DocSettings.open, DocSettings, local_path)
            if ok_o and ds and ds.readSetting then
                local summary = ds:readSetting("summary")
                local lpct = tonumber(ds:readSetting("percent_finished"))
                if (summary and type(summary) == "table" and summary.status == "complete") or (lpct and lpct >= 0.99) then
                    status = "finished"
                    pct = 1.0
                elseif (summary and type(summary) == "table" and summary.status == "reading") or (lpct and lpct > 0) then
                    status = "reading"
                    pct = lpct
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
    }
end

local _komga_covers_queue = {}
local _komga_covers_attempted = {}
local _komga_queue_running = false
local _repaint_scheduled = false

local function scheduleRepaint()
    if _repaint_scheduled then return end
    _repaint_scheduled = true
    local ok_ui, UIManager = pcall(require, "ui/uimanager")
    if ok_ui and UIManager and UIManager.scheduleIn then
        UIManager:scheduleIn(0.5, function()
            _repaint_scheduled = false
            M.clearCoverPathCache()
            local ok_s, Sources = pcall(require, "lib/bookshelf_sources")
            if ok_s and Sources and Sources.changed then
                Sources.changed("hybrid")
            end
        end)
    else
        _repaint_scheduled = false
        M.clearCoverPathCache()
        local ok_s, Sources = pcall(require, "lib/bookshelf_sources")
        if ok_s and Sources and Sources.changed then
            Sources.changed("hybrid")
        end
    end
end

local function processNextCover()
    if #_komga_covers_queue == 0 then
        _komga_queue_running = false
        return
    end

    local ok_net, NetworkMgr = pcall(require, "ui/network/manager")
    if ok_net and NetworkMgr and NetworkMgr.isConnected and not NetworkMgr:isConnected() then
        _komga_covers_queue = {}
        _komga_queue_running = false
        return
    end

    local ok_h, Health = pcall(require, "lib/bridge_health")
    if ok_h and Health and Health.isServerReachable and not Health.isServerReachable() then
        _komga_covers_queue = {}
        _komga_queue_running = false
        return
    end

    local plugin = getKomgaPlugin()
    if not (plugin and plugin.cache and plugin.cache.cacheThumbnail) then
        _komga_covers_queue = {}
        _komga_queue_running = false
        return
    end

    local m = table.remove(_komga_covers_queue, 1)
    if m then
        local ok, path = pcall(plugin.cache.cacheThumbnail, plugin.cache,
            m.type_label, m.id, m.lastModified, true)
        if ok and path then
            scheduleRepaint()
        end
    end

    if #_komga_covers_queue > 0 then
        local ok_ui, UIManager = pcall(require, "ui/uimanager")
        if ok_ui and UIManager and UIManager.scheduleIn then
            UIManager:scheduleIn(0.1, processNextCover)
        else
            _komga_queue_running = false
        end
    else
        _komga_queue_running = false
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
            if id and not getKomgaCoverPath(type_label, id) then
                local key = type_label .. "_" .. tostring(id)
                if not _komga_covers_attempted[key] then
                    _komga_covers_attempted[key] = true
                    _komga_covers_queue[#_komga_covers_queue + 1] = {
                        key = key,
                        type_label = type_label,
                        id = id,
                        lastModified = rec.komga_dto and rec.komga_dto.lastModified,
                    }
                    added = added + 1
                    if added >= 6 then break end
                end
            end
            -- Also queue active_book cover if present on series record
            if rec.active_book and rec.active_book.id and added < 6 then
                local b_id = rec.active_book.id
                if not getKomgaCoverPath("book", b_id) then
                    local key = "book_" .. tostring(b_id)
                    if not _komga_covers_attempted[key] then
                        _komga_covers_attempted[key] = true
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
            local ok_ip, resp_ip = pcall(api.get_books, api,
                { read_status = "IN_PROGRESS", sort = "readProgress.readDate,desc" }, 0, 100)
            local content_ip = ok_ip and resp_ip and (resp_ip.content or (resp_ip[1] and resp_ip))
            if content_ip then
                for _, b in ipairs(content_ip) do
                    local tb = trimBook(b)
                    if tb and tb.id and tb.seriesId then
                        in_progress[#in_progress + 1] = tb
                    end
                end
            end

            -- 2. On Deck books
            local ok_od, resp_od = pcall(api.get_books_ondeck, api, 0, 100)
            local content_od = ok_od and resp_od and (resp_od.content or (resp_od[1] and resp_od))
            if content_od then
                for _, b in ipairs(content_od) do
                    local tb = trimBook(b)
                    if tb and tb.id and tb.seriesId then
                        ondeck[#ondeck + 1] = tb
                    end
                end
            end

            -- Group by seriesId: in-progress takes precedence over on-deck
            local series_map = {}
            local series_order = {}

            for _, b in ipairs(in_progress) do
                local sid = tostring(b.seriesId)
                if not series_map[sid] then
                    series_map[sid] = b
                    series_order[#series_order + 1] = sid
                end
            end

            for _, b in ipairs(ondeck) do
                local sid = tostring(b.seriesId)
                if not series_map[sid] then
                    series_map[sid] = b
                    series_order[#series_order + 1] = sid
                end
            end

            local items = {
                by_series = series_map,
                series_order = series_order,
            }

            cached_entry = items
            pcall(function()
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

function M.getActiveSeriesRecords(source)
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
                first_book = {
                    filepath = filepath,
                    cover_image_path = cp,
                    title = series_title,
                    has_cover = has_cover,
                },
                active_book = book_dto,
            }
            records[#records + 1] = rec
        end
    end

    M.scheduleKomgaCovers(records)
    return records, #records
end

function M.getKomgaRecords(source, drill)
    ensureKomgaApiPatched()

    -- Next Book mode interception
    if source and source.remote_mode == "next_book" then
        if not drill then
            return M.getActiveSeriesRecords(source)
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
                M.scheduleKomgaCovers({ rec })
                return { rec }, 1
            end
        end
    end

    -- 1. Drilling down into a series/collection
    if drill and (drill.kind == "komga_series" or drill.kind == "series" or drill.series_id or drill.komga_series_id or (type(drill.path) == "string" and drill.path:find("^komga://series/"))) then
        local series_id = drill.series_id or drill.komga_series_id or (type(drill.path) == "string" and drill.path:match("^komga://series/(.+)$"))
        local cached_items = nil
        local fetched_at = 0
        if series_id then
            pcall(function()
                local DataStorage = require("datastorage")
                local LuaSettings = require("luasettings")
                local s = LuaSettings:open(DataStorage:getSettingsDir() .. "/kokomga_bookshelf.lua")
                if s then
                    local entries = s:readSetting("series") or {}
                    local e = entries[series_id]
                    if e and e.items and #e.items > 0 then
                        cached_items = e.items
                        fetched_at = tonumber(e.fetched_at) or 0
                    end
                end
            end)
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

        if series_id and is_cache_stale and can_fetch then
            local komga = getKomgaPlugin()
            local api = (komga and komga.api) or getKomgaApi()
            if api then
                local ok_res, resp = pcall(api.get_books_for_series, api, series_id,
                    { sort = "metadata.numberSort,asc" }, 0, 1000)
                if not ok_res or not resp then
                    ok_res, resp = pcall(api.get_books_for_series, api, series_id, nil, 0, 1000)
                end
                local content = resp and (resp.content or (resp[1] and resp))
                if content and #content > 0 then
                    cached_items = trimBooks(content, 1000)
                    pcall(function()
                        local DataStorage = require("datastorage")
                        local LuaSettings = require("luasettings")
                        local s = LuaSettings:open(DataStorage:getSettingsDir() .. "/kokomga_bookshelf.lua")
                        if s then
                            local entries = s:readSetting("series") or {}
                            entries[series_id] = { fetched_at = os.time(), items = cached_items }
                            s:saveSetting("series", entries)
                            s:flush()
                        end
                    end)
                end
            end
        end

        if cached_items and #cached_items > 0 then
            local downloaded = Dedup.getDownloadedMap()
            local books = {}
            for _, dto in ipairs(cached_items) do
                local rec = bookDtoToRecord(dto, drill.label, drill.series_summary, downloaded)
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
                books[#books + 1] = rec
            end
            M.scheduleKomgaCovers(books)
            return books, #books
        end
    end

    local ok_h, Health = pcall(require, "lib/bridge_health")
    if ok_h and Health and Health.isServerReachable and not Health.isServerReachable() then
        logger.info("[Hybrid] Komga server unreachable, returning empty remote records")
        return {}, 0
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
    -- Ask komga_spec for all cached items (limit 100000 tells kokomga want_all=true,
    -- which reads all cached pages instantly in <2ms from memory/disk without network blocking).
    local records, total = komga_spec.fetch(komga_source, nil, 0, 100000)
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
            if cp then
                r.cover_image_path = cp
                r.has_cover = true
                r.first_book = {
                    filepath = r.path,
                    cover_image_path = cp,
                    title = r.title or r.label,
                    has_cover = true,
                }
            else
                r.first_book = r.first_book or {
                    filepath = r.path,
                    title = r.title or r.label,
                    has_cover = false,
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
            M.scheduleKomgaCovers({ rec })
            return { rec }, 1
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
    local feed_url = drill.feed_url
    local server_key = drill.server_key or source.opds_id or source.id
    if not (feed_url and server_key) then return {}, 0 end

    local ok_w, OpdsWindow = pcall(require, "lib/bookshelf_opds_window")
    if not (ok_w and OpdsWindow) then return {}, 0 end

    local win = OpdsWindow.load(server_key, feed_url)
    local count = tonumber(win.count) or 0

    if count == 0 and not win.complete then
        local ok_f, OpdsFeed = pcall(require, "lib/bookshelf_opds_feed")
        local ok_s, OpdsSource = pcall(require, "lib/bookshelf_opds_source")
        if ok_f and OpdsFeed and ok_s and OpdsSource then
            local server = OpdsSource.getServer(server_key)
            local user = server and server.username
            local pass = server and server.password
            local ok_req, res = pcall(OpdsFeed.fetch, feed_url, user, pass)
            local body = (type(res) == "table" and res.body) or (type(res) == "string" and res) or nil
            if ok_req and body and body ~= "" then
                local ok_p, cat = pcall(OpdsFeed.parse, body)
                if ok_p and cat then
                    local ok_m, mapped = pcall(OpdsFeed.mapEntries, cat, feed_url, server_key)
                    if ok_m and mapped then
                        OpdsWindow.appendPage(win, mapped)
                        win.fetched_at = os.time()
                        win.complete = mapped.next_url == nil
                        pcall(OpdsWindow.save, server_key, feed_url, win)
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

function M.fetchRemote(source, folder_path, drill)
    -- 1. If drilling into an OPDS series or subcatalog feed
    if drill and (drill.kind == "opds_nav" or drill.feed_url) then
        return M.getOpdsDrillRecords(source, drill)
    end

    -- 2. If drilling into a Komga series
    if drill and (drill.kind == "komga_series" or drill.series_id or drill.komga_series_id or (type(drill.path) == "string" and drill.path:find("^komga://series/"))) then
        return M.getKomgaRecords(source, drill)
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
        return M.getKomgaRecords(source, nil)
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
    local book_id = target_dto and target_dto.id
    if not book_id then
        if on_failure_callback then on_failure_callback("Missing Komga book ID") end
        return nil, "Missing Komga book ID"
    end

    local api = (komga and komga.api) or getKomgaApi()
    if api and api.download_book then
        local ok_dl, dl_err = api:download_book(book_id, tmp_path)
        if ok_dl then
            os.rename(tmp_path, dest_path)
            M.registerDownloadedBook(book, dest_path)
            if on_success_callback then on_success_callback(dest_path) end
            return dest_path
        else
            if on_failure_callback then on_failure_callback(tostring(dl_err)) end
            return nil, dl_err
        end
    end

    if not api or not api.base_url or api.base_url == "" then
        if on_failure_callback then on_failure_callback("Komga API unavailable") end
        return nil, "Komga API unavailable"
    end

    local http = require("socket.http")
    local https = require("ssl.https")
    local socketutil = require("socketutil")

    local url = api.base_url .. "/api/v1/books/" .. tostring(book_id) .. "/file"
    local headers = api.get_headers and api:get_headers() or {}
    headers["Accept"] = nil
    headers["User-Agent"] = "KOReader-Bookshelf"

    local file, open_err = io.open(tmp_path, "wb")
    if not file then
        local err_msg = "Failed to open destination: " .. tostring(open_err)
        if on_failure_callback then on_failure_callback(err_msg) end
        return nil, err_msg
    end

    local function progress_sink(chunk, err)
        if chunk and #chunk > 0 then
            file:write(chunk)
        end
        return 1
    end

    pcall(function()
        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT or 30, socketutil.FILE_TOTAL_TIMEOUT or 300)
    end)

    local request_params = {
        url = url,
        method = "GET",
        headers = headers,
        sink = progress_sink,
        timeout = 120,
    }

    local res, code, res_headers, status
    if url:find("https://") == 1 then
        res, code, res_headers, status = https.request(request_params)
    else
        res, code, res_headers, status = http.request(request_params)
    end

    pcall(function() socketutil:reset_timeout() end)
    pcall(file.close, file)

    code = tonumber(code) or 0
    if not res or code < 200 or code >= 300 then
        pcall(os.remove, tmp_path)
        local err_msg = "HTTP Error " .. tostring(code) .. " (" .. tostring(status) .. ")"
        if on_failure_callback then on_failure_callback(err_msg) end
        return nil, err_msg
    end

    local ok_ren = os.rename(tmp_path, dest_path)
    if not ok_ren then
        local rf = io.open(tmp_path, "rb")
        local wf = io.open(dest_path, "wb")
        if rf and wf then
            wf:write(rf:read("*a"))
            rf:close()
            wf:close()
            pcall(os.remove, tmp_path)
        else
            local err_msg = "Failed to save file: " .. tostring(dest_path)
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
end

function M.deleteDownloadedBook(book, local_path)
    if not local_path or local_path == "" then return false end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok_lfs and lfs and lfs.attributes and lfs.attributes(local_path, "mode") == "file" then
        pcall(os.remove, local_path)
    end
    local sidecar = local_path:gsub("%.%w+$", ".cover.jpg")
    pcall(os.remove, sidecar)

    local book_id = book.komga_book_id or book.komga_id or (type(book.filepath) == "string" and book.filepath:match("^komga://book/(.+)$"))
    local rec_key = "komga://book/" .. tostring(book_id or "")

    pcall(function()
        local ok_s, Store = pcall(require, "lib/bookshelf_settings_store")
        if ok_s and Store and Store.read and Store.save then
            local map = Store.read("opds_downloads") or {}
            map[rec_key] = nil
            if type(book.filepath) == "string" then map[book.filepath] = nil end
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
                    downloads[rec_key] = nil
                    if type(book.filepath) == "string" then downloads[book.filepath] = nil end
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

    return true
end

function M.setKomgaReadProgress(book_id, completed)
    if not book_id then return false end
    local komga = getKomgaPlugin()
    local api = (komga and komga.api) or getKomgaApi()
    if not api then return false end

    if completed then
        if api.patch_read_progress then
            return pcall(api.patch_read_progress, api, book_id, nil, true)
        else
            return pcall(api.request, api, "/api/v1/books/" .. tostring(book_id) .. "/read-progress", "PATCH", { completed = true })
        end
    else
        return pcall(api.request, api, "/api/v1/books/" .. tostring(book_id) .. "/read-progress", "DELETE")
    end
end

M.bookDtoToRecord = bookDtoToRecord

return M
