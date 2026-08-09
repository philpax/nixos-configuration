-- Live scoreboard client.
--
-- Responsibilities:
--   * Show/hide the NUI overlay while the scoreboard key (Tab) is held,
--     or via /scoreboard.
--   * Report this player's ped state to the server once a second.
--   * Detect kills and deaths locally from gameEventTriggered, classify the
--     victim (player vs NPC), and report to the server.
--
-- Kill/death detection notes (researched, Aug 2026):
--   * The reliable kill/damage game event is `CEventNetworkEntityDamage`
--     (the commonly-guessed `CEventShockingEventPedKilledByPlayer` etc. are
--     NOT real events in current FiveM).
--   * Its args are reverse of the common guess: args[1] = VICTIM ped,
--     args[2] = killer/culprit ped (or -1 for falls/vehicles), args[4] = 1
--     when the damage was fatal. Some builds report the death flag at
--     args[6] instead (undocumented variance), so we accept either.
--   * The event fires on the client that is a party to the damage, so our
--     own death shows up with args[1] == PlayerPedId(), and our own kills
--     with args[2] == PlayerPedId().
--   * Death has no netId, so the death tally can only come from the victim's
--     client — that's us, and we guard against double-fires.

-- The scoreboard key. Tab is NOT safe in freeroam (weapon wheel) and F12 is
-- the screenshot key; F2 is vMenu's noclip toggle in this config (see
-- vmenu_noclip_toggle_key in fivem.nix) and F8 is the FiveM console, so none
-- of those. F5 is unbound in both vanilla GTA V and this config — and it's
-- rebindable via Esc > Settings > Key Bindings > FiveM.
--
-- F5 has no native gameplay control index to press-poll, so we toggle on the
-- key-mapping command: press F5 to show, press again (or die / open a menu)
-- to hide. Combined with auto-hide on death and pause this behaves like a
-- hold-to-show without fighting the weapon wheel.

local overlayVisible = false

local function setOverlay(visible)
    if overlayVisible == visible then
        return
    end
    overlayVisible = visible
    SendNUIMessage({ type = 'setVisible', visible = visible })
end

-- ---------------------------------------------------------------------------
-- Local ped state (reported to the server every second)
-- ---------------------------------------------------------------------------

local function currentVehicleName()
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    if veh == 0 then
        return ''
    end
    return GetDisplayNameFromVehicleModel(GetEntityModel(veh))
end

-- No ping: GetPlayerPing is a CFX server native with no client counterpart, so
-- calling it here threw every tick into the pcall below and no report ever
-- reached the server. The server reads it instead.
local function reportState()
    TriggerServerEvent('scoreboard:report', {
        vehicle = currentVehicleName(),
        alive = not IsPedDeadOrDying(PlayerPedId(), true),
        pedModel = GetEntityModel(PlayerPedId()),
    })
end

-- Startup handshake: tells the server this client script loaded and is about
-- to start reporting. Lets us distinguish "client script never loaded" from
-- "reports aren't flowing" in the server log.
AddEventHandler('onClientResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then
        return
    end
    TriggerServerEvent('scoreboard:hello')
end)

-- The pcall keeps a bad frame from killing the thread, but a swallowed error is
-- indistinguishable from the server not listening, so print the first one.
CreateThread(function()
    local warned = false
    while true do
        Wait(1000)
        local ok, err = pcall(reportState)
        if not ok and not warned then
            warned = true
            print(('[scoreboard] report failed, scoreboard will be empty: %s'):format(err))
        end
    end
end)

-- ---------------------------------------------------------------------------
-- Kill / death detection
-- ---------------------------------------------------------------------------

local EVENT_DAMAGE = 'CEventNetworkEntityDamage'

local lastDeathReport = 0
-- Same dedupe window for kills: explosive/fire deaths can emit multiple fatal
-- CEventNetworkEntityDamage frames for one death, and a corpse taking further
-- damage can re-fire fatal. Without this guard a single kill could be credited
-- twice (once in its real bucket, once as misc_npc via the deferred path).
-- victimKey -> expiry. A single last-key slot only suppresses immediate
-- repeats, and an explosion killing a squad emits A,B,C,D and can re-fire the
-- set — interleaved, every repeat looks like a new victim, and lands in the
-- server's deferred path to be credited again as misc_npc.
local recentKills = {}
local KILL_DEDUPE_MS = 2000

local function dedupeKill(victimKey)
    local t = GetGameTimer()

    -- Bounded: everything added here expires, so it can't outgrow one window's
    -- worth of kills.
    for key, expiry in pairs(recentKills) do
        if t > expiry then
            recentKills[key] = nil
        end
    end

    if recentKills[victimKey] then
        return true
    end
    recentKills[victimKey] = t + KILL_DEDUPE_MS
    return false
end

-- Police-style peds (uniform, highway, sheriff, ranger, SWAT, FIB, security),
-- so kills of them can be broken out separately. Counted by model on the
-- killer's client; this covers cops spawned by vMenu or any other resource
-- too, not just ones we track by netId. A player wearing a cop model is still
-- counted as a player (the victim-is-player check happens first).
local POLICE_MODELS = {}
for _, model in ipairs({
    's_m_y_cop_01',
    's_m_y_hwaycop_01',
    's_m_y_sheriff_01',
    's_m_y_ranger_01',
    's_m_y_swat_01',
    's_m_m_fibsec_01',
    's_m_m_security_01',
}) do
    POLICE_MODELS[GetHashKey(model)] = true
end

local function isPolicePed(ped)
    return POLICE_MODELS[GetEntityModel(ped)] == true
end

AddEventHandler('gameEventTriggered', function(name, args)
    -- Defensive: this handler must NEVER abort the client script, or the
    -- report thread below dies with it (which would make the scoreboard show
    -- 0 players forever). Any error here is non-fatal.
    pcall(function()
        if name ~= EVENT_DAMAGE then
            return
        end

        local victim = args[1]
        local killer = args[2]
        -- The death flag is undocumented and sits at args[4] on current builds
        -- but args[6] on some older ones; accept either so we don't silently
        -- stop counting on a build that changed it.
        local fatal = args[4] == 1 or args[6] == 1

        if not fatal or not IsEntityAPed(victim) then
            return
        end

        -- Our own death: only the victim's client sees this reliably, so the
        -- death tally comes from here. The event can re-fire during the death
        -- cam; guard with a short window.
        if victim == PlayerPedId() then
            local t = GetGameTimer()
            if t - lastDeathReport > 2000 then
                lastDeathReport = t
                TriggerServerEvent('scoreboard:death')
            end
            return
        end

        -- A kill we made: report it with the victim's netId so the server can
        -- bucket it (player / squad / survival / bounty / misc / ambient).
        if killer == PlayerPedId() then
            local victimIsPlayer = NetworkGetPlayerIndexFromPed(victim) ~= -1
            -- Ambient peds (and animals) have no netId; NetworkGetNetworkIdFromEntity
            -- returns 0 for them (and for entities not owned by us). Send nil in
            -- that case so the server counts it as ambient rather than as an
            -- unknown networked NPC.
            local netId = 0
            if not victimIsPlayer then
                netId = NetworkGetNetworkIdFromEntity(victim)
            end

            -- Dedup identity: player index for players, netId for networked NPCs,
            -- ped handle for ambient NPCs (which have no stable netId).
            local victimKey
            if victimIsPlayer then
                victimKey = 'player:' .. NetworkGetPlayerIndexFromPed(victim)
            elseif netId ~= 0 then
                victimKey = 'npc:' .. tostring(netId)
            else
                victimKey = 'ped:' .. tostring(victim)
            end
            if dedupeKill(victimKey) then
                return
            end

            TriggerServerEvent('scoreboard:kill', {
                victimIsPlayer = victimIsPlayer,
                victimIsPolice = (not victimIsPlayer) and isPolicePed(victim) or false,
                victimNetId = netId ~= 0 and netId or nil,
            })
        end
    end)
end)

-- ---------------------------------------------------------------------------
-- Scoreboard display
-- ---------------------------------------------------------------------------

RegisterNetEvent('scoreboard:data', function(data)
    if not data or type(data) ~= 'table' then
        return
    end

    -- Self-highlight: rows whose id matches our own server id get the .me
    -- style. Server sends a shared payload to everyone, so this is client-side.
    local myId = GetPlayerServerId(PlayerId())
    local players = {}
    for _, p in ipairs(data.players or {}) do
        players[#players + 1] = p
        players[#players].me = (p.id == myId)
    end

    SendNUIMessage({
        type = 'update',
        data = {
            serverName = data.serverName or 'redline sandbox',
            players = players,
            hostiles = data.hostiles or 0,
            bounty = data.bounty or nil,
        },
    })
end)

-- Auto-hide when the game menu/pause comes up, so the overlay never lingers
-- over a frontend screen.
AddEventHandler('onClientPauseMenuChange', function(opened)
    if opened then
        setOverlay(false)
    end
end)

-- Auto-hide while dead (the death cam is fullscreen; nothing useful to show,
-- and it would block the respawn screen).
CreateThread(function()
    while true do
        Wait(500)
        if overlayVisible and IsPedDeadOrDying(PlayerPedId(), true) then
            setOverlay(false)
        end
    end
end)

-- ---------------------------------------------------------------------------
-- Command
-- ---------------------------------------------------------------------------

-- Toggle on the key-mapping command (F5 by default, rebindable).
local function toggleOverlay()
    setOverlay(not overlayVisible)
end

RegisterCommand('scoreboard', function()
    toggleOverlay()
end, false)

RegisterKeyMapping('scoreboard', 'Toggle scoreboard', 'keyboard', 'F5')

AddEventHandler('onClientResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then
        return
    end
    TriggerEvent('chat:addSuggestion', '/scoreboard', 'Toggle the player scoreboard overlay (F5 also does this).')
end)