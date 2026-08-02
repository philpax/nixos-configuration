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
    if entry.ped and DoesEntityExist(entry.ped) then
        SetEntityAsMissionEntity(entry.ped, true, true)
        DeleteEntity(entry.ped)
    end
end

-- Also does the blip upkeep: a corpse keeps its entity around for a while,
-- and leaving a "Hostile" marker on the map for it makes the survival counter
-- look wrong.
local function livingCount()
    local alive = 0
    for i = #spawned, 1, -1 do
        local entry = spawned[i]
        if not DoesEntityExist(entry.ped) then
            dropBlip(entry)
            table.remove(spawned, i)
        elseif IsPedDeadOrDying(entry.ped, true) then
            dropBlip(entry)
        else
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

local function spawnHostile(point, tier)
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

    spawned[#spawned + 1] = { ped = ped, blip = addBlip(ped) }
    return ped
end

local function spawnGroup(count, tier, radius)
    local coords = GetEntityCoords(PlayerPedId())
    local made = 0

    for _ = 1, count do
        if #spawned >= MAX_ALIVE then
            break
        end
        if spawnHostile(spawnPointNear(coords, radius), tier) then
            made = made + 1
        end
    end

    return made
end

RegisterCommand('squad', function(_, args)
    if args[1] == 'clear' then
        clearAll()
        notify('cleared')
        return
    end

    local count = math.min(tonumber(args[1]) or 4, MAX_ALIVE)
    local tier = math.min(math.max(tonumber(args[2]) or 1, 1), #WEAPON_TIERS)

    local made = spawnGroup(count, tier, 30.0)
    if made == 0 then
        notify('^1could not spawn anyone here')
    else
        notify(('%d hostile(s), tier %d'):format(made, tier))
    end
end, false)

RegisterCommand('survival', function(_, args)
    if args[1] == 'stop' or survivalActive then
        survivalActive = false
        clearAll()
        notify('survival over')
        return
    end

    survivalActive = true
    notify('survival started — /survival again to stop')

    CreateThread(function()
        local wave = 0

        while survivalActive do
            wave = wave + 1

            local tier = math.min(math.ceil(wave / 2), #WEAPON_TIERS)
            local count = math.min(2 + wave, 10)
            local made = spawnGroup(count, tier, 45.0)

            if made == 0 then
                notify('^1nowhere to spawn — survival stopped')
                survivalActive = false
                break
            end

            notify(('wave %d — %d hostile(s), tier %d'):format(wave, made, tier))

            -- Wave ends when they're all down, or when you are.
            while survivalActive and livingCount() > 0 do
                Wait(500)
                if IsPedDeadOrDying(PlayerPedId(), true) then
                    notify(('^1you died on wave %d'):format(wave))
                    survivalActive = false
                end
            end

            if survivalActive then
                notify(('wave %d cleared'):format(wave))
                Wait(5000)
            end
        end

        clearAll()
    end)
end, false)

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
