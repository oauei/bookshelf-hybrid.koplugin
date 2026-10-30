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
                        return Repo.getBySource(src, nil, nil, offset, LIMIT, {})
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

    logger.info("[Hybrid] Hooked BookshelfWidget start feed and effective tab methods")
end

-- ---------------------------------------------------------------------------
-- 2. Patch BookshelfChipEditor for Sort Rows, Filters, and Catalog Settings
-- ---------------------------------------------------------------------------

function M.installEditorPatch()
    local ok_ed, Editor = pcall(require, "lib/bookshelf_chip_editor")
    if not (ok_ed and Editor and Editor.editTab) then return end
    if Editor._hybrid_editor_patched then return end
    Editor._hybrid_editor_patched = true

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
                text = _("Close"),
                callback = function()
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

    logger.info("[Hybrid] Hooked BookshelfChipEditor for catalog settings")
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
                                local cp = item.cover_image_path or Remote.getKomgaCoverPath("series", item.komga_series_id or item.komga_id, item.title or item.label)
                                if cp then
                                    item.cover_image_path = cp
                                    item.has_cover = true
                                    item.first_book = item.first_book or {
                                        filepath = item.path or item.filepath,
                                        cover_image_path = cp,
                                        title = item.title or item.label,
                                        has_cover = true,
                                    }
                                else
                                    item.first_book = item.first_book or {
                                        filepath = item.path or item.filepath,
                                        title = item.title or item.label,
                                        has_cover = false,
                                    }
                                end
                            else
                                local cp = item.cover_image_path or Remote.getKomgaCoverPath("book", item.komga_book_id or item.komga_id, item.title)
                                if cp then
                                    item.cover_image_path = cp
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

function M.installAll()
    M.installWidgetPatch()
    M.installEditorPatch()
    M.installShelfRowPatch()
    M.installStartupPatch()
end

return M
