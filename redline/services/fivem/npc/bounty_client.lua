-- Client half of the bounty. Three jobs: draw the blip, spawn the target if
-- the server picked us to, and report the kill when we see it.

local BOUNTY_MODEL = 'g_m_m_armboss_01'

local current = nil

local function notify(message)
    TriggerEvent('chat:addMessage', {
        color = { 255, 200, 0 },
        multiline = true,
        args = { 'bounty', message },
    })
end

local function clearBlip()
    if current and current.blip and DoesBlipExist(current.blip) then
        RemoveBlip(current.blip)
    end
end

RegisterNetEvent('npc:bounty:begin', function(id, coords, name)
    clearBlip()

    local blip = AddBlipForCoord(coords.x, coords.y, coords.z)
    SetBlipSprite(blip, 303)
    SetBlipColour(blip, 1)
    SetBlipScale(blip, 1.1)
    SetBlipAsShortRange(blip, false)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName('Bounty: ' .. name)
    EndTextCommandSetBlipName(blip)

    current = { id = id, blip = blip, ped = nil }
end)

RegisterNetEvent('npc:bounty:end', function()
    clearBlip()
    current = nil
end)

-- We were picked to host the target. Ground-snap first: the server's
-- coordinates are only approximate, and a ped created below the map falls
-- forever while everyone drives to an empty field.
RegisterNetEvent('npc:bounty:spawn', function(id, coords)
    CreateThread(function()
        local model = GetHashKey(BOUNTY_MODEL)

        if not IsModelInCdimage(model) then
            TriggerServerEvent('npc:bounty:failed', id)
            return
        end

        RequestModel(model)
        local deadline = GetGameTimer() + 10000
        while not HasModelLoaded(model) and GetGameTimer() < deadline do
            Wait(0)
        end

        if not HasModelLoaded(model) then
            TriggerServerEvent('npc:bounty:failed', id)
            return
        end

        -- Collision for a far-away cell isn't loaded, so ask the engine to
        -- stream it in around the target before trusting the ground query.
        RequestCollisionAtCoord(coords.x, coords.y, coords.z)
        local collisionDeadline = GetGameTimer() + 5000
        while not HasCollisionLoadedAroundEntity(PlayerPedId()) and GetGameTimer() < collisionDeadline do
            RequestCollisionAtCoord(coords.x, coords.y, coords.z)
            Wait(100)
        end

        local z = coords.z
        local hasGround, groundZ = GetGroundZFor_3dCoord(coords.x, coords.y, coords.z + 25.0, false)
        if hasGround then
            z = groundZ
        end

        local ped = CreatePed(4, model, coords.x, coords.y, z + 1.0, 0.0, true, false)
        SetModelAsNoLongerNeeded(model)

        if not DoesEntityExist(ped) then
            TriggerServerEvent('npc:bounty:failed', id)
            return
        end

        SetEntityAsMissionEntity(ped, true, true)
        SetPedArmour(ped, 100)
        GiveWeaponToPed(ped, GetHashKey('WEAPON_CARBINERIFLE'), 250, false, true)
        SetPedAccuracy(ped, 45)
        SetPedCombatAttributes(ped, 46, true)
        SetPedCombatAbility(ped, 2)
        SetPedFleeAttributes(ped, 0, false)
        SetPedDropsWeaponsWhenDead(ped, true)

        -- Keep it alive and in place until someone arrives: without this the
        -- engine culls a ped nobody is near, and the bounty quietly evaporates.
        SetEntityInvincible(ped, false)
        SetPedCanRagdollFromPlayerImpact(ped, true)

        TriggerServerEvent('npc:bounty:spawned', id, NetworkGetNetworkIdFromEntity(ped))
    end)
end)

-- Everyone watches the same entity, so whoever's client notices the death
-- first reports it. The server keeps the first report and drops the rest.
RegisterNetEvent('npc:bounty:track', function(id, netId)
    CreateThread(function()
        while current and current.id == id do
            Wait(500)

            if NetworkDoesNetworkIdExist(netId) then
                local ped = NetworkGetEntityFromNetworkId(netId)
                if DoesEntityExist(ped) then
                    current.ped = ped

                    -- Follow the target with the blip once it's real, so it
                    -- stays honest if the ped wanders.
                    --
                    -- Components, never table.unpack(coords): in CfxLua
                    -- `#vector3` is the magnitude (that's what makes the
                    -- `#(a - b) < 2.0` idiom work), so unpack sees a
                    -- fractional length and throws.
                    if current.blip and DoesBlipExist(current.blip) then
                        local at = GetEntityCoords(ped)
                        SetBlipCoords(current.blip, at.x, at.y, at.z)
                    end

                    if IsPedDeadOrDying(ped, true) then
                        TriggerServerEvent('npc:bounty:claim', id)
                        return
                    end
                end
            end
        end
    end)
end)

RegisterCommand('bounty', function()
    if current then
        notify('a bounty is already up')
        return
    end
    TriggerServerEvent('npc:bounty:request')
end, false)

-- ---------------------------------------------------------------------------
-- Player bounties (/mark): client half.
--
-- The server tells everyone who's marked (server id). We draw a red blip on
-- that player's CURRENT ped (players change peds on respawn, so we re-attach
-- each tick), and when we witness the marked player die AND we dealt the kill,
-- claim it. The kill detection reuses the scoreboard's CEventNetworkEntityDamage
-- pattern but only for the marked target.
-- ---------------------------------------------------------------------------

local pbTarget = nil -- server id of the marked player
local pbBlip = nil
local pbLastClaim = 0

local function clearPBBlip()
    if pbBlip and DoesBlipExist(pbBlip) then
        RemoveBlip(pbBlip)
    end
    pbBlip = nil
end

RegisterNetEvent('npc:pbounty:set', function(targetId)
    clearPBBlip()
    pbTarget = targetId
end)

RegisterNetEvent('npc:pbounty:clear', function()
    clearPBBlip()
    pbTarget = nil
end)

-- Track: find the marked player's current ped, keep the blip attached. Runs
-- while a target is set.
CreateThread(function()
    while true do
        Wait(250)
        if not pbTarget then
            Wait(1000)
        end

        -- Find the player by server id.
        local targetPed = nil
        for _, pid in ipairs(GetActivePlayers()) do
            local serverId = GetPlayerServerId(pid)
            if serverId == pbTarget then
                targetPed = GetPlayerPed(pid)
                break
            end
        end

        if targetPed and DoesEntityExist(targetPed) then
            -- Create only: AddBlipForEntity attaches to the ped and follows it,
            -- so there is nothing to update per tick.
            if not pbBlip then
                pbBlip = AddBlipForEntity(targetPed)
                SetBlipSprite(pbBlip, 1)
                SetBlipColour(pbBlip, 1) -- red
                SetBlipScale(pbBlip, 1.0)
                BeginTextCommandSetBlipName('STRING')
                AddTextComponentSubstringPlayerName('BOUNTY: ' .. (GetPlayerName(GetPlayerFromServerId(pbTarget)) or ''))
                EndTextCommandSetBlipName(pbBlip)
            end
        else
            -- Target not in scope right now; keep a stale blip from the last
            -- known position is pointless, so drop it until we see them again.
            clearPBBlip()
        end
    end
end)

-- Claim when we deal the killing blow to the marked player. Uses the same
-- gameEventTriggered detection as the scoreboard.
AddEventHandler('gameEventTriggered', function(name, args)
    if name ~= 'CEventNetworkEntityDamage' or not pbTarget then
        return
    end
    local victim = args[1]
    local killer = args[2]
    local fatal = args[4] == 1 or args[6] == 1
    if not fatal or not IsEntityAPed(victim) then
        return
    end

    -- Victim must be the marked player; killer must be us.
    local victimPlayer = NetworkGetPlayerIndexFromPed(victim)
    if victimPlayer == -1 then
        return
    end
    local victimServerId = GetPlayerServerId(victimPlayer)
    if victimServerId ~= pbTarget then
        return
    end

    -- Corroboration for the server's claim check, and only worth anything if it
    -- comes from the victim — a claimant vouching for its own kill is not
    -- evidence.
    if victimPlayer == PlayerId() then
        TriggerServerEvent('npc:pbounty:deathnotify', pbTarget)
    end

    if killer ~= PlayerPedId() then
        return
    end

    -- Claim it. The server sorts out first-wins / placer-no-reward.
    local t = GetGameTimer()
    if t - pbLastClaim > 2000 then
        pbLastClaim = t
        TriggerServerEvent('npc:pbounty:claim', pbTarget)
    end
end)

AddEventHandler('onClientResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then
        return
    end

    TriggerEvent('chat:addSuggestion', '/bounty', 'Put a bounty target somewhere on the map. First to kill it wins.')
    TriggerEvent('chat:addSuggestion', '/bounties', 'Show the bounty scoreboard.')
    TriggerEvent('chat:addSuggestion', '/mark', 'Place a bounty on a player. First to kill them claims it.', {
        { name = 'player', help = 'Name or unique prefix.' },
    })
end)

AddEventHandler('onClientResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        clearBlip()
        clearPBBlip()
        pbTarget = nil
    end
end)
