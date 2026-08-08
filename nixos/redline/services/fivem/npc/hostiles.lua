-- Hostile NPCs on demand: /squad spawns a one-off group, /survival runs
-- escalating waves until you die or call it off.
--
-- Everything here is client-side. Peds are created with isNetwork=true, so
-- they exist for everyone and your friends can join the fight — but the
-- spawning client owns them, and they go away when that client leaves.

local HOSTILE_GROUP = 'SANDBOX_HOSTILE'
local hostileGroupHash = GetHashKey(HOSTILE_GROUP)
local playerGroupHash = GetHashKey('PLAYER')

local PED_MODELS = {
    'g_m_y_ballaeast_01',
    'g_m_y_famca_01',
    'g_m_y_lost_01',
    'g_m_y_mexgoon_01',
    'g_m_m_chigoon_01',
    'g_m_y_salvaboss_01',
}

-- Indexed by difficulty tier: /squad always uses tier 1, /survival climbs.
local WEAPON_TIERS = {
    { 'WEAPON_PISTOL', 'WEAPON_SNSPISTOL' },
    { 'WEAPON_MICROSMG', 'WEAPON_SAWNOFFSHOTGUN' },
    { 'WEAPON_SMG', 'WEAPON_PUMPSHOTGUN' },
    { 'WEAPON_ASSAULTRIFLE', 'WEAPON_CARBINERIFLE' },
    { 'WEAPON_SPECIALCARBINE', 'WEAPON_COMBATMG' },
}

local MAX_ALIVE = 24

local spawned = {}
local survivalActive = false

local function notify(message)
    TriggerEvent('chat:addMessage', {
        color = { 255, 90, 90 },
        multiline = true,
        args = { 'npc', message },
    })
end

local function pick(list)
    return list[math.random(#list)]
end

-- Model loading is the one genuinely fallible step here: an unknown or
-- unstreamed model never loads and the caller must not block forever.
local function loadModel(model)
    if not IsModelInCdimage(model) then
        return false
    end

    RequestModel(model)
    local deadline = GetGameTimer() + 5000
    while not HasModelLoaded(model) and GetGameTimer() < deadline do
        Wait(0)
    end

    return HasModelLoaded(model)
end

-- Tell the scoreboard resource about a hostile ped we spawned, so its server
-- can classify kills against it (squad/survival) and show a live count.
local function announceSpawned(entry, kind)
    if not entry.netId or entry.netId == 0 then
        return
    end
    TriggerServerEvent('scoreboard:npc:spawned', entry.netId, kind)
    -- Cross-client hostility: everyone needs to apply the hostile relationship
    -- to this ped themselves (relationship groups don't replicate). The server
    -- relays this as `npc:hostile:apply` to all clients; each applies the group
    -- locally and tasks the ped to fight their ped too.
    TriggerServerEvent('npc:hostile:spawned', entry.netId)
end

-- And when one dies or disappears (without a kill event landing), tell the
-- scoreboard to drop it from the registry so the live-hostile count stays
-- honest. Guarded so a ped is only ever announced dead once.
local function announceDead(entry)
    if not entry.deadReported then
        entry.deadReported = true
        if entry.netId and entry.netId ~= 0 then
            TriggerServerEvent('scoreboard:npc:dead', entry.netId)
            TriggerServerEvent('npc:hostile:dead', entry.netId)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Cross-client hostility
--
-- Relationship groups / SetPedAsEnemy are per-client game state; they do NOT
-- replicate. So when ANY player spawns hostiles, we broadcast the netId and
-- every client applies the hostile relationship to that ped themselves. Shared
-- by squad/survival (hostiles.lua) and the bounty target (bounty_client.lua).
-- ---------------------------------------------------------------------------

-- netId -> true, for peds we've marked hostile on this client. Used to avoid
-- re-applying and to clean up when they die.
local markedHostile = {}

local function markHostileByNetId(netId)
    if not netId or netId == 0 or markedHostile[netId] then
        return
    end
    if not NetworkDoesNetworkIdExist(netId) then
        return
    end

    local ped = NetworkGetEntityFromNetworkId(netId)
    if not DoesEntityExist(ped) or not IsEntityAPed(ped) then
        return
    end

    markedHostile[netId] = true
    SetPedRelationshipGroupHash(ped, hostileGroupHash)
    SetPedAsEnemy(ped, true)
    SetPedCombatAttributes(ped, 46, true)
    -- No TaskCombatPed here: the SANDBOX_HOSTILE <-> PLAYER relationship (set
    -- on every client in onClientResourceStart) makes the ped aggro the nearest
    -- player automatically. Per-client TaskCombatPed would fight over the same
    -- ped's task and just thrash between targets.
end

-- Server relay: apply hostility to a spawned ped (from hostiles or bounty).
RegisterNetEvent('npc:hostile:apply', function(netId)
    markHostileByNetId(netId)
end)

-- Server relay: a hostile ped is gone; clean up our local marker.
RegisterNetEvent('npc:hostile:clear', function(netId)
    markedHostile[netId] = nil
end)

local function addBlip(ped)
    local blip = AddBlipForEntity(ped)
    SetBlipSprite(blip, 1)
    SetBlipColour(blip, 1)
    SetBlipScale(blip, 0.7)
    SetBlipAsShortRange(blip, false)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName('Hostile')
    EndTextCommandSetBlipName(blip)
    return blip
end

local function dropBlip(entry)
    if entry.blip and DoesBlipExist(entry.blip) then
        RemoveBlip(entry.blip)
    end
    entry.blip = nil
end

local function forget(entry)
    dropBlip(entry)
    announceDead(entry)
    if entry.ped and DoesEntityExist(entry.ped) then
        SetEntityAsMissionEntity(entry.ped, true, true)
        DeleteEntity(entry.ped)
    end
end

-- Also does the blip upkeep: a corpse keeps its entity around for a while,
-- and leaving a "Hostile" marker on the map for it makes the survival counter
-- look wrong.
-- Optional `kind` filter: count only entries of that kind (used by the co-op
-- survival alive-report so /squad spawns don't pollute the wave counter).
local function livingCount(kind)
    local alive = 0
    for i = #spawned, 1, -1 do
        local entry = spawned[i]
        if not DoesEntityExist(entry.ped) then
            dropBlip(entry)
            announceDead(entry)
            table.remove(spawned, i)
        elseif IsPedDeadOrDying(entry.ped, true) then
            dropBlip(entry)
            announceDead(entry)
            -- The corpse leaves the list too, not just its blip: `spawned` is
            -- what spawnGroup checks against MAX_ALIVE, and bodies linger.
            table.remove(spawned, i)
        elseif not kind or entry.kind == kind then
            alive = alive + 1
        end
    end
    return alive
end

local function clearAll()
    for _, entry in ipairs(spawned) do
        forget(entry)
    end
    spawned = {}
end

-- Somewhere on the ground, roughly `radius` away, not on top of the player.
local function spawnPointNear(coords, radius)
    local angle = math.random() * 2.0 * math.pi
    local distance = radius * (0.6 + math.random() * 0.4)
    local x = coords.x + math.cos(angle) * distance
    local y = coords.y + math.sin(angle) * distance

    local found, safe = GetSafeCoordForPed(x, y, coords.z, true, 16)
    if found then
        return safe
    end

    local hasGround, groundZ = GetGroundZFor_3dCoord(x, y, coords.z + 50.0, false)
    return vector3(x, y, hasGround and groundZ or coords.z)
end

local function spawnHostile(point, tier, kind)
    local model = GetHashKey(pick(PED_MODELS))
    if not loadModel(model) then
        return nil
    end

    local ped = CreatePed(4, model, point.x, point.y, point.z, math.random(360) + 0.0, true, false)
    SetModelAsNoLongerNeeded(model)

    if not DoesEntityExist(ped) then
        return nil
    end

    SetPedRelationshipGroupHash(ped, hostileGroupHash)
    SetPedAsEnemy(ped, true)

    GiveWeaponToPed(ped, GetHashKey(pick(WEAPON_TIERS[tier])), 250, false, true)
    SetPedDropsWeaponsWhenDead(ped, true)

    -- 46 = always fight, 5 = can use cover, 2 = can do drivebys.
    -- Without "always fight" they break off and wander after a few seconds.
    SetPedCombatAttributes(ped, 46, true)
    SetPedCombatAttributes(ped, 5, true)
    SetPedCombatAttributes(ped, 2, true)
    SetPedCombatAbility(ped, 2)
    SetPedCombatRange(ped, 2)
    SetPedAccuracy(ped, 20 + tier * 10)
    SetPedArmour(ped, (tier - 1) * 25)
    SetPedFleeAttributes(ped, 0, false)
    SetPedSeeingRange(ped, 120.0)
    SetPedHearingRange(ped, 120.0)

    TaskCombatPed(ped, PlayerPedId(), 0, 16)

    local entry = { ped = ped, blip = addBlip(ped), netId = NetworkGetNetworkIdFromEntity(ped), kind = kind or 'squad' }
    spawned[#spawned + 1] = entry
    announceSpawned(entry, kind or 'squad')
    return ped
end

local function spawnGroup(count, tier, radius, kind)
    local coords = GetEntityCoords(PlayerPedId())
    local made = 0

    for _ = 1, count do
        if #spawned >= MAX_ALIVE then
            break
        end
        if spawnHostile(spawnPointNear(coords, radius), tier, kind or 'squad') then
            made = made + 1
        end
    end

    return made
end

-- Co-op survival: the server drives waves and asks each participant to spawn
-- hostiles around THEMSELVES, so hostiles appear around every player. This
-- spawns `count` hostiles around the caller's own position.
local function spawnSurvivalAroundSelf(count, tier)
    return spawnGroup(count, tier, 45.0, 'survival')
end

-- Server relays for co-op survival. The server owns wave state; each client
-- just spawns/clears and reports how many hostiles it still has alive.
RegisterNetEvent('npc:survival:wave', function(wave, count, tier)
    notify(('wave %d — %d hostile(s), tier %d'):format(wave, count, tier))
    spawnSurvivalAroundSelf(count, tier)
end)

RegisterNetEvent('npc:survival:stop', function()
    survivalActive = false
    clearAll()
end)

-- The server asks us how many of OUR spawned hostiles are still alive, so it
-- can tell when a wave is cleared across all participants. Counts only
-- survival-kind peds so /squad spawns during a run don't hold waves open.
RegisterNetEvent('npc:survival:reportalive', function()
    TriggerServerEvent('npc:survival:alive', livingCount('survival'))
end)

RegisterCommand('squad', function(_, args)
    if args[1] == 'clear' then
        clearAll()
        notify('cleared')
        return
    end

    -- Floored: tonumber keeps fractions, and a fractional tier indexes
    -- WEAPON_TIERS to nil and then throws in the "%d" format below.
    local count = math.min(math.floor(tonumber(args[1]) or 4), MAX_ALIVE)
    local tier = math.min(math.max(math.floor(tonumber(args[2]) or 1), 1), #WEAPON_TIERS)

    local made = spawnGroup(count, tier, 30.0)
    if made == 0 then
        notify('^1could not spawn anyone here')
    else
        notify(('%d hostile(s), tier %d'):format(made, tier))
    end
end, false)

-- /survival is now TRUE cooperative: the server owns waves and spawns hostiles
-- around every alive participant. The server's RegisterCommand('survival')
-- handles start/stop; this client only reacts to the npc:survival:* events
-- (wave/stop/reportalive) defined above, plus it tells the server when this
-- player dies so the event can end when everyone is down.
RegisterNetEvent('npc:survival:started', function()
    survivalActive = true
    clearAll()
end)

-- Report our own death to the server once per death while a co-op run is
-- active (the server ends the event when all participants are down). Clearing
-- our own spawns on death stops them leaking into the next wave (and avoids
-- spamming npc:survival:dead twice a second). We re-arm when we're alive
-- again so a death in a later wave is reported too.
local reportedThisDeath = false

CreateThread(function()
    while true do
        Wait(500)
        local dead = IsPedDeadOrDying(PlayerPedId(), true)
        if dead then
            if survivalActive and not reportedThisDeath then
                reportedThisDeath = true
                TriggerServerEvent('npc:survival:dead')
                -- Don't clear spawns here: the scoreboard's kill attribution
                -- still needs the netIds. The server's wave poll stops counting
                -- dead participants anyway; their peds get cleared on respawn.
            end
        else
            reportedThisDeath = false
        end
    end
end)

-- /survival drives livingCount itself between waves, but /squad has no loop,
-- so blips for its casualties would sit on the map forever. Idles at nothing
-- while there are no hostiles.
CreateThread(function()
    while true do
        Wait(1000)
        if #spawned > 0 then
            livingCount()
        end
    end
end)

AddEventHandler('onClientResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then
        return
    end

    AddRelationshipGroup(HOSTILE_GROUP)
    -- 5 = hate. Both directions, or they'll shoot at you without you being
    -- able to freely retaliate.
    SetRelationshipBetweenGroups(5, hostileGroupHash, playerGroupHash)
    SetRelationshipBetweenGroups(5, playerGroupHash, hostileGroupHash)

    TriggerEvent('chat:addSuggestion', '/squad', 'Spawn hostile NPCs around you.', {
        { name = 'count', help = 'How many. Defaults to 4.' },
        { name = 'tier', help = '1-5, weapons and armour. Defaults to 1. Or "clear" as the first argument.' },
    })
    TriggerEvent('chat:addSuggestion', '/survival', 'Escalating waves of hostiles until you die. Run again to stop.')
end)

AddEventHandler('onClientResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        survivalActive = false
        clearAll()
    end
end)
