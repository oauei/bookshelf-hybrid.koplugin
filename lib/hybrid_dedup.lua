-- lib/hybrid_dedup.lua
-- Normalization, deduplication, and merging for hybrid shelf items.

local logger = require("logger")

local M = {}

local _hybrid_unescape_map = {
    lt = "<", gt = ">", amp = "&", quot = '"', apos = "'",
    rsquo = "'", lsquo = "'", rdquo = '"', ldquo = '"',
    hellip = " ", ndash = "-", mdash = "-", nbsp = " ",
}

function M.unescapeHtml(str)
    if type(str) ~= "string" or not str:find("&") then return str end
    return (str:gsub('(&(#?)([%d%a]+);)', function(orig, n, s)
        if _hybrid_unescape_map[s] then return _hybrid_unescape_map[s] end
        if n == "#" then
            local cp = (s:sub(1, 1) == "x" or s:sub(1, 1) == "X")
                and tonumber(s:sub(2), 16) or tonumber(s)
            if cp then
                if cp < 128 then return string.char(cp) end
                if cp == 8217 or cp == 8216 or cp == 8219 or cp == 8242 then return "'" end
                if cp == 8220 or cp == 8221 then return '"' end
                if cp == 8230 then return " " end
                if cp == 8211 or cp == 8212 then return "-" end
                local ok_u, util = pcall(require, "util")
                if ok_u and util and util.unicodeCodepointToUtf8 then
                    return util.unicodeCodepointToUtf8(cp)
                end
            end
        end
        return orig
    end))
end

local _multibyte_punct = {
    ["\xE2\x80\x99"] = " ", -- ’
    ["\xE2\x80\x98"] = " ", -- ‘
    ["\xE2\x80\x9B"] = " ", -- ‛
    ["\xCA\xBC"]     = " ", -- ʼ
    ["\xEF\xBC\x87"] = " ", -- ＇
    ["\xC2\xB4"]     = " ", -- ´
    ["\xE2\x80\xB2"] = " ", -- ′
    ["\xE2\x80\x90"] = " ", -- ‐
    ["\xE2\x80\x91"] = " ", -- ‑
    ["\xE2\x80\x92"] = " ", -- ‒
    ["\xE2\x80\x93"] = " ", -- –
    ["\xE2\x80\x94"] = " ", -- —
    ["\xE2\x80\x95"] = " ", -- ―
    ["\xE3\x80\x9C"] = " ", -- 〜
    ["\xEF\xBD\x9E"] = " ", -- ～
    ["\xE2\x80\xA6"] = " ", -- …
    ["\xE2\x80\x9C"] = " ", -- “
    ["\xE2\x80\x9D"] = " ", -- ”
    ["\xC2\xAB"]     = " ", -- «
    ["\xC2\xBB"]     = " ", -- »
    ["\xE2\x80\xB9"] = " ", -- ‹
    ["\xE2\x80\xBA"] = " ", -- ›
    ["\xC2\xA0"]     = " ", -- non-breaking space
    ["\xE3\x80\x80"] = " ", -- ideographic space
}

function M.nameKey(value)
    if type(value) ~= "string" then return nil end
    value = M.unescapeHtml(value)
    local ok_util, util = pcall(require, "util")
    if ok_util and util then
        if util.fixUtf8 then value = util.fixUtf8(value, "?") end
        if util.lower then value = util.lower(value) else value = value:lower() end
    else
        value = value:lower()
    end

    value = value:gsub("[\194-\244][\128-\191]+", function(ch)
        return _multibyte_punct[ch] or ch
    end)
    value = value:gsub("[%p]", " ")
    value = value:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
    return value ~= "" and value or nil
end

function M.nameKeysMatch(k1, k2)
    if not k1 or not k2 then return false end
    if k1 == k2 then return true end
    if k1:gsub("%s+", "") == k2:gsub("%s+", "") then return true end
    local c1 = k1:gsub("(%w) ([stmdve]|ll|re)%f[%A]", "%1%2"):gsub("(%w) ([stmdve]|ll|re)$", "%1%2")
    local c2 = k2:gsub("(%w) ([stmdve]|ll|re)%f[%A]", "%1%2"):gsub("(%w) ([stmdve]|ll|re)$", "%1%2")
    if c1 == c2 then return true end
    if c1:gsub("%s+", "") == c2:gsub("%s+", "") then return true end
    return false
end

function M.bookKey(rec)
    if type(rec) ~= "table" then return nil end
    local value = rec.title or rec.display_title
    if type(value) ~= "string" or value == "" then
        value = rec.filename or rec.name
    end
    if type(value) == "string" then
        value = value:gsub("%.%a%w%w?%w?$", "")
    end
    return M.nameKey(value)
end

local function checkLocalReadingProgress(filepath)
    if not filepath or type(filepath) ~= "string" or filepath:find("^%a+://") then
        return nil, nil
    end

    -- 1. Check in-memory BookList / BookInfo cache first
    local ok_bl, BookList = pcall(require, "ui/widget/booklist")
    local cached_info = ok_bl and BookList and BookList.book_info_cache and BookList.book_info_cache[filepath]
    if cached_info then
        local st = cached_info.status
        local pct = tonumber(cached_info.percent_finished)
        if (st == "complete" or st == "finished") or (pct and pct >= 0.99) then
            return "finished", 1.0
        elseif st == "reading" or (pct and pct > 0) then
            return "reading", pct or 0.5
        end
    end

    -- 2. Fallback to DocSettings.open if not in memory cache
    local ok_ds, DocSettings = pcall(require, "docsettings")
    if ok_ds and DocSettings and DocSettings.open then
        local ok_o, ds = pcall(DocSettings.open, DocSettings, filepath)
        if ok_o and ds and ds.readSetting then
            local summary = ds:readSetting("summary")
            local pct = tonumber(ds:readSetting("percent_finished"))
            if (summary and type(summary) == "table" and summary.status == "complete") or (pct and pct >= 0.99) then
                return "finished", 1.0
            elseif (summary and type(summary) == "table" and summary.status == "reading") or (pct and pct > 0) then
                return "reading", pct
            end
        end
    end
    return nil, nil
end

function M.extractChapterNumber(rec)
    if not rec then return nil end

    if type(rec) == "number" then return rec end
    if type(rec) == "string" then
        local n = tonumber(rec)
        if n then return n end
    end

    if type(rec) ~= "table" then return nil end

    -- 1. Direct fields
    local num = tonumber(rec.series_index or rec.series_num or rec.numberSort or rec.number)
    if num then return num end

    -- 2. Metadata table
    if type(rec.metadata) == "table" then
        local m_num = tonumber(rec.metadata.numberSort or rec.metadata.number or rec.metadata.series_index)
        if m_num then return m_num end
    end

    -- 3. Komga DTO
    if type(rec.komga_dto) == "table" then
        local k_dto = rec.komga_dto
        local k_num = tonumber(k_dto.numberSort or k_dto.number)
        if k_num then return k_num end
        if type(k_dto.metadata) == "table" then
            k_num = tonumber(k_dto.metadata.numberSort or k_dto.metadata.number)
            if k_num then return k_num end
        end
    end

    -- 4. DocSettings sidecar properties (doc_props or custom_props)
    local fp = rec.filepath or rec.path
    if fp and type(fp) == "string" and not fp:find("^%a+://") then
        local ok_ds, DocSettings = pcall(require, "docsettings")
        if ok_ds and DocSettings and DocSettings.open then
            local ok_o, ds = pcall(DocSettings.open, DocSettings, fp)
            if ok_o and ds and ds.readSetting then
                local dp = ds:readSetting("doc_props")
                if type(dp) == "table" then
                    local s_idx = tonumber(dp.series_index)
                    if s_idx then return s_idx end
                end
                local cp = ds:readSetting("custom_props")
                if type(cp) == "table" then
                    local s_idx = tonumber(cp.series_index)
                    if s_idx then return s_idx end
                end
            end
        end
    end

    -- 5. Filename / Title pattern parsing
    local str = rec.title or rec.display_title or rec.filename or rec.name
    if type(str) ~= "string" and fp and type(fp) == "string" then
        str = fp:match("([^/]+)$")
    end
    if type(str) == "string" then
        -- Remove extension (.cbz, .cbr, .epub, .pdf, etc.)
        str = str:gsub("%.%a%w%w?%w?$", "")

        -- Chapter markers: "Chapter 3", "ch. 03", "c3.5", "Ch3", "ch 3"
        local ch_str = str:match("[Cc]h[%a]*[%s_%.%-]*([%d]+%.?[%d]*)")
        if ch_str then
            local n = tonumber(ch_str)
            if n then return n end
        end

        -- Hash marker: "#03", "# 3"
        local hash_str = str:match("[#＃][%s_]*([%d]+%.?[%d]*)")
        if hash_str then
            local n = tonumber(hash_str)
            if n then return n end
        end

        -- Volume and chapter: "v01 c03", "v1 - 03", "Vol 1 Ch 3"
        local vol_ch_str = str:match("[Vv]ol?%d+[%s_%.%-]+[Cc]?(%d+%.?%d*)")
        if vol_ch_str then
            local n = tonumber(vol_ch_str)
            if n then return n end
        end

        -- " - 03", " - 3.5" (standard "Series - 03")
        local dash_num = str:match("%s+%-%s+([%d]+%.?[%d]*)")
        if dash_num then
            local n = tonumber(dash_num)
            if n then return n end
        end

        -- Trailing number: "Series Name 03", "Series 3"
        local trailing_num = str:match("[%s_]+([%d]+%.?[%d]*)%s*$")
        if trailing_num then
            local n = tonumber(trailing_num)
            if n then return n end
        end

        -- Leading number: "03 - Series", "03.cbz"
        local leading_num = str:match("^([%d]+%.?[%d]*)[%s_%.%-]+")
        if leading_num then
            local n = tonumber(leading_num)
            if n then return n end
        end

        -- Exact number only: "03"
        local exact_num = str:match("^([%d]+%.?[%d]*)$")
        if exact_num then
            local n = tonumber(exact_num)
            if n then return n end
        end
    end

    return nil
end

function M.syncLocalChapterStatus(local_rec, frontier_dto)
    if not local_rec or not frontier_dto then return false end
    local frontier_num = M.extractChapterNumber(frontier_dto)
    local local_num = M.extractChapterNumber(local_rec)

    if not frontier_num or not local_num then return false end
    if local_num >= frontier_num then return false end

    -- Local chapter is older than the active reading frontier:
    -- Update in-memory record to finished (1.0)
    local_rec.status = "finished"
    local_rec._status = "finished"
    local_rec.read_status = "finished"
    local_rec.percent_finished = 1.0
    local_rec.book_pct = 1.0
    local_rec.is_completed = true

    -- Update .sdr sidecar on disk if local file exists
    local filepath = local_rec.filepath or local_rec.path
    if filepath and type(filepath) == "string" and not filepath:find("^%a+://") then
        local ok_ds, DocSettings = pcall(require, "docsettings")
        if ok_ds and DocSettings and DocSettings.open then
            local ok_o, ds = pcall(DocSettings.open, DocSettings, filepath)
            if ok_o and ds and ds.readSetting then
                local summary = ds:readSetting("summary")
                if type(summary) ~= "table" then summary = {} end
                local current_pct = tonumber(ds:readSetting("percent_finished")) or 0
                if summary.status ~= "complete" or current_pct < 1.0 then
                    summary.status = "complete"
                    summary.modified = os.date("%Y-%m-%d")
                    if ds.saveSetting then
                        ds:saveSetting("summary", summary)
                        ds:saveSetting("percent_finished", 1.0)
                    end
                    if ds.flush then pcall(ds.flush, ds) end
                end
            end
        end

        -- Update BookList cache if available
        local ok_bl, BookList = pcall(require, "apps/filemanager/booklist")
        if ok_bl and BookList and BookList.setBookInfoCacheProperty then
            pcall(BookList.setBookInfoCacheProperty, BookList, filepath, "status", "complete")
            pcall(BookList.setBookInfoCacheProperty, BookList, filepath, "percent_finished", 1.0)
        end
    end

    return true
end

local _downloaded_map_cache = nil
local _downloaded_map_time = 0
local DOWNLOADED_MAP_TTL = 30 -- 30 seconds TTL

function M.invalidateDownloadedMap()
    _downloaded_map_cache = nil
    _downloaded_map_time = 0
end

function M.getDownloadedMap(force_refresh)
    local now = os.time()
    if not force_refresh and _downloaded_map_cache and (now - _downloaded_map_time < DOWNLOADED_MAP_TTL) then
        return _downloaded_map_cache
    end

    local downloaded = {}

    -- 1. Bookshelf's own OPDS download map
    local ok_s, Store = pcall(require, "lib/bookshelf_settings_store")
    if ok_s and Store and Store.read then
        local map = Store.read("opds_downloads")
        if type(map) == "table" then
            for filepath, local_path in pairs(map) do
                if type(filepath) == "string" and type(local_path) == "string" and local_path ~= "" then
                    downloaded[filepath] = local_path
                end
            end
        end
    end

    -- 2. Kokomga's OPDS download map
    local ok_p, PluginLoader = pcall(require, "pluginloader")
    local loaded = ok_p and PluginLoader and PluginLoader.loaded_plugins or nil
    local komga = loaded and loaded["kokomga"] or nil
    if komga and komga.getOpdsDownloadsPath then
        local ok_ls, LuaSettings = pcall(require, "luasettings")
        if ok_ls and LuaSettings then
            local ok_f, kokomga_dl = pcall(LuaSettings.open, LuaSettings, komga:getOpdsDownloadsPath())
            if ok_f and kokomga_dl then
                local downloads = kokomga_dl:readSetting("downloads")
                if type(downloads) == "table" then
                    for filepath, local_path in pairs(downloads) do
                        if type(filepath) == "string" and type(local_path) == "string" and local_path ~= "" then
                            downloaded[filepath] = local_path
                        end
                    end
                end
            end
        end
    end

    -- 3. Kokomga's matched_books_cache (contains all Kokomga auto-downloaded & matched books)
    local mbc = komga and komga.settings and type(komga.settings.matched_books_cache) == "table" and komga.settings.matched_books_cache
    if not mbc then
        local ok_ds, DataStorage = pcall(require, "datastorage")
        local ok_ls, LuaSettings = pcall(require, "luasettings")
        if ok_ds and ok_ls and DataStorage and LuaSettings then
            local ok_k, ks = pcall(LuaSettings.open, LuaSettings, DataStorage:getSettingsDir() .. "/kokomga.lua")
            if ok_k and ks and ks.readSetting then
                mbc = ks:readSetting("matched_books_cache")
            end
        end
    end
    if type(mbc) == "table" then
        local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
        for local_fp, book_id in pairs(mbc) do
            if type(local_fp) == "string" and type(book_id) == "string" and book_id ~= "" then
                local exists = not (ok_lfs and lfs and lfs.attributes) or lfs.attributes(local_fp, "mode") == "file"
                if exists then
                    local id_str = tostring(book_id)
                    downloaded["komga://book/" .. id_str] = local_fp
                    downloaded[id_str] = local_fp
                    downloaded[local_fp] = local_fp
                end
            end
        end
    end

    _downloaded_map_cache = downloaded
    _downloaded_map_time = now
    return downloaded
end

function M.mergeRecords(local_records, remote_records, frontier_dto)
    local downloaded = M.getDownloadedMap()
    local out = {}

    local local_folders, local_folders_collapsed, local_folders_list = {}, {}, {}
    local local_books, local_books_collapsed, local_books_list = {}, {}, {}
    local local_books_by_id, local_books_by_path = {}, {}

    -- 1. Add all local records (they are authoritative)
    for i = 1, #local_records do
        local rec = local_records[i]
        if rec then
            out[#out + 1] = rec
            local idx = #out
            if rec.kind == "folder" or rec.is_folder then
                rec.is_folder = true
                rec.kind = "folder"
                rec.label = rec.label or rec.title or rec.series_name or rec.name
                rec.title = rec.title or rec.label or rec.series_name or rec.name
                rec.series_name = rec.series_name or rec.label or rec.title or rec.name
                rec.display_title = rec.display_title or rec.title
                local name = M.nameKey(rec.label or rec.name or rec.title)
                if name then
                    local_folders[name] = idx
                    local_folders_collapsed[name:gsub("%s+", "")] = idx
                    local_folders_list[#local_folders_list + 1] = { name = name, idx = idx }
                end
            else
                if rec.filepath then
                    local_books_by_path[rec.filepath] = idx
                    -- Check if path maps to a komga id
                    local mapped_id = downloaded[rec.filepath]
                    if mapped_id and mapped_id ~= rec.filepath then
                        local_books_by_id[mapped_id] = idx
                        rec.komga_id = rec.komga_id or mapped_id
                    end
                end
                if rec.komga_id or rec.komga_book_id then
                    local id_str = tostring(rec.komga_id or rec.komga_book_id)
                    local_books_by_id[id_str] = idx
                    local_books_by_id["komga://book/" .. id_str] = idx
                end
                local key = M.bookKey(rec)
                if key then
                    local_books[key] = idx
                    local_books_collapsed[key:gsub("%s+", "")] = idx
                    local_books_list[#local_books_list + 1] = { key = key, idx = idx }
                end
                -- Update local reading progress if not already completed by database query
                if rec.filepath then
                    local already_finished = (rec.status == "complete" or rec.status == "finished")
                        or (rec.percent_finished and rec.percent_finished >= 0.99)
                    if not already_finished then
                        local local_st, local_pct = checkLocalReadingProgress(rec.filepath)
                        if local_st == "finished" then
                            rec.status = "finished"
                            rec._status = "finished"
                            rec.read_status = "finished"
                            rec.percent_finished = 1.0
                            rec.book_pct = 1.0
                            rec.is_completed = true
                        elseif local_st == "reading" and (not rec.percent_finished or rec.percent_finished == 0) then
                            rec.status = "reading"
                            rec._status = "reading"
                            rec.read_status = "reading"
                            rec.percent_finished = local_pct
                            rec.book_pct = local_pct
                        end
                    end
                end
            end
        end
    end

    -- 2. Merge remote records, filtering out duplicates
    local seen_remote = {}
    for i = 1, #remote_records do
        local rec = remote_records[i]
        if rec then
            if rec.kind == "folder" or rec.is_folder or rec.is_opds_nav then
                rec.label = rec.label or rec.title or rec.series_name or rec.name
                rec.title = rec.title or rec.label or rec.series_name or rec.name
                rec.series_name = rec.series_name or rec.label or rec.title or rec.name
                rec.display_title = rec.display_title or rec.title
            end
            local kid = rec.komga_book_id or rec.komga_id or rec.id
            local kid_str = kid and tostring(kid) or nil
            local rec_key = rec.filepath or (kid_str and ("komga://book/" .. kid_str))
            local downloaded_path = (rec_key and downloaded[rec_key])
                or (kid_str and (downloaded["komga://book/" .. kid_str] or downloaded[kid_str]))
                or (rec.filepath and downloaded[rec.filepath])
            local downloaded_here = downloaded_path ~= nil

            local duplicate_local_folder = false
            if rec.is_folder or rec.is_opds_nav or rec.kind == "folder" then
                local remote_name = M.nameKey(rec.label or rec.name or rec.title)
                local matched_idx = nil
                if remote_name then
                    matched_idx = local_folders[remote_name] or local_folders_collapsed[remote_name:gsub("%s+", "")]
                    if not matched_idx and #local_folders_list <= 100 then
                        for j = 1, #local_folders_list do
                            if M.nameKeysMatch(remote_name, local_folders_list[j].name) then
                                matched_idx = local_folders_list[j].idx
                                break
                            end
                        end
                    end
                end

                if matched_idx then
                    duplicate_local_folder = true
                    local local_folder = out[matched_idx]
                    local_folder.is_hybrid_folder = true
                    local_folder.is_folder = true
                    local_folder.kind = "folder"
                    local_folder.source_kind = "hybrid"
                    local_folder.label = local_folder.label or local_folder.title or local_folder.series_name or local_folder.name or rec.label or rec.title
                    local_folder.title = local_folder.title or local_folder.label or local_folder.series_name or local_folder.name or rec.title
                    local_folder.series_name = local_folder.series_name or local_folder.label or local_folder.title or rec.series_name
                    local_folder.display_title = local_folder.display_title or local_folder.title
                    local_folder.komga_series_id = rec.komga_series_id or rec.komga_id or rec.id
                    local_folder.server_key = rec.server_key
                    if not local_folder.cover_image_path and rec.cover_image_path then
                        local_folder.cover_image_path = rec.cover_image_path
                        local_folder.has_cover = true
                        if local_folder.first_book then
                            local_folder.first_book.cover_image_path = rec.cover_image_path
                            local_folder.first_book.has_cover = true
                        end
                    end
                    if not local_folder.first_book and rec.first_book then
                        local_folder.first_book = rec.first_book
                    end
                    if rec.active_book then
                        local_folder.active_book = rec.active_book
                    end
                end
            end

            local duplicate_local_book = false
            local matched_book_idx = nil
            if not (rec.is_folder or rec.is_opds_nav or rec.kind == "folder") then
                -- Try matching by komga_id
                if kid_str and local_books_by_id[kid_str] then
                    matched_book_idx = local_books_by_id[kid_str]
                elseif kid_str and local_books_by_id["komga://book/" .. kid_str] then
                    matched_book_idx = local_books_by_id["komga://book/" .. kid_str]
                -- Try matching by downloaded filepath
                elseif downloaded_path and local_books_by_path[downloaded_path] then
                    matched_book_idx = local_books_by_path[downloaded_path]
                end

                -- Fallback to name matching
                if not matched_book_idx then
                    local remote_book_key = M.bookKey(rec)
                    if remote_book_key then
                        matched_book_idx = local_books[remote_book_key]
                            or local_books_collapsed[remote_book_key:gsub("%s+", "")]
                        if not matched_book_idx and #local_books_list <= 100 then
                            for j = 1, #local_books_list do
                                if M.nameKeysMatch(remote_book_key, local_books_list[j].key) then
                                    matched_book_idx = local_books_list[j].idx
                                    break
                                end
                            end
                        end
                    end
                end

                if matched_book_idx then
                    duplicate_local_book = true
                    local local_book = out[matched_book_idx]
                    if local_book then
                        local_book.komga_id = local_book.komga_id or rec.komga_id or kid_str
                        local_book.komga_book_id = local_book.komga_book_id or rec.komga_book_id or kid_str
                        local_book.komga_series_id = local_book.komga_series_id or rec.komga_series_id
                        local_book.series_num = local_book.series_num or rec.series_num
                        local_book.komga_dto = local_book.komga_dto or rec.komga_dto
                        local_book.is_komga = true
                        local_book.downloaded = true
                        local_book.is_remote = false
                        if not local_book.format and rec.format then
                            local_book.format = rec.format
                        end
                        if not local_book.cover_image_path and rec.cover_image_path then
                            local_book.cover_image_path = rec.cover_image_path
                            local_book.has_cover = true
                        end
                        -- If remote shows finished, mark local as finished and sync .sdr sidecar
                        local remote_finished = (rec.status == "finished" or rec.read_status == "finished" or rec.percent_finished == 1.0
                            or (rec.komga_dto and rec.komga_dto.readProgress and rec.komga_dto.readProgress.completed))
                        if remote_finished then
                            local_book.status = "finished"
                            local_book._status = "finished"
                            local_book.read_status = "finished"
                            local_book.percent_finished = 1.0
                            local_book.book_pct = 1.0
                            local_book.is_completed = true

                            local fp = local_book.filepath or local_book.path
                            if fp and type(fp) == "string" and not fp:find("^%a+://") then
                                local ok_ds, DocSettings = pcall(require, "docsettings")
                                if ok_ds and DocSettings and DocSettings.open then
                                    local ok_o, ds = pcall(DocSettings.open, DocSettings, fp)
                                    if ok_o and ds and ds.readSetting then
                                        local summary = ds:readSetting("summary")
                                        if type(summary) ~= "table" then summary = {} end
                                        local current_pct = tonumber(ds:readSetting("percent_finished")) or 0
                                        if summary.status ~= "complete" or current_pct < 1.0 then
                                            summary.status = "complete"
                                            summary.modified = os.date("%Y-%m-%d")
                                            if ds.saveSetting then
                                                ds:saveSetting("summary", summary)
                                                ds:saveSetting("percent_finished", 1.0)
                                            end
                                            if ds.flush then pcall(ds.flush, ds) end
                                        end
                                    end
                                end
                                local ok_bl, BookList = pcall(require, "apps/filemanager/booklist")
                                if ok_bl and BookList and BookList.setBookInfoCacheProperty then
                                    pcall(BookList.setBookInfoCacheProperty, BookList, fp, "status", "complete")
                                    pcall(BookList.setBookInfoCacheProperty, BookList, fp, "percent_finished", 1.0)
                                end
                            end
                        end
                    end
                end
            end

            local duplicate_remote = (rec_key and seen_remote[rec_key])
                or (kid_str and seen_remote[kid_str])
                or false

            if not duplicate_local_folder and not duplicate_local_book and not duplicate_remote then
                if downloaded_here and downloaded_path then
                    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
                    if not (ok_lfs and lfs and lfs.attributes) or lfs.attributes(downloaded_path, "mode") == "file" then
                        rec.filepath = downloaded_path
                        rec.downloaded = true
                        rec.is_remote = false

                        -- Check local reading status on the downloaded file
                        local local_st, local_pct = checkLocalReadingProgress(downloaded_path)
                        if local_st == "finished" then
                            rec.status = "finished"
                            rec._status = "finished"
                            rec.read_status = "finished"
                            rec.percent_finished = 1.0
                            rec.book_pct = 1.0
                            rec.is_completed = true
                        elseif local_st == "reading" and (not rec.percent_finished or rec.percent_finished == 0) then
                            rec.status = "reading"
                            rec._status = "reading"
                            rec.read_status = "reading"
                            rec.percent_finished = local_pct
                            rec.book_pct = local_pct
                        end
                    end
                end
                out[#out + 1] = rec
            end

            if rec_key then seen_remote[rec_key] = true end
            if kid_str then
                seen_remote[kid_str] = true
            end
        end
    end

    -- Read-Ahead Status Alignment against frontier DTO
    local active_frontier = frontier_dto
    if not active_frontier and remote_records and #remote_records > 0 then
        if remote_records[1] and remote_records[1].active_book then
            active_frontier = remote_records[1].active_book
        elseif #remote_records == 1 and not (remote_records[1].is_folder or remote_records[1].kind == "folder") then
            active_frontier = remote_records[1]
        elseif #remote_records > 1 then
            local highest_in_progress = nil
            local highest_ip_num = -1
            for _, r in ipairs(remote_records) do
                if not (r.is_folder or r.kind == "folder") then
                    local is_reading = (r.status == "reading" or r.read_status == "reading")
                        or (r.percent_finished and r.percent_finished > 0 and r.percent_finished < 1)
                        or (r.komga_dto and r.komga_dto.readProgress and not r.komga_dto.readProgress.completed and (r.komga_dto.readProgress.page or 0) > 0)
                    if is_reading then
                        local n = M.extractChapterNumber(r) or -1
                        if n > highest_ip_num then
                            highest_ip_num = n
                            highest_in_progress = r
                        end
                    end
                end
            end
            if highest_in_progress then
                active_frontier = highest_in_progress
            end
        end
    end

    if active_frontier then
        for i = 1, #out do
            local item = out[i]
            if item and not (item.is_folder or item.kind == "folder" or item.is_series) then
                M.syncLocalChapterStatus(item, active_frontier)
            end
        end
    end

    -- 3. Post-pass: Enrich any local folders or books that didn't match remote records
    local ok_rem, Remote = pcall(require, "lib/hybrid_remote")
    for i = 1, #out do
        local rec = out[i]
        if rec then
            if rec.is_folder or rec.kind == "folder" then
                if not rec.komga_series_id and ok_rem and Remote and Remote.lookupSeriesIdByTitle then
                    rec.komga_series_id = Remote.lookupSeriesIdByTitle(rec.title or rec.label or rec.series_name)
                end
                if not rec.cover_image_path and ok_rem and Remote and Remote.getKomgaCoverPath then
                    local cp = Remote.getKomgaCoverPath("series", rec.komga_series_id, rec.title or rec.label or rec.series_name)
                    if not cp and rec.active_book and rec.active_book.id then
                        cp = Remote.getKomgaCoverPath("book", rec.active_book.id, rec.active_book.name, rec.komga_series_id)
                    end
                    if cp then
                        rec.cover_image_path = cp
                        rec.has_cover = true
                        if rec.first_book then
                            rec.first_book.cover_image_path = cp
                            rec.first_book.has_cover = true
                        else
                            rec.first_book = {
                                filepath = rec.path or rec.filepath,
                                cover_image_path = cp,
                                title = rec.title or rec.label,
                                has_cover = true,
                            }
                        end
                    end
                end
            elseif not rec.is_folder and rec.kind ~= "folder" then
                if (rec.downloaded or (rec.filepath and not rec.filepath:find("^%a+://"))) and not rec.has_cover then
                    rec.has_cover = true
                end
            end
        end
    end

    for i = 1, #out do
        local rec = out[i]
        if not rec.page_count or rec.page_count <= 0 then
            rec.page_count = (rec.komga_dto and rec.komga_dto.media and rec.komga_dto.media.pagesCount and rec.komga_dto.media.pagesCount > 0 and rec.komga_dto.media.pagesCount)
                or (rec.active_book and rec.active_book.media and rec.active_book.media.pagesCount and rec.active_book.media.pagesCount > 0 and rec.active_book.media.pagesCount)
                or 200
        end
        if rec.first_book and (not rec.first_book.page_count or rec.first_book.page_count <= 0) then
            rec.first_book.page_count = rec.page_count
        end
    end

    return out
end

return M
