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
    if not book then return nil end
    return book.komga_book_id or book.komga_id
        or (type(book.filepath) == "string" and book.filepath:match("^komga://book/(.+)$"))
end

local function getDownloadedPath(book)
    if not book then return nil end
    local downloaded = Dedup.getDownloadedMap()
    local book_id = getBookId(book)
    local rec_key = "komga://book/" .. tostring(book_id or "")

    local p = downloaded[rec_key]
        or (type(book.filepath) == "string" and downloaded[book.filepath])
        or (type(book.filepath) == "string" and not book.filepath:find("^%a+://") and book.filepath)

    if p and p ~= "" then
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
        if NetworkMgr.promptWifiConnection then
            NetworkMgr:promptWifiConnection(function()
                M.startDownload(book, widget, opts)
            end)
            return
        else
            UIManager:show(Notification:new{ text = _("Wi-Fi connection required to download.") })
            return
        end
    end

    local dest_path = Remote.resolveDownloadDestination(book)

    if open_after then
        local notice = InfoMessage:new{
            text = T(_("Downloading %1..."), title),
        }
        UIManager:show(notice)

        Remote.downloadKomgaBook(book, opts, function(downloaded_path)
            pcall(function() if notice then UIManager:close(notice) end end)

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
            pcall(function() if notice then UIManager:close(notice) end end)
            UIManager:show(Notification:new{
                text = T(_("Download failed: %1"), tostring(err or "Unknown error")),
            })
        end)
    else
        -- Background Download
        UIManager:show(Notification:new{
            text = T(_("Downloading %1 in background…"), title),
            timeout = 3,
        })

        Remote.downloadKomgaBook(book, opts, function(path)
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
    if ok then
        book.status = mark_as_read and "finished" or "unread"
        book.read_status = book.status
        book.book_pct = mark_as_read and 1 or 0
        book.percent_finished = book.book_pct

        local msg = mark_as_read and T(_("Marked '%1' as finished"), title)
            or T(_("Marked '%1' as unread"), title)
        UIManager:show(Notification:new{ text = msg, timeout = 3 })

        local ok_s, Sources = pcall(require, "lib/bookshelf_sources")
        if ok_s and Sources and Sources.changed then
            Sources.changed("hybrid")
        elseif widget and widget._rebuild then
            widget:_rebuild()
            UIManager:setDirty(widget, "ui")
        end
    else
        UIManager:show(Notification:new{
            text = T(_("Failed to update status on Komga: %1"), tostring(res or "Error")),
        })
    end
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

    local authors = book.authors or (book.author and { book.author })
    if authors and #authors > 0 then
        lines[#lines + 1] = T(_("Authors: %1"), table.concat(authors, ", "))
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
    local title = getBookTitle(book)
    local filename = local_path:match("([^/]+)$") or title

    UIManager:show(ConfirmBox:new{
        text = T(_("Delete local file '%1'?\n\nThe remote entry will remain available on the shelf."), filename),
        ok_text = _("Delete"),
        ok_callback = function()
            local success = Remote.deleteDownloadedBook(book, local_path)
            if success then
                book.downloaded = false
                book.is_remote = true
                book.filepath = "komga://book/" .. tostring(getBookId(book) or "")

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
                UIManager:show(Notification:new{ text = _("Failed to delete local file.") })
            end
        end,
    })
end

return M
