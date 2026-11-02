-- lib/hybrid_spec.lua
-- Bookshelf SOURCE_API 1 specification for Hybrid shelves.

local logger = require("logger")
local UIManager = require("ui/uimanager")
local ButtonDialog = require("ui/widget/buttondialog")
local FileChooser = require("ui/widget/filechooser")
local Notification = require("ui/widget/notification")
local _ = require("gettext")

local Dedup = require("lib/hybrid_dedup")
local Remote = require("lib/hybrid_remote")

local M = {}

local _series_folder_cache = {}
local _active_series_cache = {}

function M.clearSeriesCache()
    _series_folder_cache = {}
    _active_series_cache = {}
end
M.clearSeriesFolderCache = M.clearSeriesCache

function M.clearCachesForSeries(sid_str, title_key)
    if not sid_str and not title_key then
        M.clearSeriesCache()
        return
    end
    for k in pairs(_active_series_cache) do
        local ks = tostring(k):lower()
        if (sid_str and ks:find(sid_str:lower(), 1, true)) or (title_key and ks:find(title_key:lower(), 1, true)) then
            _active_series_cache[k] = nil
        end
    end
    for k in pairs(_series_folder_cache) do
        local ks = tostring(k):lower()
        if (sid_str and ks:find(sid_str:lower(), 1, true)) or (title_key and ks:find(title_key:lower(), 1, true)) then
            _series_folder_cache[k] = nil
        end
    end
end

local function debugLog(msg)
    pcall(function()
        local f = io.open("/sdcard/koreader/hybrid_debug.log", "a")
        if f then
            f:write(os.date("%Y-%m-%d %H:%M:%S") .. " " .. tostring(msg) .. "\n")
            f:close()
        end
    end)
end

local function liveModule(name)
    for _, mod in ipairs({ "apps/filemanager/filemanager", "apps/reader/readerui" }) do
        local ok, m = pcall(require, mod)
        local found = ok and m and m.instance and m.instance[name]
        if found then return found end
    end
end

local function getKomgaPlugin()
    local ok_p, PluginLoader = pcall(require, "pluginloader")
    local loaded = ok_p and PluginLoader and PluginLoader.loaded_plugins or nil
    return loaded and loaded["kokomga"] or liveModule("kokomga")
end

local function getBridgePlugin()
    local ok_p, PluginLoader = pcall(require, "pluginloader")
    local loaded = ok_p and PluginLoader and PluginLoader.loaded_plugins or nil
    return loaded and loaded["kokomga_bookshelf_bridge"] or liveModule("kokomga_bookshelf_bridge")
end

-- ---------------------------------------------------------------------------
-- Shelf Source Specification
-- ---------------------------------------------------------------------------

local SPEC = {
    api = 1,
    label = function() return _("Hybrid") end,
    available = function() return true end,
    remote_prefix = "komga://",
    sort_default = { { key = "filename", reverse = false } },

    pick = function(draft, done)
        local prev = draft.source or {}
        draft.source = { kind = "hybrid" }

        if prev.kind == "komga" then
            draft.source.remote_kind = "komga"
            draft.source.library_id = prev.library_id
            draft.source.library_names = prev.library_names
            draft.source.library_name = prev.library_name
            draft.source.list = prev.list
        elseif prev.kind == "opds" then
            draft.source.remote_kind = "opds"
            draft.source.opds_id = prev.id
            draft.source.feed_url = prev.feed_url
            draft.source.feed_label = prev.feed_label
        elseif prev.kind == "folder" or prev.kind == "folder_flat" then
            draft.source.remote_kind = "komga"
            draft.source.local_folder = prev.id
        else
            draft.source.remote_kind = prev.remote_kind or "komga"
            draft.source.library_id = prev.library_id
            draft.source.library_name = prev.library_name
            draft.source.local_folder = prev.local_folder
        end
        draft.source.remote_mode = prev.remote_mode or "all"

        if not draft.label or draft.label == "" or draft.label == _("New shelf") or draft.label == "New chip" then
            draft.label = _("Hybrid")
        end

        logger.info("[Hybrid] Picked hybrid shelf source, remote:", tostring(draft.source.remote_kind))
        done()
    end,

    editor_rows = function(draft)
        local rows = {}
        local src = draft.source or {}
        local ok_ffi, ffiutil = pcall(require, "ffi/util")
        local T = (ok_ffi and ffiutil and ffiutil.template) or function(str, ...)
            local args = { ... }
            return (str:gsub("%%(%d+)", function(n) return tostring(args[tonumber(n)] or "") end))
        end

        local DEFAULT_REVERSE = {
            date_added   = true,
            last_read    = true,
            file_mtime   = true,
            book_count   = true,
            finished_pct = true,
            progress     = true,
            rating       = true,
        }

        local function isDefaultDirection(key, reverse)
            return (DEFAULT_REVERSE[key] == true) == (reverse == true)
        end

        local function sortButtonText(d, level_index)
            local sp = d.sort_priority or (d.source and d.source.sort_priority)
            local lv = sp and sp[level_index]
            if not lv or not lv.key then
                return level_index .. _(": (none)")
            end
            local ok_se, SortEngine = pcall(require, "lib/bookshelf_sort_engine")
            local k = ok_se and SortEngine and SortEngine.KEYS and SortEngine.KEYS[lv.key]
            local lbl = (k and (k.short or k.label)) or lv.key
            if not isDefaultDirection(lv.key, lv.reverse) then
                lbl = lbl .. " " .. "\xE2\x86\x91"
            end
            return level_index .. ": " .. lbl
        end

        -- Row 1: Sort Priority Levels 1, 2, 3 (3 buttons, matching local shelf)
        rows[#rows + 1] = {
            {
                text = function(d) return sortButtonText(d, 1) end,
                callback = function(d, done)
                    local ok_ed, Editor = pcall(require, "lib/bookshelf_chip_editor")
                    if ok_ed and Editor and Editor._pickSortLevel then
                        Editor:_pickSortLevel(d, 1, function()
                            if d.source then d.source.sort_priority = d.sort_priority end
                            done()
                        end)
                    else
                        done()
                    end
                end,
            },
            {
                text = function(d) return sortButtonText(d, 2) end,
                callback = function(d, done)
                    local ok_ed, Editor = pcall(require, "lib/bookshelf_chip_editor")
                    if ok_ed and Editor and Editor._pickSortLevel then
                        Editor:_pickSortLevel(d, 2, function()
                            if d.source then d.source.sort_priority = d.sort_priority end
                            done()
                        end)
                    else
                        done()
                    end
                end,
            },
            {
                text = function(d) return sortButtonText(d, 3) end,
                callback = function(d, done)
                    local ok_ed, Editor = pcall(require, "lib/bookshelf_chip_editor")
                    if ok_ed and Editor and Editor._pickSortLevel then
                        Editor:_pickSortLevel(d, 3, function()
                            if d.source then d.source.sort_priority = d.sort_priority end
                            done()
                        end)
                    else
                        done()
                    end
                end,
            },
        }

        -- Row 2: Local Filters, Local Folder Picker, Remote Provider Toggle (3 buttons)
        rows[#rows + 1] = {
            {
                text = function(d)
                    local ok_f, Filter = pcall(require, "lib/bookshelf_filter")
                    local f = d.filter or (d.source and d.source.filter) or {}
                    local summary = ok_f and Filter and Filter.summary and Filter.summary(f) or _("none")
                    return _("Filters: ") .. summary
                end,
                callback = function(d, done)
                    local ok_ed, Editor = pcall(require, "lib/bookshelf_chip_editor")
                    if ok_ed and Editor and Editor._openFilters then
                        Editor:_openFilters(d, function()
                            if d.source then d.source.filter = d.filter end
                            done()
                        end)
                    else
                        done()
                    end
                end,
            },
            {
                text = function(d)
                    local p = d.source and d.source.local_folder
                    local name = p and (p:match("([^/]+)/?$") or p) or _("All Library")
                    return _("Local: ") .. name
                end,
                callback = function(d, done)
                    local DataStorage = require("datastorage")
                    local root_dir = DataStorage:getDataDir()
                    local fc = nil
                    fc = FileChooser:new{
                        title = _("Select Local Folder (or Cancel for All)"),
                        path = (d.source and d.source.local_folder) or root_dir,
                        select_directory = true,
                        callback = function(chosen_dir)
                            UIManager:close(fc)
                            if chosen_dir and chosen_dir ~= "" then
                                d.source.local_folder = chosen_dir
                            else
                                d.source.local_folder = nil
                            end
                            done()
                        end,
                    }
                    UIManager:show(fc)
                end,
            },
            {
                text = function(d)
                    return (d.source and d.source.remote_kind == "opds") and _("Remote: OPDS") or _("Remote: Komga")
                end,
                callback = function(d, done)
                    if d.source.remote_kind == "opds" then
                        d.source.remote_kind = "komga"
                    else
                        d.source.remote_kind = "opds"
                    end
                    done()
                end,
            },
        }

        -- Row 3: Remote Target Picker, Switch Network, Convert Back Toggle (3 buttons)
        local row3 = {
            {
                text = function(d)
                    local s = d.source or {}
                    if s.remote_kind == "opds" then
                        return s.feed_label or _("OPDS Feed…")
                    else
                        return s.library_name and T(_("Library: %1"), s.library_name) or _("All Libraries")
                    end
                end,
                callback = function(d, done)
                    if d.source.remote_kind == "opds" then
                        local ok_c, Catalogs = pcall(require, "lib/bookshelf_opds_catalogs")
                        local list = ok_c and Catalogs and Catalogs.list and Catalogs.list() or {}
                        if #list == 0 then
                            UIManager:show(Notification:new{ text = _("No OPDS catalogs configured.") })
                            return
                        end
                        local cat_buttons = {}
                        local cat_dialog = nil
                        for _, cat in ipairs(list) do
                            local c = cat
                            cat_buttons[#cat_buttons + 1] = {
                                {
                                    text = c.title or c.url,
                                    callback = function()
                                        if cat_dialog then UIManager:close(cat_dialog) end
                                        d.source.feed_url = c.url
                                        d.source.feed_label = c.title
                                        local ok_s, OpdsSource = pcall(require, "lib/bookshelf_opds_source")
                                        d.source.opds_id = (ok_s and OpdsSource and OpdsSource.serverKey) and OpdsSource.serverKey(c.url) or "komga"
                                        done()
                                    end,
                                },
                            }
                        end
                        cat_buttons[#cat_buttons + 1] = {
                            { text = _("Cancel"), callback = function() if cat_dialog then UIManager:close(cat_dialog) end end },
                        }
                        cat_dialog = ButtonDialog:new{ title = _("Select OPDS Catalog"), buttons = cat_buttons }
                        UIManager:show(cat_dialog)
                    else
                        local komga = getKomgaPlugin()
                        local komga_libraries = nil
                        if komga and komga.api then
                            local ok_l, res = pcall(komga.api.get_libraries, komga.api)
                            if ok_l and type(res) == "table" then komga_libraries = res end
                        end
                        local lib_dialog = nil
                        local lib_buttons = {
                            {
                                {
                                    text = _("All Libraries"),
                                    callback = function()
                                        if lib_dialog then UIManager:close(lib_dialog) end
                                        d.source.library_id = nil
                                        d.source.library_name = nil
                                        d.source.library_names = nil
                                        done()
                                    end,
                                },
                            },
                        }
                        if komga_libraries then
                            for _, lib in ipairs(komga_libraries) do
                                local l = lib
                                lib_buttons[#lib_buttons + 1] = {
                                    {
                                        text = l.name or l.id,
                                        callback = function()
                                            if lib_dialog then UIManager:close(lib_dialog) end
                                            d.source.library_id = { l.id }
                                            d.source.library_name = l.name
                                            d.source.library_names = { [l.id] = l.name }
                                            done()
                                        end,
                                    },
                                }
                            end
                        end
                        lib_buttons[#lib_buttons + 1] = {
                            { text = _("Cancel"), callback = function() if lib_dialog then UIManager:close(lib_dialog) end end },
                        }
                        lib_dialog = ButtonDialog:new{ title = _("Select Komga Library"), buttons = lib_buttons }
                        UIManager:show(lib_dialog)
                    end
                end,
            },
        }

        local bridge = getBridgePlugin()
        if bridge and bridge.showNetworkProfilesDialog then
            row3[#row3 + 1] = {
                text = _("Switch Network…"),
                callback = function(d, done)
                    bridge.showNetworkProfilesDialog(function()
                        done()
                    end)
                end,
            }
        end

        row3[#row3 + 1] = {
            text = function(d)
                return (d.source and d.source.remote_kind == "opds") and _("OPDS only") or _("Komga only")
            end,
            callback = function(d, done)
                if d.source.remote_kind == "opds" then
                    d.source.kind = "opds"
                    d.source.id = d.source.opds_id or d.source.id
                else
                    d.source.kind = "komga"
                end
                d.source.remote_kind = nil
                d.source.local_folder = nil
                done()
            end,
        }

        rows[#rows + 1] = row3

        -- Row 4: Remote Content (All Series & Chapters vs Next Book)
        rows[#rows + 1] = {
            {
                text = function(d)
                    local s = d.source or {}
                    if s.remote_mode == "next_book" then
                        return _("Remote Content: Next Book")
                    else
                        return _("Remote Content: All Chapters")
                    end
                end,
                callback = function(d, done)
                    local s = d.source or {}
                    if s.remote_mode == "next_book" then
                        s.remote_mode = "all"
                    else
                        s.remote_mode = "next_book"
                    end
                    done()
                end,
            },
        }

        return rows
    end,

    fetch = function(source, drill, offset, limit)
        drill = drill or (source and source.drill)
        debugLog(string.format("[FETCH ENTER] drill=%s id=%s label=%s off=%s lim=%s",
            tostring(drill and drill.kind),
            tostring(drill and (drill.series_id or drill.path or drill.feed_url)),
            tostring(drill and drill.label),
            tostring(offset),
            tostring(limit)))

        local is_komga_series = drill and (drill.kind == "komga_series" or drill.kind == "series" or drill.series_id ~= nil or drill.komga_series_id ~= nil or (type(drill.path) == "string" and drill.path:find("^komga://series/")))
        local is_opds_series = drill and (drill.kind == "opds_nav" or drill.feed_url)

        if not drill then
            _active_series_cache = {}
        end

        local series_cache_key = (is_komga_series or is_opds_series) and tostring(drill.series_id or drill.komga_series_id or drill.path or drill.label or "")
        local merged = nil
        if series_cache_key and series_cache_key ~= "" and _active_series_cache[series_cache_key] and (os.time() - _active_series_cache[series_cache_key].timestamp < 60) then
            merged = _active_series_cache[series_cache_key].books
        end

        if not merged then
            local folder_path
            if drill and type(drill.path) == "string" and drill.path:find("^/") then
                folder_path = drill.path
            elseif (is_komga_series or is_opds_series) and drill and drill.label then
            local cache_key = tostring(drill.series_id or drill.label)
            local cached_entry = _series_folder_cache and _series_folder_cache[cache_key]
            local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
            if cached_entry and cached_entry.path then
                if not (ok_lfs and lfs and lfs.attributes) or lfs.attributes(cached_entry.path, "mode") == "directory" then
                    folder_path = cached_entry.path
                end
            elseif cached_entry and cached_entry.path == false and (os.time() - (cached_entry.time or 0) < 30) then
                folder_path = nil
            end

            if not folder_path then
                local ok_fp, fp_err = pcall(function()
                    local base_dirs = {}
                    local function add_base(dir)
                        if dir and type(dir) == "string" and dir ~= "" then
                            local clean = dir:gsub("/+$", "")
                            for _, b in ipairs(base_dirs) do
                                if b == clean then return end
                            end
                            base_dirs[#base_dirs + 1] = clean
                        end
                    end

                    add_base(source.local_folder)

                    -- Kokomga download dir
                    local komga = getKomgaPlugin()
                    local komga_dl = komga and komga.getDownloadDir and komga:getDownloadDir()
                    if not komga_dl then
                        local ok_ds, DataStorage = pcall(require, "datastorage")
                        local ok_ls, LuaSettings = pcall(require, "luasettings")
                        if ok_ds and ok_ls and DataStorage and LuaSettings then
                            local ok_k, ks = pcall(LuaSettings.open, LuaSettings, DataStorage:getSettingsDir() .. "/kokomga.lua")
                            if ok_k and ks and ks.readSetting then
                                komga_dl = ks:readSetting("download_dir")
                            end
                        end
                    end
                    add_base(komga_dl)

                    local ok_hd, HomeDir = pcall(require, "lib/bookshelf_home_dir")
                    add_base(ok_hd and HomeDir and HomeDir.get and HomeDir.get())
                    add_base(G_reader_settings and G_reader_settings:readSetting("home_dir"))

                    local series_label = drill.label or ""
                    if #base_dirs > 0 and series_label ~= "" and ok_lfs and lfs and lfs.attributes then
                        local sanitized_label = series_label:gsub('[/%\\%:%*%?%"%<%>%|]', '_')
                        local title_key = Dedup.nameKey(series_label)

                        for _, base_path in ipairs(base_dirs) do
                            -- 1. Direct label
                            local direct = base_path .. "/" .. series_label
                            if lfs.attributes(direct, "mode") == "directory" then
                                folder_path = direct
                                break
                            end

                            -- 2. Kokomga sanitized label
                            if sanitized_label ~= series_label then
                                local sanitized_path = base_path .. "/" .. sanitized_label
                                if lfs.attributes(sanitized_path, "mode") == "directory" then
                                    folder_path = sanitized_path
                                    break
                                end
                            end

                            -- 3. Fuzzy directory scan
                            if title_key and lfs.dir then
                                local ok_d, iter = pcall(lfs.dir, base_path)
                                if ok_d and iter then
                                    for entry in iter do
                                        if entry ~= "." and entry ~= ".." then
                                            local full = base_path .. "/" .. entry
                                            if lfs.attributes(full, "mode") == "directory" then
                                                if Dedup.nameKeysMatch(Dedup.nameKey(entry), title_key) then
                                                    folder_path = full
                                                    break
                                                end
                                            end
                                        end
                                    end
                                end
                            end

                            if folder_path then break end
                        end
                    end
                end)

                if _series_folder_cache then
                    _series_folder_cache[cache_key] = { path = folder_path or false, time = os.time() }
                end
            end
        elseif drill and drill.kind == "folder" then
            folder_path = drill.path or source.local_folder
        else
            folder_path = source.local_folder
        end

        local ok_r, Repo = pcall(require, "lib/bookshelf_book_repository")
        if not (ok_r and Repo and Repo.getAll) then return {}, 0 end

        -- Resolve remote_mode, filter, and sort priority from source, falling back to TabModel tab
        local filter = source.filter
        local sort_priority = source.sort_priority
        if source.remote_mode == nil or not filter or not sort_priority then
            local ok_tm, TabModel = pcall(require, "lib/bookshelf_tab_model")
            if ok_tm and TabModel and TabModel.load then
                local live_chip = nil
                for _, mod in ipairs({ "apps/filemanager/filemanager", "apps/reader/readerui" }) do
                    local ok_m, m = pcall(require, mod)
                    local bw = ok_m and m and m.instance and m.instance.bookshelf
                    if bw and bw.chip then live_chip = bw.chip; break end
                end

                local function same_lib(l1, l2)
                    if l1 == l2 then return true end
                    if type(l1) == "table" and type(l2) == "table" then
                        return l1[1] and l1[1] == l2[1]
                    end
                    if type(l1) == "table" and type(l2) == "string" then
                        return l1[1] == l2
                    end
                    if type(l1) == "string" and type(l2) == "table" then
                        return l1 == l2[1]
                    end
                    return false
                end

                for _, t in ipairs(TabModel.load()) do
                    if t.source and t.source.kind == "hybrid" then
                        local is_match = false
                        if live_chip and t.id == live_chip then
                            is_match = true
                        elseif t.source == source then
                            is_match = true
                        elseif source.library_id and t.source.library_id and same_lib(source.library_id, t.source.library_id) then
                            is_match = true
                        elseif not source.library_id and not t.source.library_id and t.source.local_folder == source.local_folder then
                            is_match = true
                        end

                        if is_match then
                            filter = filter or t.filter
                            sort_priority = sort_priority or t.sort_priority
                            if source.remote_mode == nil and t.source.remote_mode ~= nil then
                                source.remote_mode = t.source.remote_mode
                            end
                        end
                    end
                end
            end
        end
        if source.remote_mode == nil then
            source.remote_mode = "all"
        end
        filter = filter or {}
        sort_priority = sort_priority or { { key = "filename", reverse = false } }

        -- 1. Fetch local records
        local local_books = {}
        if is_komga_series or is_opds_series then
            if folder_path then
                local_books = Repo.getAll(
                    folder_path,
                    1000000,
                    0,
                    sort_priority,
                    nil
                ) or {}
            end
        else
            local_books = Repo.getAll(
                folder_path,
                1000000,
                0,
                sort_priority,
                filter
            ) or {}
        end

        -- Apply filter to local books if active at the top level
        local ok_flt, Filter = pcall(require, "lib/bookshelf_filter")
        if not (is_komga_series or is_opds_series) and ok_flt and Filter and Filter.isActive and Filter.isActive(filter) then
            local compiled = Filter.compile(filter, Repo.filterOpts and Repo.filterOpts() or {})
            local filtered_local = {}
            for i = 1, #local_books do
                if Filter.matches(local_books[i], compiled) then
                    filtered_local[#filtered_local + 1] = local_books[i]
                end
            end
            local_books = filtered_local
        end

        -- Detect if Spines shelf mode is active
        local is_spine = (Repo and Repo.spine_light == true)
        if not is_spine then
            for _, mod in ipairs({ "apps/filemanager/filemanager", "apps/reader/readerui" }) do
                local ok_m, m = pcall(require, mod)
                local bw = ok_m and m and m.instance and m.instance.bookshelf
                if bw and bw._isSpineMode and bw:_isSpineMode() then
                    is_spine = true
                    break
                end
            end
        end

        -- 2. Fetch all remote records
        local remote_books
        if is_komga_series or is_opds_series then
            remote_books = Remote.fetchRemote(source, nil, drill, is_spine)
        else
            remote_books = Remote.fetchRemote(source, folder_path, drill, false)
        end
        remote_books = remote_books or {}

        -- Apply filter to remote records if active at the top level
        if not (is_komga_series or is_opds_series) and ok_flt and Filter and Filter.isActive and Filter.isActive(filter) then
            local compiled = Filter.compile(filter, Repo.filterOpts and Repo.filterOpts() or {})
            local filtered_remote = {}
            for i = 1, #remote_books do
                local r = remote_books[i]
                if r.is_folder or r.is_opds_nav or Filter.matches(r, compiled) then
                    filtered_remote[#filtered_remote + 1] = r
                end
            end
            remote_books = filtered_remote
        end

        -- 3. Merge and deduplicate
        if (is_komga_series or is_opds_series) and #local_books == 0 then
            merged = remote_books
        else
            merged = Dedup.mergeRecords(local_books, remote_books)
        end

        -- Ghost series detection: if drilled into a series with 0 local books and 0 remote books while online
        if is_komga_series and #local_books == 0 and #remote_books == 0 and drill then
            local sid = drill.series_id or drill.komga_series_id
            local s_label = drill.label or drill.title
            local ok_bh, BridgeHealth = pcall(require, "lib/bridge_health")
            local reachable = (not ok_bh or not BridgeHealth or not BridgeHealth.isServerReachable or BridgeHealth.isServerReachable())
            if sid and reachable then
                logger.warn(string.format("[Hybrid] fetch: Series %s (%s) has 0 local and 0 remote books while online; purging from cache",
                    tostring(sid), tostring(s_label)))
                if Remote and Remote.purgeDeletedSeries then
                    Remote.purgeDeletedSeries(sid, s_label)
                end
                local ok_ui, UIManager = pcall(require, "ui/uimanager")
                local ok_notif, Notification = pcall(require, "ui/widget/notification")
                if ok_ui and UIManager and ok_notif and Notification then
                    UIManager:show(Notification:new{ text = _("Series no longer exists on Komga; returning to shelf.") })
                end
                -- Auto-eject: pop back to root shelf if currently drilled in
                for _, mod in ipairs({ "apps/filemanager/filemanager", "apps/reader/readerui" }) do
                    local ok_m, m = pcall(require, mod)
                    local bw = ok_m and m and m.instance and m.instance.bookshelf
                    if bw and bw._drilldown_path and #bw._drilldown_path > 0 then
                        bw:_drillBackTo(0)
                        break
                    end
                end
            end
        end

        debugLog(string.format("[FETCH] drill=%s label=%s local=%d remote=%d merged=%d off=%s lim=%s",
            tostring(drill and drill.kind),
            tostring(drill and drill.label),
            #local_books,
            #remote_books,
            #merged,
            tostring(offset),
            tostring(limit)
        ))

        -- Spine shelf mode: flatten series groups into individual book records
        if is_spine then
            if is_komga_series or is_opds_series then
                local sec_label = drill.label or drill.title
                for i = 1, #merged do
                    local b = merged[i]
                    b.shelf_section = b.shelf_section or sec_label
                    b.shelf_section_path = b.shelf_section_path or drill.path
                    b.page_count = (b.page_count and b.page_count > 0 and b.page_count) or 200
                end
            else
                local spine_books = {}
                local seen_spine_keys = {}
                local function spineKey(b)
                    if not b then return nil end
                    if b.filepath and b.filepath ~= "" then return b.filepath end
                    if b.path and b.path ~= "" then return b.path end
                    if b.komga_book_id or b.komga_id then
                        return "komga://book/" .. tostring(b.komga_book_id or b.komga_id)
                    end
                    return nil
                end

                for i = 1, #merged do
                    local entry = merged[i]
                    if entry.is_folder or entry.kind == "folder" or entry.is_series or entry.komga_series_id or (type(entry.path) == "string" and entry.path:find("^komga://series/")) then
                        local books = Remote.expandSeriesToBooks(source, entry, sort_priority, folder_path)
                        for _, b in ipairs(books) do
                            local k = spineKey(b)
                            if not k or not seen_spine_keys[k] then
                                if k then seen_spine_keys[k] = true end
                                spine_books[#spine_books + 1] = b
                            end
                        end
                    else
                        entry.shelf_section = entry.shelf_section or nil
                        entry.filepath = entry.filepath or entry.path or entry.fp
                        entry.is_folder = false
                        entry.is_series = false
                        entry.kind = "book"
                        entry.source_kind = "hybrid"
                        entry.page_count = (entry.page_count and entry.page_count > 0 and entry.page_count) or 200
                        local k = spineKey(entry)
                        if not k or not seen_spine_keys[k] then
                            if k then seen_spine_keys[k] = true end
                            spine_books[#spine_books + 1] = entry
                        end
                    end
                end
                merged = spine_books
            end
        end

        for i = 1, #merged do
            local rec = merged[i]
            if rec.source_kind == nil or rec.source_kind == "komga" then
                rec.source_kind = "hybrid"
            end
            if rec.downloaded ~= true then
                if rec.is_remote == nil then
                    rec.is_remote = (rec.filepath and rec.filepath:find("^%a+://") ~= nil)
                        or rec.is_komga
                        or rec.is_opds_nav
                        or (rec.opds ~= nil)
                        or (rec.source_nav == true)
                end
            else
                rec.is_remote = false
            end
        end

        -- 4. Apply Sort Priority across merged records
        local ok_se, SortEngine = pcall(require, "lib/bookshelf_sort_engine")
        if is_komga_series or is_opds_series then
            -- Series natural reading order: series_index / series_num numerical sort, then natural title/filename
            table.sort(merged, function(a, b)
                local na = tonumber(a.series_index or a.series_num)
                local nb = tonumber(b.series_index or b.series_num)
                if na and nb and na ~= nb then
                    return na < nb
                end
                if na and not nb then return true end
                if nb and not na then return false end
                if ok_se and SortEngine and SortEngine.KEYS and SortEngine.KEYS.filename then
                    local res = SortEngine.KEYS.filename.comparator(a, b)
                    if res ~= 0 then return res < 0 end
                end
                local ta = a.title or a.display_title or a.filename or a.name or ""
                local tb = b.title or b.display_title or b.filename or b.name or ""
                return tostring(ta):lower() < tostring(tb):lower()
            end)
        elseif is_spine then
            -- Spines mode: sections stay grouped, books are ordered within their section
            -- (mirroring Repo.getFolderSections). No cross-section reordering.
        elseif ok_se and SortEngine and SortEngine.chainedComparator and sort_priority and #sort_priority > 0 then
            local ok_s = pcall(table.sort, merged, SortEngine.chainedComparator(sort_priority))
            if not ok_s then
                table.sort(merged, function(a, b)
                    return (a.title or a.name or "") < (b.title or b.name or "")
                end)
            end
        end

        if (is_komga_series or is_opds_series) and series_cache_key and series_cache_key ~= "" then
            _active_series_cache[series_cache_key] = {
                timestamp = os.time(),
                books = merged,
            }
        end
    end

        local total = #merged
        local off = offset or 0
        local lim = limit or total
        local page = {}
        for i = off + 1, math.min(off + lim, total) do
            local rec = merged[i]
            if not rec.cover_image_path then
                if rec.is_folder or rec.is_opds_nav or rec.komga_series_id then
                    local sid = rec.komga_series_id or (type(rec.filepath) == "string" and rec.filepath:match("^komga://series/(.+)$"))
                    local cp = sid and Remote.getKomgaCoverPath("series", sid, rec.title or rec.label)
                    if cp then
                        rec.cover_image_path = cp
                        rec.has_cover = true
                        rec.first_book = {
                            filepath = rec.filepath,
                            cover_image_path = cp,
                            title = rec.title,
                            has_cover = true,
                        }
                    end
                elseif rec.komga_book_id or rec.komga_id then
                    local bid = rec.komga_book_id or rec.komga_id or (type(rec.filepath) == "string" and rec.filepath:match("^komga://book/(.+)$"))
                    local cp = bid and Remote.getKomgaCoverPath("book", bid)
                    if cp then
                        rec.cover_image_path = cp
                        rec.has_cover = true
                    end
                end
            end
            page[#page + 1] = rec
        end

        if #page > 0 and Remote and Remote.scheduleKomgaCovers then
            Remote.scheduleKomgaCovers(page)
        end

        return page, total
    end,

    open_folder = function(folder)
        Remote.ensureKomgaApiPatched()

        -- 1. Komga series
        local series_id = folder.komga_series_id
            or (type(folder.filepath) == "string" and folder.filepath:match("^komga://series/(.+)$"))
            or (type(folder.path) == "string" and folder.path:match("^komga://series/(.+)$"))
            or folder.series_id
            or folder.komga_id
        if series_id then
            folder.komga_series_id = series_id
            local s_label = folder.komga_series_title or folder.title or folder.label
            debugLog(string.format("[OPEN_FOLDER] komga_series id=%s label=%s", tostring(series_id), tostring(s_label)))

            -- Pre-drill validation:
            -- Check if folder has local files on disk. If not, it is purely remote.
            local has_local_dir = false
            local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
            local p = folder.path or folder.filepath
            if p and type(p) == "string" and p:find("^/") and ok_lfs and lfs and lfs.attributes and lfs.attributes(p, "mode") == "directory" then
                has_local_dir = true
            end

            -- If purely remote, check if series is deleted on Komga
            if not has_local_dir then
                local ok_bh, BridgeHealth = pcall(require, "lib/bridge_health")
                local reachable = (not ok_bh or not BridgeHealth or not BridgeHealth.isServerReachable or BridgeHealth.isServerReachable())
                if reachable then
                    local komga = getKomgaPlugin()
                    local api = (komga and komga.api) or (Remote and Remote.getKomgaApi and Remote.getKomgaApi())
                    if api then
                        local ok_det, s_det, err_det = false, nil, nil
                        if api.get_series_detail then
                            ok_det, s_det, err_det = pcall(api.get_series_detail, api, series_id)
                        elseif api.get_books_for_series then
                            ok_det, s_det, err_det = pcall(api.get_books_for_series, api, series_id, nil, 0, 1)
                        end
                        local det_str = tostring(s_det or err_det or ""):lower()
                        local is_404 = det_str:find("404") ~= nil or det_str:find("not found") ~= nil or (ok_det and s_det == nil)
                        if is_404 then
                            logger.warn(string.format("[Hybrid] open_folder: Series %s (%s) no longer exists on Komga (404), blocking drilldown and purging cache",
                                tostring(series_id), tostring(s_label)))
                            if Remote and Remote.purgeDeletedSeries then
                                Remote.purgeDeletedSeries(series_id, s_label)
                            end
                            local ok_ui, UIManager = pcall(require, "ui/uimanager")
                            local ok_notif, Notification = pcall(require, "ui/widget/notification")
                            if ok_ui and UIManager and ok_notif and Notification then
                                UIManager:show(Notification:new{ text = _("Series no longer exists on Komga; removed from shelf.") })
                            end
                            return nil
                        end
                    end
                end
            end
            local ok_s, Sources = pcall(require, "lib/bookshelf_sources")
            local komga_spec = ok_s and Sources and Sources.get and Sources.get("komga")
            if komga_spec and komga_spec.open_folder then
                local ok_e, entry = pcall(komga_spec.open_folder, folder)
                if ok_e and entry then
                    entry.path = folder.path or folder.filepath or entry.path
                    entry.komga_series_id = folder.komga_series_id or entry.series_id
                    entry.is_hybrid_folder = folder.is_hybrid_folder
                    return entry
                end
            end
            return {
                kind = "komga_series",
                series_id = series_id,
                komga_series_id = series_id,
                path = folder.path or folder.filepath,
                is_hybrid_folder = folder.is_hybrid_folder,
                label = folder.komga_series_title or folder.title or folder.label,
                series_summary = folder.komga_series_summary,
            }
        end

        -- 2. Komga collection
        if folder.komga_collection_id then
            local ok_s, Sources = pcall(require, "lib/bookshelf_sources")
            local komga_spec = ok_s and Sources and Sources.get and Sources.get("komga")
            if komga_spec and komga_spec.open_folder then
                local entry = komga_spec.open_folder(folder)
                if entry then return entry end
            end
            return {
                kind = "komga_collection",
                collection_id = folder.komga_collection_id,
                label = folder.komga_collection_title or folder.title or folder.label,
            }
        end

        -- 3. OPDS navigation tile
        if folder.is_opds_nav or (folder.opds and folder.opds.feed_url) then
            local fu = folder.opds and folder.opds.feed_url
            local sk = (folder.opds and folder.opds.server_key) or folder.server_key
            if not sk then
                local ok_os, OpdsSource = pcall(require, "lib/bookshelf_opds_source")
                if ok_os and OpdsSource and OpdsSource.serverKey and fu then
                    sk = OpdsSource.serverKey(fu)
                end
            end
            return {
                kind = "opds_nav",
                feed_url = fu,
                server_key = sk,
                label = folder.label or folder.title or folder.name,
                path = folder.filepath,
            }
        end

        -- 4. Local filesystem folder
        local p = folder.path or folder.filepath
        if p and not p:find("^komga://") and not p:find("^OPDS://") then
            return {
                kind = "folder",
                path = p,
                label = folder.label or folder.title or folder.name or p:match("([^/]+)/?$"),
            }
        end

        return {
            kind = "folder",
            path = folder.filepath or folder.path,
            label = folder.label or folder.title or folder.name,
        }
    end,

    open = function(book, ctx)
        local fp = book and book.filepath
        if fp and not fp:find("^komga://") and not fp:find("^OPDS://") then
            local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
            if ok_lfs and lfs and lfs.attributes(fp, "mode") == "file" then
                return fp
            end
        end

        -- Check downloaded mapping
        local downloaded = Dedup.getDownloadedMap()
        local local_path = fp and downloaded[fp]
        if local_path then
            local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
            if ok_lfs and lfs and lfs.attributes(local_path, "mode") == "file" then
                return local_path
            end
        end

        -- Remote open / download
        local komga = getKomgaPlugin()
        if book.komga_id and komga and komga.downloadBookById then
            UIManager:show(Notification:new{ text = _("Downloading from Komga…") })
            komga:downloadBookById(book.komga_id, function(path)
                if ctx and ctx.open and path then
                    ctx.open(path)
                end
            end, function(err)
                UIManager:show(Notification:new{ text = _("Download failed: ") .. tostring(err) })
            end)
            return true
        end

        -- OPDS download fallback
        local ok_dl, OpdsDownload = pcall(require, "lib/bookshelf_opds_download")
        if ok_dl and OpdsDownload and OpdsDownload.downloadBook then
            OpdsDownload.downloadBook(book, function(path)
                if ctx and ctx.open and path then
                    ctx.open(path)
                end
            end)
            return true
        end

        return false
    end,

    info = function(book, ctx)
        local ok_i, Info = pcall(require, "lib/bookshelf_book_info")
        if ok_i and Info and Info.show then
            Info.show(book, ctx)
        else
            UIManager:show(Notification:new{
                text = (book.title or _("Book")) .. "\n" .. (book.authors or book.author or ""),
            })
        end
    end,

    refresh = function(source, drill, done)
        local remote_kind = source.remote_kind or (source.opds_id and "opds") or "komga"
        if remote_kind == "opds" then
            local ok_w, OpdsWindow = pcall(require, "lib/bookshelf_opds_window")
            if ok_w and OpdsWindow and OpdsWindow.invalidate then
                OpdsWindow.invalidate(source.opds_id, source.feed_url)
            end
            if done then done() end
        else
            local ok_s, Sources = pcall(require, "lib/bookshelf_sources")
            local komga_spec = ok_s and Sources and Sources.get and Sources.get("komga")
            if komga_spec and komga_spec.refresh then
                local komga_source = {
                    kind = "komga",
                    list = source.komga_list or "all_series",
                    library_id = source.library_id,
                    library_names = source.library_names,
                    read_status = source.read_status,
                    status = source.status,
                    sort = source.sort,
                }
                komga_spec.refresh(komga_source, drill, done)
            elseif done then
                done()
            end
        end
    end,

    owns = function(book)
        if type(book) ~= "table" then return false end
        return book.source_kind == "hybrid"
            or book.is_komga == true
            or (book.filepath and (book.filepath:find("^komga://") or book.filepath:find("^OPDS://")))
    end,
}

function M.installSourceForwarding()
    local ok_s, Sources = pcall(require, "lib/bookshelf_sources")
    if ok_s and Sources and type(Sources.onChanged) == "function" then
        Sources.onChanged("hybrid_forwarder", function(id)
            if id == "komga" or id == "opds" then
                logger.info("[Hybrid] Forwarding sourceChanged(" .. tostring(id) .. ") -> Sources.changed('hybrid')")
                debugLog("[FORWARD] sourceChanged(" .. tostring(id) .. ") -> Sources.changed('hybrid')")
                local ok_ui, UIManager = pcall(require, "ui/uimanager")
                if ok_ui and UIManager and UIManager.nextTick then
                    UIManager:nextTick(function()
                        Sources.changed("hybrid")
                    end)
                else
                    Sources.changed("hybrid")
                end
            end
        end)
        logger.info("[Hybrid] Installed Sources.onChanged hybrid forwarder")
    end
end

M.SPEC = SPEC
return M
