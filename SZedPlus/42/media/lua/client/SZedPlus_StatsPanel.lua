--- ZED+ : the debug stats window.
---
--- Shows what a zombie actually is - tier, health, walk type - so a Zed+ can be
--- compared against an ordinary zombie side by side. Works on any zombie, not
--- just ours.
---
--- Multiplayer: the values live in server-side modData, so the panel never
--- reads the zombie itself. It asks the server and renders whatever comes back.

SZedPlus = SZedPlus or {}

SZedPlusStatsPanel = ISCollapsableWindow:derive("SZedPlusStatsPanel")

local PADDING = 12
local LINE_HEIGHT = 18

--- The single open instance, so repeated clicks reuse one window.
local instance = nil

function SZedPlusStatsPanel:new(x, y, width, height)
    local o = ISCollapsableWindow:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    o.stats = nil
    o.message = nil
    o:setResizable(false)
    return o
end

function SZedPlusStatsPanel:initialise()
    ISCollapsableWindow.initialise(self)
    self.title = getText("IGUI_SZedPlus_StatsTitle")
end

--- Replace the displayed values.
function SZedPlusStatsPanel:setStats(stats, message)
    self.stats = stats
    self.message = message
end

--- One "label: value" row.
function SZedPlusStatsPanel:drawRow(y, label, value, r, g, b)
    self:drawText(label, PADDING, y, 0.7, 0.7, 0.7, 1, UIFont.Small)
    self:drawText(value, 150, y, r or 1, g or 1, b or 1, 1, UIFont.Small)
    return y + LINE_HEIGHT
end

--- Human-readable state: "T3 fast", "T6 host", or "ordinary zombie".
local function describeState(stats)
    if not stats.isZedPlus then
        return getText("IGUI_SZedPlus_StatsOrdinary"), 0.7, 0.7, 0.7
    end
    local detail = stats.calamity or stats.form or stats.path
    local text = "T" .. tostring(stats.stage or "?")
    if detail then
        text = text .. " " .. tostring(detail)
    end
    return text, 0.6, 0.9, 0.3
end

function SZedPlusStatsPanel:prerender()
    ISCollapsableWindow.prerender(self)

    local y = self:titleBarHeight() + PADDING

    if self.message then
        self:drawText(self.message, PADDING, y, 0.9, 0.6, 0.2, 1, UIFont.Small)
        return
    end

    local stats = self.stats
    if stats == nil then
        self:drawText(getText("IGUI_SZedPlus_StatsNoTarget"), PADDING, y,
            0.7, 0.7, 0.7, 1, UIFont.Small)
        return
    end

    local stateText, r, g, b = describeState(stats)
    y = self:drawRow(y, getText("IGUI_SZedPlus_StatsState"), stateText, r, g, b)

    -- Health, with the multiplier spelled out so the effect of the tier is
    -- visible rather than inferred.
    local healthText = string.format("%.2f", stats.health or 0)
    local hr, hg, hb = 1, 1, 1
    if stats.baseHealth and stats.healthMultiplier then
        healthText = string.format("%.2f  (%.2f x %.2f)",
            stats.health or 0, stats.baseHealth, stats.healthMultiplier)

        -- Flag the case where the engine overwrote what we wrote: the number
        -- on screen is then not the one the tier asked for.
        local expected = stats.expectedHealth
        if expected and math.abs((stats.health or 0) - expected) > 0.01 then
            healthText = string.format("%.2f  (expected %.2f)", stats.health or 0, expected)
            hr, hg, hb = 0.9, 0.4, 0.3
        end
    end
    y = self:drawRow(y, getText("IGUI_SZedPlus_StatsHealth"), healthText, hr, hg, hb)

    local walkText = tostring(stats.walkType or "-")
    if stats.baseWalkType and stats.baseWalkType ~= stats.walkType then
        walkText = string.format("%s  (%s %+d)",
            tostring(stats.walkType), tostring(stats.baseWalkType), stats.speedSteps or 0)
    end
    y = self:drawRow(y, getText("IGUI_SZedPlus_StatsWalkType"), walkText)

    y = self:drawRow(y, getText("IGUI_SZedPlus_StatsSpeedType"),
        tostring(stats.speedType or "-"))

    local flags = {}
    if stats.crawling then flags[#flags + 1] = "crawling" end
    if stats.knockedDown then flags[#flags + 1] = "knocked down" end
    self:drawRow(y, getText("IGUI_SZedPlus_StatsFlags"),
        #flags > 0 and table.concat(flags, ", ") or "-")
end

-- ------------------------------------------------------------------ show --

--- Open (or reuse) the window and display these stats.
function SZedPlus.showStats(stats, message)
    if instance == nil then
        instance = SZedPlusStatsPanel:new(
            getCore():getScreenWidth() / 2 - 170,
            getCore():getScreenHeight() / 2 - 90,
            340, 160)
        instance:initialise()
        instance:instantiate()
        instance:addToUIManager()
    end

    instance:setStats(stats, message)
    instance:setVisible(true)
    instance:addToUIManager()
    instance:bringToTop()
end

--- Server answer in multiplayer.
local function onServerCommand(module, command, args)
    if module ~= "SZedPlus" or command ~= "stats" then return end
    -- The server sends a translation key, never a translated string.
    local message = args and args.messageKey and getText(args.messageKey) or nil
    SZedPlus.showStats(args and args.stats, message)
end

Events.OnServerCommand.Add(onServerCommand)
