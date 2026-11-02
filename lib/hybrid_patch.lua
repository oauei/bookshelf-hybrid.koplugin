-- lib/hybrid_patch.lua
-- Non-invasive hooks into Bookshelf's Widget and ChipEditor for Hybrid shelves.

local logger = require("logger")
local UIManager = require("ui/uimanager")
local ButtonDialog = require("ui/widget/buttondialog")
local _ = require("gettext")

local function debugLog(msg)
    pcall(function()
        local f = io.open("/sdcard/koreader/hybrid_debug.log", "a")
        if f then
            f:write(os.date("%Y-%m-%d %H:%M:%S") .. " [PATCH] " .. tostring(msg) .. "\n")
            f:close()
        end
    end)
end

local M = {}

-- ---------------------------------------------------------------------------
-- 1. Patch BookshelfWidget for Start Folder Long-Press Menu
-- ---------------------------------------------------------------------------

function M.installWidgetPatch()
    local ok_bw, BookshelfWidget = pcall(require, "lib/bookshelf_widget")
    if not (ok_bw and BookshelfWidget) then return end
    if BookshelfWidget._hybrid_widget_patched then return end
    BookshelfWidget._hybrid_widget_patched = true

    -- Hook _expandSourceNav for audit logging
    local orig_expandSourceNav = BookshelfWidget._expandSourceNav
    BookshelfWidget._expandSourceNav = function(self_w, rec)
        debugLog(string.format("expandSourceNav title=%s kind=%s id=%s",
            tostring(rec and (rec.title or rec.label)),
            tostring(rec and rec.kind),
            tostring(rec and (rec.komga_series_id or rec.filepath))))
        return orig_expandSourceNav and orig_expandSourceNav(self_w, rec)
    end

    -- Hook _expandOpdsNav for audit logging
    local orig_expandOpdsNav = BookshelfWidget._expandOpdsNav
    BookshelfWidget._expandOpdsNav = function(self_w, rec, no_fetch)
        debugLog(string.format("expandOpdsNav title=%s kind=%s source_nav=%s fp=%s",
            tostring(rec and (rec.title or rec.label)),
            tostring(rec and rec.kind),
            tostring(rec and rec.source_nav),
            tostring(rec and rec.filepath)))
        return orig_expandOpdsNav and orig_expandOpdsNav(self_w, rec, no_fetch)
    end

    -- Add _hybridTab
    BookshelfWidget._hybridTab = function(self_w)
        local TabModel = require("lib/bookshelf_tab_model")
        local tab = TabModel.getById(self_w.chip)
        if tab and tab.source and tab.source.kind == "hybrid" then
            return tab
        end
        return nil
    end

    -- Hook _shelfLabelMode so hybrid shelf titles are never suppressed by _gridDrawsLabels
    local orig_shelfLabelMode = BookshelfWidget._shelfLabelMode
    BookshelfWidget._shelfLabelMode = function(self_w)
        if self_w._hybridTab and self_w:_hybridTab() then
            local ok_cl, CoverLabel = pcall(require, "lib/bookshelf_cover_label")
            local mode = ok_cl and CoverLabel and CoverLabel.modeFor and CoverLabel.modeFor(self_w.chip)
            if mode == "none" and not (self_w._groupLabelMode and self_w:_groupLabelMode()) then
                return nil
            end
            if mode ~= "author" and mode ~= "series" and mode ~= "custom" and mode ~= "none" then
                mode = "title"
            end
            return mode
        end
        return orig_shelfLabelMode and orig_shelfLabelMode(self_w)
    end

    -- Hook _opdsPrefsTab
    local orig_opdsPrefsTab = BookshelfWidget._opdsPrefsTab
    BookshelfWidget._opdsPrefsTab = function(self_w)
        local tab = orig_opdsPrefsTab and orig_opdsPrefsTab(self_w)
        if tab then return tab end
        return self_w._hybridTab and self_w:_hybridTab() or nil
    end

    -- Hook _opdsEffectiveTab
    local orig_opdsEffectiveTab = BookshelfWidget._opdsEffectiveTab
    BookshelfWidget._opdsEffectiveTab = function(self_w)
        local path = self_w._drilldown_path or {}
        local tip = path[#path]
        if tip then
            if tip.kind == "opds_nav" and tip.payload and tip.payload.feed_url then
                return {
                    label = tip.label,
                    source = { kind = "opds", id = tip.payload.server_key or "komga", feed_url = tip.payload.feed_url },
                }
            end
            if tip.kind == "source_nav" and tip.payload and tip.payload.source_kind == "hybrid" then
                return self_w._hybridTab and self_w:_hybridTab() or nil
            end
        end
        local tab = orig_opdsEffectiveTab and orig_opdsEffectiveTab(self_w)
        if tab then return tab end
        return self_w._hybridTab and self_w:_hybridTab() or nil
    end

    -- Hook _currentRegisteredSource so hybrid shelf notifications are never dropped
    local orig_currentRegisteredSource = BookshelfWidget._currentRegisteredSource
    BookshelfWidget._currentRegisteredSource = function(self_w)
        local src = orig_currentRegisteredSource and orig_currentRegisteredSource(self_w)
        if src then return src end
        if self_w._hybridTab and self_w:_hybridTab() then
            local path = self_w._drilldown_path or {}
            local tip = path[#path]
            return {
                kind = "hybrid",
                drill = tip and (tip.payload and (tip.payload.drill or tip.payload) or tip) or nil,
            }
        end
        return nil
    end

    -- Hook _opdsAfterPage to drive OPDS covers and Komga covers on hybrid shelves
    local orig_opdsAfterPage = BookshelfWidget._opdsAfterPage
    BookshelfWidget._opdsAfterPage = function(self_w, items)
        if orig_opdsAfterPage then orig_opdsAfterPage(self_w, items) end
        if self_w._hybridTab and self_w:_hybridTab() then
            pcall(function()
                if self_w._opdsEnsureCovers then
                    self_w:_opdsEnsureCovers()
                end
                local ok_r, Remote = pcall(require, "lib/hybrid_remote")
                if ok_r and Remote and Remote.scheduleKomgaCovers then
                    Remote.scheduleKomgaCovers(self_w._page_items)
                end
            end)
        end
    end

    -- Hook _fetchChipItems to ensure hybrid shelf drills stay on the hybrid source
    local orig_fetchChipItems = BookshelfWidget._fetchChipItems
    BookshelfWidget._fetchChipItems = function(self_w, n, want_all)
        local tab = self_w._hybridTab and self_w:_hybridTab()
        if tab then
            local path = self_w._drilldown_path or {}
            local tip = path[#path]
            if tip then
                local Repo = require("lib/bookshelf_book_repository")
                local offset = want_all and 0 or math.max(0, (self_w._cursor or 1) - 1)
                local LIMIT = want_all and n or self_w:_viewSize()
                local within
                local sp = tab.sort_priority
                if sp and #sp >= 2 then
                    within = {}
                    for i = 2, #sp do within[#within + 1] = sp[i] end
                end

                -- 1. Folder drill on a hybrid shelf
                if tip.kind == "folder" then
                    local pay = tip.payload or {}
                    local p_path = pay.path
                    local series_id = pay.komga_series_id or (p_path and p_path:match("^komga://series/(.+)$"))
                    local fetch_opts = { hybrid_folder_path = p_path }
                    local drill = {
                        kind = (series_id and not (p_path and p_path:find("^/"))) and "komga_series" or "folder",
                        path = p_path,
                        series_id = series_id,
                        komga_series_id = series_id,
                        is_hybrid_folder = pay.is_hybrid_folder,
                        label = tip.label,
                    }
                    local src = {}
                    for k, v in pairs(tab.source) do src[k] = v end
                    src.drill = drill
                    return Repo.getBySource(src, nil, within or tab.sort_priority, offset, LIMIT, fetch_opts)
                end

                -- 2. OPDS navigation or source_nav tile drill on a hybrid shelf
                if tip.kind == "opds_nav" or tip.kind == "source_nav" then
                    local pay = tip.payload or {}
                    local series_id = pay.komga_series_id or (pay.path and pay.path:match("^komga://series/(.+)$"))
                    if series_id or (pay.drill and (pay.drill.series_id or pay.drill.kind == "komga_series")) then
                        local src = {}
                        for k, v in pairs(tab.source) do src[k] = v end
                        src.drill = pay.drill or {
                            kind = "komga_series",
                            series_id = series_id,
                            label = tip.label,
                        }
                        local res_items, res_total = Repo.getBySource(src, nil, nil, offset, LIMIT, {})
                        if (not res_items or #res_items == 0) and (not res_total or res_total == 0) and (series_id or (pay.drill and pay.drill.series_id)) then
                            local sid = series_id or (pay.drill and pay.drill.series_id)
                            local ok_bh, BridgeHealth = pcall(require, "lib/bridge_health")
                            local reachable = (not ok_bh or not BridgeHealth or not BridgeHealth.isServerReachable or BridgeHealth.isServerReachable())
                            if reachable then
                                local ok_rem, Remote = pcall(require, "lib/hybrid_remote")
                                if ok_rem and Remote and Remote.purgeDeletedSeries then
                                    Remote.purgeDeletedSeries(sid, tip.label)
                                end
                                -- Auto-eject: pop back to root shelf
                                self_w._drilldown_path = {}
                                self_w._cursor = 1
                                self_w:_syncPageFromCursor()
                                local ok_ui, UIManager = pcall(require, "ui/uimanager")
                                local ok_notif, Notification = pcall(require, "ui/widget/notification")
                                if ok_ui and UIManager and ok_notif and Notification then
                                    UIManager:show(Notification:new{ text = _("Series no longer exists on Komga; returning to shelf.") })
                                end
                                local root_src = {}
                                for k, v in pairs(tab.source) do root_src[k] = v end
                                root_src.drill = nil
                                return Repo.getBySource(root_src, nil, tab.sort_priority, 0, LIMIT, {})
                            end
                        end
                        return res_items, res_total
                    end
                    local drill = {
                        kind = "opds_nav",
                        feed_url = pay.feed_url,
                        server_key = pay.server_key,
                        label = tip.label,
                    }
                    local src = {}
                    for k, v in pairs(tab.source) do src[k] = v end
                    src.drill = drill
                    return Repo.getBySource(src, nil, tab.sort_priority, offset, LIMIT, {})
                end
            end
        end
        return orig_fetchChipItems(self_w, n, want_all)
    end

    -- Hook _opdsStartFeed
    local orig_opdsStartFeed = BookshelfWidget._opdsStartFeed
    BookshelfWidget._opdsStartFeed = function(self_w, tab)
        tab = tab or require("lib/bookshelf_tab_model").getById(self_w.chip)
        if tab and tab.source and tab.source.kind == "hybrid" then
            return tab.source.feed_url, tab.source.feed_label
        end
        if orig_opdsStartFeed then
            return orig_opdsStartFeed(self_w, tab)
        end
        return nil
    end

    -- Hook _setOpdsStartFeed
    local orig_setOpdsStartFeed = BookshelfWidget._setOpdsStartFeed
    BookshelfWidget._setOpdsStartFeed = function(self_w, feed_url, label)
        local TabModel = require("lib/bookshelf_tab_model")
        local tabs = TabModel.load()
        local found = false
        for _i, t in ipairs(tabs) do
            if t.id == self_w.chip and t.source and t.source.kind == "hybrid" then
                t.source.feed_url = feed_url
                t.source.feed_label = feed_url and label or nil
                found = true
                break
            end
        end
        if found then
            TabModel.save(tabs)
            self_w:_selectChip(self_w.chip)
            return true
        end
        if orig_setOpdsStartFeed then
            return orig_setOpdsStartFeed(self_w, feed_url, label)
        end
        return false
    end

    local function isHybridBook(book)
        if not book then return false end
        if book.is_komga or book.komga_book_id or book.komga_dto then return true end
        if type(book.filepath) == "string" and book.filepath:find("^komga://") then return true end
        if book.source_kind == "hybrid" and (book.is_remote or (type(book.filepath) == "string" and book.filepath:find("^%a+://"))) then return true end
        return false
    end

    -- Hook _openBook for remote hybrid book action dialog
    local orig_openBook = BookshelfWidget._openBook
    BookshelfWidget._openBook = function(self_w, book, after_open_callback)
        if isHybridBook(book) then
            local ok_d, Dedup = pcall(require, "lib/hybrid_dedup")
            local downloaded = ok_d and Dedup and Dedup.getDownloadedMap and Dedup.getDownloadedMap() or {}
            local book_id = book.komga_book_id or book.komga_id
                or (type(book.filepath) == "string" and book.filepath:match("^komga://book/(.+)$"))
            local rec_key = "komga://book/" .. tostring(book_id or "")

            local local_path = downloaded[rec_key]
                or (type(book.filepath) == "string" and downloaded[book.filepath])
                or (type(book.filepath) == "string" and not book.filepath:find("^%a+://") and book.filepath)

            local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
            local is_file = local_path and ok_lfs and lfs and lfs.attributes and lfs.attributes(local_path, "mode") == "file"

            if is_file then
                book.filepath = local_path
                book.downloaded = true
                book.is_remote = false
                if self_w._launchReader then
                    return self_w:_launchReader(local_path, after_open_callback)
                end
            else
                local ok_hd, HybridDialog = pcall(require, "lib/hybrid_dialog")
                if ok_hd and HybridDialog and HybridDialog.showBookActionDialog then
                    return HybridDialog.showBookActionDialog(book, self_w, after_open_callback)
                elseif not ok_hd then
                    debugLog("require hybrid_dialog failed: " .. tostring(HybridDialog))
                end
            end
        end
        if orig_openBook then
            return orig_openBook(self_w, book, after_open_callback)
        end
    end

    -- Hook _showBookDetail for hybrid book actions
    local orig_showBookDetail = BookshelfWidget._showBookDetail
    BookshelfWidget._showBookDetail = function(self_w, book, opts)
        if isHybridBook(book) then
            local ok_hd, HybridDialog = pcall(require, "lib/hybrid_dialog")
            if ok_hd and HybridDialog and HybridDialog.showBookActionDialog then
                return HybridDialog.showBookActionDialog(book, self_w, nil, opts)
            end
        end
        if orig_showBookDetail then
            return orig_showBookDetail(self_w, book, opts)
        end
    end

    -- Hook _isRemoteRecord so Bookshelf doesn't treat remote komga items as missing local files
    local orig_isRemoteRecord = BookshelfWidget._isRemoteRecord
    BookshelfWidget._isRemoteRecord = function(self_w, book)
        if isHybridBook(book) and (book.is_remote or (type(book.filepath) == "string" and book.filepath:find("^komga://"))) then
            local ok_d, Dedup = pcall(require, "lib/hybrid_dedup")
            local downloaded = ok_d and Dedup and Dedup.getDownloadedMap and Dedup.getDownloadedMap() or {}
            local book_id = book.komga_book_id or book.komga_id
                or (type(book.filepath) == "string" and book.filepath:match("^komga://book/(.+)$"))
            local rec_key = "komga://book/" .. tostring(book_id or "")
            local local_path = downloaded[rec_key]
                or (type(book.filepath) == "string" and downloaded[book.filepath])
            if not local_path then
                return true
            end
        end
        if orig_isRemoteRecord then
            return orig_isRemoteRecord(self_w, book)
        end
        return false
    end

    -- Hook _viewMode to preserve ViewMode.SPINES for hybrid, komga, and opds
    local orig_viewMode = BookshelfWidget._viewMode
    BookshelfWidget._viewMode = function(self_w)
        local ok_vm, ViewMode = pcall(require, "lib/bookshelf_view_mode")
        if not (ok_vm and ViewMode) then
            return orig_viewMode and orig_viewMode(self_w)
        end
        local ok_tm, TabModel = pcall(require, "lib/bookshelf_tab_model")
        local tab = ok_tm and TabModel and TabModel.getById and TabModel.getById(self_w.chip)
        local kind = tab and tab.source and tab.source.kind
        if kind == "hybrid" or kind == "komga" or kind == "opds" then
            if self_w._covers_pin and self_w._covers_pin > 0 then
                return ViewMode.COVERS
            end
            if self_w._isSearchResults and self_w:_isSearchResults() then
                local ok_bs, BookshelfSettings = pcall(require, "lib/bookshelf_settings_store")
                local m = ok_bs and BookshelfSettings and BookshelfSettings.read and BookshelfSettings.read("search_view_mode")
                if m == ViewMode.LIST then return ViewMode.LIST end
                if m == ViewMode.SPINES then return ViewMode.SPINES end
                if m == ViewMode.AUTO then
                    return ViewMode.effective(self_w._expanded, true)
                end
                return ViewMode.COVERS
            end
            local chip_mode = self_w._chipViewMode and self_w:_chipViewMode()
            if chip_mode == ViewMode.AUTO then
                chip_mode = ViewMode.auto(tab, self_w._isDrilledIn and self_w:_isDrilledIn())
            end
            if chip_mode == ViewMode.SPINES then
                return ViewMode.SPINES
            end
            if chip_mode then return chip_mode end
            return ViewMode.COVERS
        end
        return orig_viewMode and orig_viewMode(self_w)
    end

    -- Hook _flipViewMode to allow cycling LIST -> SPINES -> COVERS for hybrid, komga, and opds
    local orig_flipViewMode = BookshelfWidget._flipViewMode
    BookshelfWidget._flipViewMode = function(self_w)
        local ok_vm, ViewMode = pcall(require, "lib/bookshelf_view_mode")
        local ok_tm, TabModel = pcall(require, "lib/bookshelf_tab_model")
        local tab = ok_tm and TabModel and TabModel.getById and TabModel.getById(self_w.chip)
        local kind = tab and tab.source and tab.source.kind
        if (kind == "hybrid" or kind == "komga" or kind == "opds") and self_w._isListMode and self_w:_isListMode() then
            if ok_vm and ViewMode and ok_tm and TabModel then
                if self_w._markOpdsNav then self_w:_markOpdsNav() end
                local tabs = TabModel.load and TabModel.load()
                local hit = nil
                for _, t in ipairs(tabs or {}) do
                    if t.id == self_w.chip then hit = t break end
                end
                if hit then
                    hit[ViewMode.CHIP_KEY] = ViewMode.SPINES
                    TabModel.save(tabs)
                end
                if self_w._rebuild then self_w:_rebuild() end
                if UIManager and UIManager.setDirty then
                    UIManager:setDirty(self_w, "ui")
                end
                return true
            end
        end
        return orig_flipViewMode and orig_flipViewMode(self_w)
    end

    logger.info("[Hybrid] Hooked BookshelfWidget start feed, effective tab, and Spines viewMode methods")
end

-- ---------------------------------------------------------------------------
-- 2. Patch BookshelfChipEditor for Sort Rows, Filters, and Catalog Settings
-- ---------------------------------------------------------------------------

function M.persistRemoteMode(draft, new_mode)
    if not draft then return end
    draft.source = draft.source or {}
    draft.source.remote_mode = new_mode

    local ok_tm, TabModel = pcall(require, "lib/bookshelf_tab_model")
    if ok_tm and TabModel and TabModel.load then
        local tabs = TabModel.load()
        local matched_tab = nil

        -- Match 1: draft.id
        if draft.id then
            for _, t in ipairs(tabs) do
                if t.id == draft.id then
                    matched_tab = t
                    break
                end
            end
        end

        -- Match 2: by active bookshelf chip
        if not matched_tab then
            for _, mod in ipairs({ "apps/filemanager/filemanager", "apps/reader/readerui" }) do
                local ok, m = pcall(require, mod)
                local bw = ok and m and m.instance and m.instance.bookshelf
                if bw and bw.chip then
                    for _, t in ipairs(tabs) do
                        if t.id == bw.chip then
                            matched_tab = t
                            break
                        end
                    end
                end
                if matched_tab then break end
            end
        end

        -- Match 3: any hybrid tab matching source (handling library_id as table or string)
        if not matched_tab and draft.source then
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

            for _, t in ipairs(tabs) do
                if t.source and t.source.kind == "hybrid" then
                    if t.source == draft.source then
                        matched_tab = t
                        break
                    elseif draft.source.library_id and t.source.library_id and same_lib(draft.source.library_id, t.source.library_id) then
                        matched_tab = t
                        break
                    elseif not draft.source.library_id and not t.source.library_id and t.source.local_folder == draft.source.local_folder then
                        matched_tab = t
                        break
                    end
                end
            end
        end

        -- Match 4: fallback to first hybrid tab
        if not matched_tab then
            for _, t in ipairs(tabs) do
                if t.source and t.source.kind == "hybrid" then
                    matched_tab = t
                    break
                end
            end
        end

        if matched_tab then
            matched_tab.source = matched_tab.source or {}
            matched_tab.source.remote_mode = new_mode
            TabModel.save(tabs)
        end
    end

    -- Invalidate book repository cache so the shelf pulls fresh next_book / all records
    local ok_repo, Repo = pcall(require, "lib/bookshelf_book_repository")
    if ok_repo and Repo then
        if Repo.invalidateBookCache then
            Repo.invalidateBookCache("hybrid-remote-mode")
        end
        if Repo.invalidateAllCache then
            Repo.invalidateAllCache()
        end
    end
end

function M.patchCatalogSettings(Editor)
    if type(Editor) ~= "table" or Editor._hybrid_catalog_patched then return end
    Editor._hybrid_catalog_patched = true

    -- Hook _openCatalogSettings
    local orig_openCatalogSettings = Editor._openCatalogSettings
    Editor._openCatalogSettings = function(self_ed, draft, on_close)
        local is_opds = draft.source and draft.source.kind == "opds"
        local is_hybrid = draft.source and draft.source.kind == "hybrid"
        local is_komga = draft.source and draft.source.kind == "komga"

        if not (is_opds or is_hybrid or is_komga) then
            return orig_openCatalogSettings(self_ed, draft, on_close)
        end

        local d = nil
        local function reopen()
            if d then UIManager:close(d); d = nil end
            self_ed:_openCatalogSettings(draft, on_close)
        end

        local buttons = {}

        -- 1. Starts at row
        local start_label = draft.source.feed_label or draft.source.library_name
        if start_label then
            buttons[#buttons + 1] = {
                {
                    text = _("Starts at: ") .. start_label .. _(" (tap to clear)"),
                    callback = function()
                        draft.source.feed_url = nil
                        draft.source.feed_label = nil
                        draft.source.library_id = nil
                        draft.source.library_name = nil
                        if on_close then on_close() end
                        reopen()
                    end,
                },
            }
        else
            buttons[#buttons + 1] = {
                {
                    text = _("Starts at: Top of catalog / library"),
                    enabled = false,
                },
            }
        end

        -- 2. Filter local books button (for hybrid)
        if is_hybrid then
            buttons[#buttons + 1] = {
                {
                    text = _("Filter local books…"),
                    callback = function()
                        UIManager:close(d)
                        d = nil
                        self_ed:_openFilters(draft, function()
                            if on_close then on_close() end
                            reopen()
                        end)
                    end,
                },
            }
        end

        -- 3. Toggle local library inclusion
        if is_hybrid then
            local is_remote_opds = draft.source.remote_kind == "opds"
            buttons[#buttons + 1] = {
                {
                    text = is_remote_opds and _("Exclude local library (OPDS only)") or _("Exclude local library (Komga only)"),
                    callback = function()
                        if is_remote_opds then
                            draft.source.kind = "opds"
                            draft.source.id = draft.source.opds_id or draft.source.id
                        else
                            draft.source.kind = "komga"
                        end
                        draft.source.remote_kind = nil
                        draft.source.local_folder = nil
                        if d then UIManager:close(d); d = nil end
                        if on_close then on_close() end
                    end,
                },
            }
        elseif is_komga then
            buttons[#buttons + 1] = {
                {
                    text = _("Include local library (Convert to Hybrid)"),
                    callback = function()
                        draft.source.kind = "hybrid"
                        draft.source.remote_kind = "komga"
                        if d then UIManager:close(d); d = nil end
                        if on_close then on_close() end
                    end,
                },
            }
        else -- is_opds
            buttons[#buttons + 1] = {
                {
                    text = _("Include local library (Convert to Hybrid)"),
                    callback = function()
                        draft.source.kind = "hybrid"
                        draft.source.remote_kind = "opds"
                        draft.source.opds_id = draft.source.id
                        if d then UIManager:close(d); d = nil end
                        if on_close then on_close() end
                    end,
                },
            }
        end

        -- 3b. Remote Content Mode (All Chapters vs Next Book)
        if is_hybrid then
            local cur_mode = draft.source and draft.source.remote_mode or "all"
            local mode_text = (cur_mode == "next_book")
                and _("Remote Content: Next Book")
                or _("Remote Content: All Chapters")
            buttons[#buttons + 1] = {
                {
                    text = mode_text,
                    callback = function()
                        local new_mode = (draft.source and draft.source.remote_mode == "next_book") and "all" or "next_book"
                        draft.source = draft.source or {}
                        draft.source.remote_mode = new_mode
                        M.persistRemoteMode(draft, new_mode)
                        if on_close then on_close() end
                        reopen()
                    end,
                },
            }
        end

        -- 4. Switch network profiles
        local ok_kb, KomgaBridge = pcall(require, "lib/bridge_profiles")
        if not ok_kb then
            local ok_p, PluginLoader = pcall(require, "pluginloader")
            local loaded = ok_p and PluginLoader and PluginLoader.loaded_plugins or nil
            KomgaBridge = loaded and loaded["kokomga_bookshelf_bridge"]
        end
        if KomgaBridge and KomgaBridge.showNetworkProfilesDialog then
            buttons[#buttons + 1] = {
                {
                    text = _("Switch server network…"),
                    callback = function()
                        KomgaBridge.showNetworkProfilesDialog(function()
                            if on_close then on_close() end
                            reopen()
                        end)
                    end,
                },
            }
        end

        -- 5. Saves to download directory
        local dir = draft.download_dir
        local dir_label = (type(dir) == "string" and dir ~= "")
            and (dir:match("([^/]+)/?$") or dir)
            or _("KOReader folder")

        buttons[#buttons + 1] = {
            {
                text = _("Saves to: ") .. dir_label,
                callback = function()
                    UIManager:close(d)
                    d = nil
                    self_ed:_pickDownloadDir(draft, function()
                        if on_close then on_close() end
                        reopen()
                    end)
                end,
            },
        }

        buttons[#buttons + 1] = {
            {
                text = _("Save & Close"),
                is_enter_default = true,
                callback = function()
                    if is_hybrid and draft.source and draft.source.remote_mode then
                        M.persistRemoteMode(draft, draft.source.remote_mode)
                    end
                    UIManager:close(d)
                    d = nil
                    if on_close then on_close() end
                end,
            },
        }

        d = ButtonDialog:new{
            title = _("Catalog settings"),
            title_align = "center",
            buttons = buttons,
        }
        UIManager:show(d)
    end
    logger.info("[Hybrid] Hooked BookshelfChipEditor._openCatalogSettings")
end

function M.patchEditorShelfStyle(Editor)
    if type(Editor) ~= "table" or not Editor._pickGroupDisplay then return end
    if Editor._hybrid_shelf_style_patched then return end
    Editor._hybrid_shelf_style_patched = true

    local orig_pickGroupDisplay = Editor._pickGroupDisplay
    Editor._pickGroupDisplay = function(self_ed, draft, on_change, chrome)
        if chrome and draft and draft.source then
            local k = draft.source.kind
            if k == "hybrid" or k == "komga" or k == "opds" then
                chrome.is_opds = false
            end
        end
        return orig_pickGroupDisplay(self_ed, draft, on_change, chrome)
    end
    logger.info("[Hybrid] Hooked BookshelfChipEditor._pickGroupDisplay for Spines style")
end

function M.installEditorPatch()
    -- 1. Hook ButtonTable.new to inject the Remote Content toggle on the main shelf editor dialog
    local ok_bt, ButtonTable = pcall(require, "ui/widget/buttontable")
    if ok_bt and ButtonTable and not ButtonTable._hybrid_editor_hooked then
        ButtonTable._hybrid_editor_hooked = true
        local orig_new = ButtonTable.new
        ButtonTable.new = function(self_bt, o, ...)
            o = o or {}

            -- Ensure loaded Editor has _openCatalogSettings and _pickGroupDisplay patched
            local loaded_ed = package.loaded["lib/bookshelf_chip_editor"]
            if loaded_ed then
                M.patchCatalogSettings(loaded_ed)
                M.patchEditorShelfStyle(loaded_ed)
            end

            if o.buttons and type(o.buttons) == "table" then
                local draft_found, apply_preview_fn, rebuild_fn, shelf_row_idx
                for r_idx, row in ipairs(o.buttons) do
                    for _, btn in ipairs(row) do
                        if type(btn) == "table" and type(btn.callback) == "function" then
                            local cb = btn.callback
                            for u = 1, 10 do
                                local un, uv = debug.getupvalue(cb, u)
                                if not un then break end
                                if type(uv) == "table" and uv.source and type(uv.source) == "table" and uv.source.kind == "hybrid" then
                                    draft_found = uv
                                elseif un == "draft" and type(uv) == "table" then
                                    draft_found = uv
                                elseif (un == "applyLivePreview" or un:find("Preview")) and type(uv) == "function" then
                                    apply_preview_fn = uv
                                elseif (un == "rebuild" or un:find("rebuild")) and type(uv) == "function" then
                                    rebuild_fn = uv
                                end
                            end
                            if draft_found then
                                shelf_row_idx = r_idx
                                break
                            end
                        end
                    end
                    if draft_found then break end
                end

                if draft_found and draft_found.source and draft_found.source.kind == "hybrid" then
                    local already_has = false
                    for _, row in ipairs(o.buttons) do
                        for _, btn in ipairs(row) do
                            if btn._is_hybrid_remote_mode then
                                already_has = true
                                break
                            end
                        end
                        if already_has then break end
                    end

                    if not already_has then
                        local remote_btn = {
                            _is_hybrid_remote_mode = true,
                            text_func = function()
                                local s = draft_found.source or {}
                                if s.remote_mode == "next_book" then
                                    return _("Remote Content: Next Book")
                                else
                                    return _("Remote Content: All Chapters")
                                end
                            end,
                            callback = function()
                                local s = draft_found.source or {}
                                local new_mode = (s.remote_mode == "next_book") and "all" or "next_book"
                                draft_found.source = draft_found.source or {}
                                draft_found.source.remote_mode = new_mode
                                M.persistRemoteMode(draft_found, new_mode)
                                if apply_preview_fn then apply_preview_fn(true) end
                                if rebuild_fn then rebuild_fn() end
                            end,
                        }
                        local insert_pos = (shelf_row_idx and shelf_row_idx + 1) or #o.buttons
                        table.insert(o.buttons, insert_pos, { remote_btn })
                    end
                end
            end
            return orig_new(self_bt, o, ...)
        end
    end

    -- 2. Patch Editor immediately if already loaded
    local loaded_ed = package.loaded["lib/bookshelf_chip_editor"]
    if loaded_ed then
        M.patchCatalogSettings(loaded_ed)
        M.patchEditorShelfStyle(loaded_ed)
    else
        local ok_ed, Editor = pcall(require, "lib/bookshelf_chip_editor")
        if ok_ed and Editor then
            M.patchCatalogSettings(Editor)
            M.patchEditorShelfStyle(Editor)
        end
    end

    logger.info("[Hybrid] Hooked BookshelfChipEditor for catalog settings, shelf style, and shelf editor")
end

function M.installShelfRowPatch()
    local ok_sd, StackDisplay = pcall(require, "lib/bookshelf_stack_display")
    if ok_sd and StackDisplay and StackDisplay.externalLabel and not StackDisplay._hybrid_patched then
        local orig_externalLabel = StackDisplay.externalLabel
        StackDisplay.externalLabel = function(mode, name)
            if type(name) == "string" and name ~= "" then
                local ok_set, BookshelfSettings = pcall(require, "lib/bookshelf_settings_store")
                local lmode = ok_set and BookshelfSettings and BookshelfSettings.read and BookshelfSettings.read("expanded_shelf_label")
                if lmode ~= "none" then
                    return name
                end
            end
            return orig_externalLabel and orig_externalLabel(mode, name)
        end
        StackDisplay._hybrid_patched = true
        logger.info("[Hybrid] Hooked StackDisplay.externalLabel for folder caption visibility")
    end

    if ok_sd and StackDisplay and StackDisplay.groupLabel and not StackDisplay._hybrid_grouplabel_patched then
        local orig_groupLabel = StackDisplay.groupLabel
        StackDisplay.groupLabel = function(mode, item, name, group_text, format)
            local target_name = (type(name) == "string" and name ~= "") and name
                or (type(item) == "table" and (item.label or item.title or item.series_name or item.name))
            local ok_set, BookshelfSettings = pcall(require, "lib/bookshelf_settings_store")
            local lmode = ok_set and BookshelfSettings and BookshelfSettings.read and BookshelfSettings.read("expanded_shelf_label")
            if lmode ~= "none" and type(target_name) == "string" and target_name ~= "" then
                return target_name, false
            end
            return orig_groupLabel and orig_groupLabel(mode, item, name, group_text, format)
        end
        StackDisplay._hybrid_grouplabel_patched = true
        logger.info("[Hybrid] Hooked StackDisplay.groupLabel for series caption visibility")
    end

    if ok_sd and StackDisplay then
        if StackDisplay.itemDrawsExternalLabel and not StackDisplay._hybrid_item_draws_patched then
            local orig_itemDraws = StackDisplay.itemDrawsExternalLabel
            StackDisplay.itemDrawsExternalLabel = function(item, mode, labels)
                if type(item) == "table" and (item.source_kind == "hybrid" or item.is_remote or item.is_komga or item.is_folder or item.kind == "folder" or item.kind == "opds_nav" or item.komga_series_id or item.books or item.series_name) then
                    local books = not (labels and labels.books == false)
                    if books then return true end
                end
                return orig_itemDraws and orig_itemDraws(item, mode, labels)
            end
            StackDisplay._hybrid_item_draws_patched = true
            logger.info("[Hybrid] Hooked StackDisplay.itemDrawsExternalLabel for hybrid item labels")
        end

        if StackDisplay.anyExternalLabel and not StackDisplay._hybrid_any_label_patched then
            local orig_anyLabel = StackDisplay.anyExternalLabel
            StackDisplay.anyExternalLabel = function(items, override, labels)
                if type(items) == "table" then
                    for _, it in pairs(items) do
                        if StackDisplay.itemDrawsExternalLabel(it, StackDisplay.resolve(override), labels) then
                            return true
                        end
                    end
                end
                return orig_anyLabel and orig_anyLabel(items, override, labels)
            end
            StackDisplay._hybrid_any_label_patched = true
            logger.info("[Hybrid] Hooked StackDisplay.anyExternalLabel for hybrid shelf label detection")
        end
    end

    local ok_sw, SpineWidget = pcall(require, "lib/bookshelf_spine_widget")
    if ok_sw and SpineWidget and SpineWidget.init and not SpineWidget._hybrid_fallback_patched then
        local orig_spine_init = SpineWidget.init
        SpineWidget.init = function(self_sw)
            if orig_spine_init then orig_spine_init(self_sw) end
            if self_sw.book and (self_sw.book.source_kind == "hybrid" or self_sw.book.is_remote or self_sw.book.is_komga) then
                self_sw.is_fallback = false
            end
        end
        SpineWidget._hybrid_fallback_patched = true
        logger.info("[Hybrid] Hooked SpineWidget.init for fallback title visibility")
    end

    local ok_sr, ShelfRow = pcall(require, "lib/bookshelf_shelf_row")
    if ok_sr and ShelfRow and ShelfRow.new and not ShelfRow._hybrid_patched then
        local orig_ShelfRow_new = ShelfRow.new
        ShelfRow.new = function(opts)
            if opts and opts.items then
                local ok_r, Remote = pcall(require, "lib/hybrid_remote")
                for _, item in ipairs(opts.items) do
                    if item and (item.source_kind == "hybrid" or item.is_remote or item.is_komga or item.is_folder or item.kind == "folder" or item.kind == "opds_nav" or item.komga_series_id or item.books) then
                        item.label = item.label or item.title or item.name or item.series_name
                        item.title = item.title or item.label or item.name or item.series_name
                        item.series_name = item.series_name or item.label or item.title or item.name
                        item.display_title = item.display_title or item.title

                        if ok_r and Remote and Remote.getKomgaCoverPath then
                            if item.is_folder or item.is_opds_nav or item.kind == "opds_nav" or item.kind == "folder" then
                                local sid = item.komga_series_id or item.komga_id
                                if not sid and Remote.lookupSeriesIdByTitle then
                                    sid = Remote.lookupSeriesIdByTitle(item.title or item.label)
                                    item.komga_series_id = sid
                                end
                                local cp = item.cover_image_path
                                    or Remote.getKomgaCoverPath("series", sid, item.title or item.label)
                                    or (item.active_book and Remote.getKomgaCoverPath("book", item.active_book.id, item.active_book.name, sid))
                                    or (item.first_book and item.first_book.cover_image_path)

                                if cp then
                                    item.cover_image_path = cp
                                    item.has_cover = true
                                    if item.first_book then
                                        item.first_book.cover_image_path = item.first_book.cover_image_path or cp
                                        item.first_book.has_cover = true
                                    else
                                        item.first_book = {
                                            filepath = item.path or item.filepath,
                                            cover_image_path = cp,
                                            title = item.title or item.label,
                                            has_cover = true,
                                        }
                                    end
                                else
                                    item.first_book = item.first_book or {
                                        filepath = item.path or item.filepath,
                                        title = item.title or item.label,
                                        has_cover = false,
                                    }
                                end
                            else
                                local cp = item.cover_image_path
                                    or Remote.getKomgaCoverPath("book", item.komga_book_id or item.komga_id, item.title, item.komga_series_id)
                                    or (item.komga_series_id and Remote.getKomgaCoverPath("series", item.komga_series_id, item.series_name or item.title))
                                if cp then
                                    item.cover_image_path = cp
                                    item.has_cover = true
                                elseif item.downloaded or (item.filepath and not item.filepath:find("^%a+://")) then
                                    item.has_cover = true
                                end
                            end
                        end
                    end
                end
            end
            local row = orig_ShelfRow_new(opts)
            if row and opts and opts.items and (opts.show_titles or opts.label_mode ~= "none") then
                local function hasText(w)
                    if not w then return false end
                    if w.text and w.text ~= "" then return true end
                    for _, c in ipairs(w) do
                        if hasText(c) then return true end
                    end
                    return false
                end

                local slot_w = opts.slot_w or opts.cover_w or 120
                local label_gap = opts.label_gap or 4
                local TextWidget = require("ui/widget/textwidget")
                local VerticalSpan = require("ui/widget/verticalspan")

                local item_idx = 1
                for _, slot in ipairs(row) do
                    -- In ShelfRow, slots are InputContainers wrapping stack VerticalGroup, alternating with HorizontalSpans.
                    -- A slot container has child widgets (slot[1] is the stack VerticalGroup) and slot[1][1] is the tile.
                    if type(slot) == "table" and type(slot[1]) == "table" and slot[1][1] then
                        local item = opts.items[item_idx]
                        item_idx = item_idx + 1
                        if item and (item.is_folder or item.kind == "folder" or item.kind == "opds_nav" or item.komga_series_id or item.books or item.series_name) then
                            local already_has_text = hasText(slot)
                            local target_name = item.label or item.title or item.series_name or item.name
                            debugLog(string.format("[SHELF_ROW] slot=%d item=%s has_text=%s",
                                item_idx - 1, tostring(target_name), tostring(already_has_text)))
                            if not already_has_text and type(target_name) == "string" and target_name ~= "" then
                                local stack = slot[1]
                                stack[2] = VerticalSpan:new{ width = label_gap }
                                stack[3] = TextWidget:new{
                                    text = target_name,
                                    face = opts.title_face or "infofont",
                                    bold = false,
                                    max_width = slot_w,
                                }
                            end
                        end
                    end
                end
            end
            return row
        end
        ShelfRow._hybrid_patched = true
        logger.info("[Hybrid] Hooked ShelfRow.new for hybrid titles and covers")
    end
end

function M.installStartupPatch()
    local ok_w, BookshelfWidget = pcall(require, "lib/bookshelf_widget")
    if ok_w and BookshelfWidget and BookshelfWidget._openGearMenu and not BookshelfWidget._hybrid_gear_patched then
        local orig_openGearMenu = BookshelfWidget._openGearMenu
        BookshelfWidget._openGearMenu = function(self_w)
            local ButtonDialog = require("ui/widget/buttondialog")
            local bw = self_w
            local dialog
            local function closing(fn)
                return function()
                    if fn then fn() end
                    local UIManager = require("ui/uimanager")
                    UIManager:close(dialog)
                end
            end

            local is_enabled = (G_reader_settings:readSetting("start_with") == "bookshelf")
                or (G_reader_settings:isTrue("bookshelf_launch_on_startup"))

            dialog = ButtonDialog:new{
                title = "Bookshelf",
                buttons = {
                    {
                        {
                            text = is_enabled and _("\xe2\x9c\x93 Launch Bookshelf on startup")
                                           or  _("Launch Bookshelf on startup"),
                            callback = closing(function()
                                local new_val = not is_enabled
                                if new_val then
                                    G_reader_settings:saveSetting("start_with", "bookshelf")
                                    G_reader_settings:saveSetting("bookshelf_launch_on_startup", true)
                                else
                                    G_reader_settings:saveSetting("start_with", "filemanager")
                                    G_reader_settings:delSetting("bookshelf_launch_on_startup")
                                end
                                G_reader_settings:flush()
                                local ok_notif, Notification = pcall(require, "ui/widget/notification")
                                local msg = new_val and _("Bookshelf will launch on startup")
                                                     or _("Bookshelf startup launch disabled")
                                local UIManager = require("ui/uimanager")
                                if ok_notif and Notification then
                                    UIManager:show(Notification:new{ text = msg })
                                else
                                    local ok_info, InfoMessage = pcall(require, "ui/widget/infomessage")
                                    if ok_info and InfoMessage then
                                        UIManager:show(InfoMessage:new{ text = msg, timeout = 2 })
                                    end
                                end
                            end),
                        },
                    },
                    {
                        { text = "Browse files\xe2\x80\xa6",
                          callback = closing(function() bw:_browseFiles() end) },
                    },
                    {
                        { text = "Settings\xe2\x80\xa6",
                          callback = closing(function() require("lib/bookshelf_settings"):show(bw) end) },
                        { text = "About",
                          callback = closing(function() require("lib/bookshelf_settings"):_about() end) },
                    },
                    {
                        { text = "Cancel", callback = closing() },
                    },
                },
            }
            local UIManager = require("ui/uimanager")
            UIManager:show(dialog)
        end
        BookshelfWidget._hybrid_gear_patched = true
        logger.info("[Hybrid] Hooked BookshelfWidget._openGearMenu for startup toggle")
    end

    local ok_bs, Settings = pcall(require, "lib/bookshelf_settings")
    if ok_bs and Settings and Settings._behaviourSubItems and not Settings._hybrid_startup_patched then
        local orig_behaviour = Settings._behaviourSubItems
        Settings._behaviourSubItems = function(self_s)
            local items = orig_behaviour(self_s) or {}
            local is_enabled = function()
                return (G_reader_settings:readSetting("start_with") == "bookshelf")
                    or (G_reader_settings:isTrue("bookshelf_launch_on_startup"))
            end
            local toggle_startup = function(touchmenu_instance)
                local new_val = not is_enabled()
                if new_val then
                    G_reader_settings:saveSetting("start_with", "bookshelf")
                    G_reader_settings:saveSetting("bookshelf_launch_on_startup", true)
                else
                    G_reader_settings:saveSetting("start_with", "filemanager")
                    G_reader_settings:delSetting("bookshelf_launch_on_startup")
                end
                G_reader_settings:flush()
                if touchmenu_instance and touchmenu_instance.updateItems then
                    touchmenu_instance:updateItems()
                end
            end
            table.insert(items, 1, {
                text = _("Launch Bookshelf on startup"),
                checked_func = is_enabled,
                callback = toggle_startup,
                separator = true,
            })
            return items
        end
        Settings._hybrid_startup_patched = true
        logger.info("[Hybrid] Hooked BookshelfSettings._behaviourSubItems for startup toggle")
    end
end

function M.installSpineShelfPatch()
    local ok_ss, SpineShelf = pcall(require, "lib/bookshelf_spine_shelf")
    if not (ok_ss and SpineShelf) then return end
    if SpineShelf._hybrid_spines_patched then return end
    SpineShelf._hybrid_spines_patched = true

    -- 1. Hook SpineShelf.plan to enforce pagination fallback (no expensive scanning)
    local orig_plan = SpineShelf.plan
    SpineShelf.plan = function(items, opts)
        if items and type(items) == "table" then
            for i = 1, #items do
                local it = items[i]
                if it and type(it) == "table" then
                    if not it.page_count or it.page_count <= 0 then
                        it.page_count = (it.komga_dto and it.komga_dto.media and it.komga_dto.media.pagesCount and it.komga_dto.media.pagesCount > 0 and it.komga_dto.media.pagesCount)
                            or (it.active_book and it.active_book.media and it.active_book.media.pagesCount and it.active_book.media.pagesCount > 0 and it.active_book.media.pagesCount)
                            or 200
                    end
                    if it.first_book and (not it.first_book.page_count or it.first_book.page_count <= 0) then
                        it.first_book.page_count = it.page_count
                    end
                    if it.is_remote or it.source_kind == "hybrid" or it.is_komga then
                        it._spine_status_checked = true
                    end
                end
            end
        end
        return orig_plan(items, opts)
    end

    -- 2. Hook SpineShelf.bookLook to sample cover tone and aspect from cached cover image
    local orig_bookLook = SpineShelf.bookLook
    SpineShelf.bookLook = function(book)
        local fp = book and (book.cover_image_path or (book.first_book and book.first_book.cover_image_path))
        if fp and (book.is_remote or book.source_kind == "hybrid" or book.is_komga or not book.filepath or (type(book.filepath) == "string" and book.filepath:find("^%a+://"))) then
            local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
            if ok_lfs and lfs and lfs.attributes and lfs.attributes(fp, "mode") == "file" then
                local ok_ri, RenderImage = pcall(require, "ui/renderimage")
                if ok_ri and RenderImage and RenderImage.renderImageFile then
                    local ok_bb, bb = pcall(RenderImage.renderImageFile, RenderImage, fp, 60, 90)
                    if ok_bb and bb then
                        local w, h = bb:getWidth(), bb:getHeight()
                        local aspect = (w and h and w > 0) and (h / w) or 1.5
                        local n, r, g, b = 0, 0, 0, 0
                        local steps = 8
                        for sy = 0, steps - 1 do
                            for sx = 0, steps - 1 do
                                local px = math.floor((sx + 0.5) * w / steps)
                                local py = math.floor((sy + 0.5) * h / steps)
                                local p = bb:getPixel(px, py)
                                local c = p and p.getColorRGB32 and p:getColorRGB32() or nil
                                if c then
                                    n = n + 1
                                    r = r + c.r; g = g + c.g; b = b + c.b
                                end
                            end
                        end
                        if bb.free then bb:free() end
                        if n > 0 then
                            r = math.floor(r / n + 0.5)
                            g = math.floor(g / n + 0.5)
                            b = math.floor(b / n + 0.5)
                            local luma = 0.299 * r + 0.587 * g + 0.114 * b
                            if luma > 180 and luma > 0 then
                                local factor = 180 / luma
                                r = math.floor(r * factor + 0.5)
                                g = math.floor(g * factor + 0.5)
                                b = math.floor(b * factor + 0.5)
                            end
                            return { r = r, g = g, b = b, aspect = aspect, sampled = true }
                        end
                    end
                end
            end
        end
        return orig_bookLook(book)
    end

    -- 3. Hook SpineBookSlot gesture dispatch
    local Slot = SpineShelf._SpineBookSlot
    if Slot and not Slot._hybrid_gesture_patched then
        Slot._hybrid_gesture_patched = true
        local orig_onTap = Slot.onTap
        Slot.onTap = function(self_slot, arg, ges)
            local item = self_slot.book
            local cbs = self_slot.callbacks
            -- Real book records always dispatch to native book callbacks (hero selection, open)
            if item and not item.is_folder and not item.is_opds_nav and item.kind ~= "folder" and item.kind ~= "opds_nav" and item.filepath then
                return orig_onTap(self_slot, arg, ges)
            end
            if cbs and item and (item.is_folder or item.kind == "folder" or item.kind == "opds_nav" or item.is_opds_nav) then
                local cb = nil
                if item.kind == "opds_nav" or item.is_opds_nav then
                    cb = cbs.on_opds_nav_tap
                elseif item.is_folder or item.kind == "folder" then
                    cb = cbs.on_folder_tap
                end
                if cb then
                    SpineShelf.last_tapped_slot = self_slot
                    cb(item)
                    return true
                end
            end
            return orig_onTap(self_slot, arg, ges)
        end

        local orig_onHold = Slot.onHold
        Slot.onHold = function(self_slot)
            local item = self_slot.book
            local cbs = self_slot.callbacks
            -- Real book records always dispatch to native book hold callback
            if item and not item.is_folder and not item.is_opds_nav and item.kind ~= "folder" and item.kind ~= "opds_nav" and item.filepath then
                return orig_onHold(self_slot)
            end
            if cbs and item and (item.is_folder or item.kind == "folder" or item.kind == "opds_nav" or item.is_opds_nav) then
                local cb = nil
                if item.kind == "opds_nav" or item.is_opds_nav then
                    cb = cbs.on_opds_nav_hold
                elseif item.is_folder or item.kind == "folder" then
                    cb = cbs.on_folder_hold
                end
                if cb then
                    cb(item)
                    return true
                end
            end
            return orig_onHold(self_slot)
        end
    end

    -- 4. Hook Komga and OPDS specs for Spines shelf expansion
        local ok_s, Sources = pcall(require, "lib/bookshelf_sources")
        if ok_s and Sources then
            local function wrapSpec(kind, spec)
                if not spec or spec._spine_wrapped then return end
                spec._spine_wrapped = true
                local orig_fetch = spec.fetch
                spec.fetch = function(source, drill, offset, limit)
                    local ok_r, Repo = pcall(require, "lib/bookshelf_book_repository")
                    local is_spine = (ok_r and Repo and Repo.spine_light == true)
                    if not is_spine or drill then
                        return orig_fetch(source, drill, offset, limit)
                    end

                    local records, total = orig_fetch(source, nil, 0, 100000)
                    if not records or #records == 0 then
                        return records, total
                    end

                    local ok_rem, Remote = pcall(require, "lib/hybrid_remote")
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

                    for i = 1, #records do
                        local entry = records[i]
                        if entry.is_folder or entry.kind == "folder" or entry.is_series or entry.komga_series_id or (type(entry.path) == "string" and entry.path:find("^komga://series/")) then
                            if ok_rem and Remote and Remote.expandSeriesToBooks then
                                local books = Remote.expandSeriesToBooks(source, entry, nil, nil)
                                for _, b in ipairs(books) do
                                    local k = spineKey(b)
                                    if not k or not seen_spine_keys[k] then
                                        if k then seen_spine_keys[k] = true end
                                        spine_books[#spine_books + 1] = b
                                    end
                                end
                            else
                                local k = spineKey(entry)
                                if not k or not seen_spine_keys[k] then
                                    if k then seen_spine_keys[k] = true end
                                    spine_books[#spine_books + 1] = entry
                                end
                            end
                        else
                            entry.shelf_section = entry.shelf_section or nil
                            entry.is_folder = false
                            entry.is_series = false
                            entry.kind = "book"
                            entry.page_count = (entry.page_count and entry.page_count > 0 and entry.page_count) or 200
                            local k = spineKey(entry)
                            if not k or not seen_spine_keys[k] then
                                if k then seen_spine_keys[k] = true end
                                spine_books[#spine_books + 1] = entry
                            end
                        end
                    end

                    local tot = #spine_books
                    local off = offset or 0
                    local lim = limit or tot
                    local page = {}
                    for i = off + 1, math.min(off + lim, tot) do
                        page[#page + 1] = spine_books[i]
                    end
                    return page, tot
                end
            end

            for _, k in ipairs({ "komga", "opds" }) do
                if Sources.get then wrapSpec(k, Sources.get(k)) end
            end

            if Sources.register and not Sources._spine_register_hooked then
                Sources._spine_register_hooked = true
                local orig_reg = Sources.register
                Sources.register = function(kind, spec)
                    orig_reg(kind, spec)
                    if kind == "komga" or kind == "opds" then
                        wrapSpec(kind, spec)
                    end
                end
            end
        end

    logger.info("[Hybrid] Hooked SpineShelf for Spines view support")
end

function M.installAll()
    M.installWidgetPatch()
    M.installEditorPatch()
    M.installShelfRowPatch()
    M.installSpineShelfPatch()
    M.installStartupPatch()
end

return M
