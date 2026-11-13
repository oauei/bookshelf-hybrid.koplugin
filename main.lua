-- main.lua
-- Bookshelf Hybrid Shelf Plugin entry point.

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")

local HybridSpec = require("lib/hybrid_spec")
local Patch = require("lib/hybrid_patch")

local HybridPlugin = WidgetContainer:extend{
    name = "bookshelf_hybrid",
    is_doc_only = false,
}

local function liveModule(name)
    for _, mod in ipairs({ "apps/filemanager/filemanager", "apps/reader/readerui" }) do
        local ok, m = pcall(require, mod)
        local found = ok and m and m.instance and m.instance[name]
        if found then return found end
    end
end

function HybridPlugin:registerWithBookshelf()
    local bookshelf = (self.ui and self.ui.bookshelf) or liveModule("bookshelf")
    if not (bookshelf and type(bookshelf.registerSource) == "function") then
        local ok_s, Sources = pcall(require, "lib/bookshelf_sources")
        if ok_s and Sources and type(Sources.register) == "function" then
            local ok, accepted = pcall(Sources.register, "hybrid", HybridSpec.SPEC)
            if ok and accepted then
                logger.info("[Hybrid] Registered 'hybrid' source directly with BookshelfSources")
                Patch.installAll()
                return true
            end
        end
        return false
    end

    local ok, accepted = pcall(bookshelf.registerSource, bookshelf, "hybrid", HybridSpec.SPEC)
    if ok and accepted then
        logger.info("[Hybrid] Registered 'hybrid' source with Bookshelf instance")
        Patch.installAll()
        return true
    end
    return false
end

local _startup_checked = false
local function checkStartupLaunch(self_p)
    if _startup_checked then return end
    _startup_checked = true

    local is_enabled = false
    if _G.G_reader_settings then
        is_enabled = (_G.G_reader_settings:readSetting("start_with") == "bookshelf")
            or (_G.G_reader_settings:isTrue("bookshelf_launch_on_startup"))
    end
    if not is_enabled then return end

    local ok_ui, UIManager = pcall(require, "ui/uimanager")
    if not (ok_ui and UIManager and UIManager.nextTick) then return end

    UIManager:nextTick(function()
        if self_p.ui and self_p.ui.document then return end
        local bookshelf = (self_p.ui and self_p.ui.bookshelf) or liveModule("bookshelf")
        if bookshelf and type(bookshelf.show) == "function" then
            if not (bookshelf._isShowing and bookshelf:_isShowing()) then
                logger.info("[Hybrid] Launching Bookshelf on startup")
                bookshelf:show()
            end
        end
    end)
end

function HybridPlugin:init()
    HybridPlugin.instance = self

    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end

    logger.info("[Hybrid] Initializing Bookshelf Hybrid Shelf Plugin...")
    Patch.installAll()
    HybridSpec.installSourceForwarding()
    self:registerWithBookshelf()
    checkStartupLaunch(self)
end

function HybridPlugin:addToMainMenu(menu_items)
    -- Ensure registration and patches whenever main menu builds
    Patch.installAll()
    HybridSpec.installSourceForwarding()
    self:registerWithBookshelf()
end

function HybridPlugin:onReaderReady()
    Patch.installAll()
    HybridSpec.installSourceForwarding()
    self:registerWithBookshelf()
    checkStartupLaunch(self)
end

return HybridPlugin
