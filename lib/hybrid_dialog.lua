-- lib/hybrid_dialog.lua
-- Action dialog and download manager for remote/hybrid items in Bookshelf.

local UIManager = require("ui/uimanager")
local ButtonDialog = require("ui/widget/buttondialog")
local Notification = require("ui/widget/notification")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local _ = require("gettext")
local T = function(fmt, ...)
    local ok_fu, ffiutil = pcall(require, "ffi/util")
    if ok_fu and ffiutil and ffiutil.template then
        return ffiutil.template(fmt, ...)
    end
    local args = {...}
    return (fmt:gsub("%%(%d+)", function(n) return tostring(args[tonumber(n)] or "") end))
end
local logger = require("logger")

local Remote = require("lib/hybrid_remote")
local Dedup = require("lib/hybrid_dedup")

local M = {}

local function getBookTitle(book)
    return (book and (book.title or book.display_title or book.filename)) or _("Unknown Title")
end

local function getBookId(book)
    if type(book) ~= "table" then return nil end
    local id = book.komga_book_id or book.komga_id
        or (type(book.filepath) == "string" and book.filepath:match("^komga://book/(.+)$"))
    if type(id) == "string" and id ~= "" then return id end
    if type(id) == "number" then return tostring(id) end
    return nil
end

local function isSafeAbsPath(p)
    return type(p) == "string" and p:sub(1, 1) == "/" and not p:find("%.%.", 1, true)
end

local function getDownloadedPath(book)
    if type(book) ~= "table" then return nil end
    local downloaded = Dedup.getDownloadedMap()
    local book_id = getBookId(book)
    local rec_key = book_id and ("komga://book/" .. book_id) or nil

    local p = (rec_key and downloaded[rec_key])
        or (type(book.filepath) == "string" and downloaded[book.filepath])
        or (type(book.filepath) == "string" and not book.filepath:find("^%a+://") and book.filepath)

    if isSafeAbsPath(p) then
        local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
        if ok_lfs and lfs and lfs.attributes and lfs.attributes(p, "mode") == "file" then
            return p
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- 1. Main Book Action Dialog
-- ---------------------------------------------------------------------------

function M.showBookActionDialog(book, widget, after_open_callback, opts)
    if not book then return end
    opts = opts or {}

    local title = getBookTitle(book)
    local book_id = getBookId(book)
    local local_path = getDownloadedPath(book)
    local is_downloaded = local_path ~= nil

    -- Status determination
    local status = book.status or book.read_status or "unread"
    local is_finished = (status == "finished")
    local pct_str = ""
    if book.percent_finished and book.percent_finished > 0 and book.percent_finished < 1 then
        pct_str = string.format(" (%d%%)", math.floor(book.percent_finished * 100))
    end

    local status_label = is_finished and _("Finished")
        or (status == "reading" and (_("Reading") .. pct_str))
        or _("Unread")

    local format_label = (book.format or book.ext or "CBZ"):upper()

    -- Subtitle / description info
    local info_lines = {}
    if book.series_name and book.series_name ~= "" then
        local num_str = book.series_num and (" #" .. tostring(book.series_num)) or ""
        info_lines[#info_lines + 1] = T(_("Series: %1%2"), book.series_name, num_str)
    end
    if book.author and book.author ~= "" then
        info_lines[#info_lines + 1] = T(_("Author: %1"), book.author)
    end
    info_lines[#info_lines + 1] = T(_("Format: %1 | Status: %2"), format_label, status_label)
    if is_downloaded then
        info_lines[#info_lines + 1] = _("Status: Downloaded on device")
    else
        info_lines[#info_lines + 1] = _("Status: Remote (Not downloaded)")
    end

    local dialog = nil
    local buttons = {}

    if not is_downloaded then
        -- Row 1: Download & Open
        buttons[#buttons + 1] = {
            {
                text = _("Download & Open"),
                callback = function()
                    UIManager:close(dialog)
                    M.startDownload(book, widget, {
                        open_after = true,
                        after_open_callback = after_open_callback,
                    })
                end,
            },
        }

        -- Row 2: Download in Background
        buttons[#buttons + 1] = {
            {
                text = _("Download in Background"),
                callback = function()
                    UIManager:close(dialog)
                    M.startDownload(book, widget, {
                        open_after = false,
                    })
                end,
            },
        }
    else
        -- Row 1: Open
        buttons[#buttons + 1] = {
            {
                text = _("Open Book"),
                callback = function()
                    UIManager:close(dialog)
                    if widget and widget._launchReader then
                        widget:_launchReader(local_path, after_open_callback)
                    end
                end,
            },
        }

        -- Row 2: Delete Local Copy
        buttons[#buttons + 1] = {
            {
                text = _("Delete Local File"),
                callback = function()
                    UIManager:close(dialog)
                    M.confirmDelete(book, local_path, widget)
                end,
            },
        }
    end

    -- Row 3: Mark as Read / Unread & Book Details
    local read_btn_text = is_finished and _("Mark as Unread") or _("Mark as Read")
    buttons[#buttons + 1] = {
        {
            text = read_btn_text,
            callback = function()
                UIManager:close(dialog)
                M.toggleReadStatus(book, widget, not is_finished)
            end,
        },
        {
            text = _("Book Details"),
            callback = function()
                UIManager:close(dialog)
                M.showBookDetails(book)
            end,
        },
    }

    -- Row 4: Cancel
    buttons[#buttons + 1] = {
        {
            text = _("Cancel"),
            callback = function()
                UIManager:close(dialog)
            end,
        },
    }

    dialog = ButtonDialog:new{
        title = title,
        title_align = "center",
        info_text = table.concat(info_lines, "\n"),
        buttons = buttons,
    }

    UIManager:show(dialog)
end

-- ---------------------------------------------------------------------------
-- 2. Download Execution (Foreground & Background)
-- ---------------------------------------------------------------------------

function M.startDownload(book, widget, opts)
    opts = opts or {}
    local open_after = opts.open_after
    local title = getBookTitle(book)

    -- Check network connectivity
    local ok_net, NetworkMgr = pcall(require, "ui/network/manager")
    if ok_net and NetworkMgr and NetworkMgr.isConnected and not NetworkMgr:isConnected() then
        if not opts._wifi_prompted and NetworkMgr.promptWifiConnection then
            local retry_opts = {}
            for k, v in pairs(opts) do retry_opts[k] = v end
            retry_opts._wifi_prompted = true
            NetworkMgr:promptWifiConnection(function()
                M.startDownload(book, widget, retry_opts)
            end)
            return
        else
            UIManager:show(Notification:new{ text = _("Wi-Fi connection required to download.") })
            return
        end
    end

    if open_after then
        local notice = InfoMessage:new{
            text = T(_("Downloading %1..."), title),
        }
        UIManager:show(notice)

        local settled = false
        local function closeNotice()
            if notice then
                local n = notice
                notice = nil
                pcall(function() UIManager:close(n) end)
            end
        end

        local ok_call, res_or_err, err_detail = pcall(Remote.downloadKomgaBook, book, opts, function(downloaded_path)
            settled = true
            closeNotice()

            if type(downloaded_path) ~= "string" or downloaded_path == "" then
                logger.err("[Hybrid] Foreground download returned invalid path for", title)
                UIManager:show(Notification:new{
                    text = T(_("Download failed: %1"), "invalid path"),
                })
                return
            end

            book.filepath = downloaded_path
            book.downloaded = true
            book.is_remote = false

            local ok_s, Sources = pcall(require, "lib/bookshelf_sources")
            if ok_s and Sources and Sources.changed then
                Sources.changed("hybrid")
            elseif widget and widget._rebuild then
                widget:_rebuild()
                UIManager:setDirty(widget, "ui")
            end

            -- Automatically open the downloaded book in ReaderUI
            if widget and widget._launchReader then
                widget:_launchReader(downloaded_path, opts.after_open_callback)
            end
        end, function(err)
            settled = true
            closeNotice()
            logger.err("[Hybrid] Foreground download failed:", tostring(err))
            UIManager:show(Notification:new{
                text = T(_("Download failed: %1"), tostring(err or "Unknown error")),
            })
        end)

        if not ok_call then
            closeNotice()
            logger.err("[Hybrid] Foreground download threw:", tostring(res_or_err))
            UIManager:show(Notification:new{
                text = T(_("Download failed: %1"), tostring(res_or_err or "Unknown error")),
            })
        elseif not settled and res_or_err == false then
            closeNotice()
            logger.err("[Hybrid] Foreground download rejected:", tostring(err_detail or "Unknown error"))
            UIManager:show(Notification:new{
                text = T(_("Download failed: %1"), tostring(err_detail or "Unknown error")),
            })
        end
    else
        -- Background Download
        UIManager:show(Notification:new{
            text = T(_("Downloading %1 in background…"), title),
            timeout = 3,
        })

        local ok_call, res_or_err = pcall(Remote.downloadKomgaBook, book, opts, function(path)
            if type(path) ~= "string" or path == "" then
                logger.err("[Hybrid] Background download returned invalid path for", title)
                return
            end
            book.filepath = path
            book.downloaded = true
            book.is_remote = false

            UIManager:show(Notification:new{
                text = T(_("Downloaded: %1"), title),
                timeout = 4,
            })

            local ok_s, Sources = pcall(require, "lib/bookshelf_sources")
            if ok_s and Sources and Sources.changed then
                Sources.changed("hybrid")
            elseif widget and widget._rebuild then
                widget:_rebuild()
                UIManager:setDirty(widget, "ui")
            end
        end, function(err)
            logger.err("Background download failed:", tostring(err))
            UIManager:show(Notification:new{
                text = T(_("Download failed for %1: %2"), title, tostring(err or "Error")),
                timeout = 5,
            })
        end)
        if not ok_call then
            logger.err("Background download threw:", tostring(res_or_err))
            UIManager:show(Notification:new{
                text = T(_("Download failed for %1: %2"), title, tostring(res_or_err or "Error")),
                timeout = 5,
            })
        end
    end
end

-- ---------------------------------------------------------------------------
-- 3. Read Status Sync & Book Details
-- ---------------------------------------------------------------------------

function M.toggleReadStatus(book, widget, mark_as_read)
    local book_id = getBookId(book)
    if not book_id then
        UIManager:show(Notification:new{ text = _("Unable to identify Komga book ID.") })
        return
    end

    local title = getBookTitle(book)
    local ok, res = Remote.setKomgaReadProgress(book_id, mark_as_read)
    local is_queued = (not ok) and (res == "queued")
    if ok or is_queued then
        book.status = mark_as_read and "finished" or "unread"
        book.read_status = book.status
        book.book_pct = mark_as_read and 1 or 0
        book.percent_finished = book.book_pct

        local msg
        if is_queued then
            msg = mark_as_read and T(_("Marked '%1' as finished (queued for sync)"), title)
                or T(_("Marked '%1' as unread (queued for sync)"), title)
        else
            msg = mark_as_read and T(_("Marked '%1' as finished"), title)
                or T(_("Marked '%1' as unread"), title)
        end
        UIManager:show(Notification:new{ text = msg, timeout = 3 })

        local ok_s, Sources = pcall(require, "lib/bookshelf_sources")
        if ok_s and Sources and Sources.changed then
            Sources.changed("hybrid")
        elseif widget and widget._rebuild then
            widget:_rebuild()
            UIManager:setDirty(widget, "ui")
        end
    else
        logger.warn("[Hybrid] toggleReadStatus failed for book", tostring(book_id), tostring(res))
        UIManager:show(Notification:new{
            text = T(_("Failed to update status on Komga: %1"), tostring(res or "Error")),
        })
    end
end

local function formatAuthors(book)
    if type(book) ~= "table" then return nil end
    local raw = book.authors
    local list = {}
    if type(raw) == "string" and raw ~= "" then
        list[1] = raw
    elseif type(raw) == "table" then
        for _, a in ipairs(raw) do
            if type(a) == "string" and a ~= "" then
                list[#list + 1] = a
            elseif type(a) == "table" and type(a.name) == "string" and a.name ~= "" then
                list[#list + 1] = a.name
            end
        end
    end
    if #list == 0 and type(book.author) == "string" and book.author ~= "" then
        list[1] = book.author
    end
    if #list > 0 then
        return table.concat(list, ", ")
    end
    return nil
end

function M.showBookDetails(book)
    local title = getBookTitle(book)
    local lines = {}
    lines[#lines + 1] = title
    lines[#lines + 1] = string.rep("─", 30)

    if book.series_name and book.series_name ~= "" then
        local num = book.series_num and (" #" .. tostring(book.series_num)) or ""
        lines[#lines + 1] = T(_("Series: %1%2"), book.series_name, num)
    end

    local authors_str = formatAuthors(book)
    if authors_str then
        lines[#lines + 1] = T(_("Authors: %1"), authors_str)
    end

    local fmt = (book.format or book.ext or "CBZ"):upper()
    lines[#lines + 1] = T(_("Format: %1"), fmt)

    local status = book.status or book.read_status or "unread"
    local pct = (book.percent_finished and book.percent_finished > 0)
        and string.format(" (%d%%)", math.floor(book.percent_finished * 100)) or ""
    lines[#lines + 1] = T(_("Read Status: %1%2"), status, pct)

    local local_path = getDownloadedPath(book)
    if local_path then
        lines[#lines + 1] = T(_("Local File: %1"), local_path)
    else
        lines[#lines + 1] = _("Local File: Not downloaded")
    end

    local desc = book.description or (book.komga_dto and book.komga_dto.metadata and book.komga_dto.metadata.summary)
    if desc and desc ~= "" then
        lines[#lines + 1] = ""
        lines[#lines + 1] = _("Summary:")
        lines[#lines + 1] = desc
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = _("(Tap anywhere to dismiss)")

    UIManager:show(InfoMessage:new{
        text = table.concat(lines, "\n"),
        timeout = nil,
    })
end

function M.confirmDelete(book, local_path, widget)
    if type(local_path) ~= "string" or local_path == "" then
        UIManager:show(Notification:new{ text = _("No local file to delete.") })
        return
    end
    local title = getBookTitle(book)
    local filename = local_path:match("([^/]+)$") or title

    UIManager:show(ConfirmBox:new{
        text = T(_("Delete local file '%1'?\n\nThe remote entry will remain available on the shelf."), filename),
        ok_text = _("Delete"),
        ok_callback = function()
            local success, del_err = Remote.deleteDownloadedBook(book, local_path)
            if success then
                book.downloaded = false
                book.is_remote = true
                local bid = getBookId(book)
                if bid then
                    book.filepath = "komga://book/" .. bid
                end

                UIManager:show(Notification:new{
                    text = T(_("Deleted local copy of %1"), title),
                    timeout = 3,
                })

                local ok_s, Sources = pcall(require, "lib/bookshelf_sources")
                if ok_s and Sources and Sources.changed then
                    Sources.changed("hybrid")
                elseif widget and widget._rebuild then
                    widget:_rebuild()
                    UIManager:setDirty(widget, "ui")
                end
            else
                logger.warn("[Hybrid] confirmDelete failed:", tostring(del_err))
                UIManager:show(Notification:new{
                    text = T(_("Failed to delete local file: %1"), tostring(del_err or "Error")),
                })
            end
        end,
    })
end

return M
