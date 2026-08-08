-- Race client.
--
-- The invoker maps a waypoint and types /race; the server owns state. This
-- client: requests the race, spawns the car the server drew for this race
-- (the same one for the whole field), sets its map waypoint to the finish,
-- counts down, detects arrival, and reports live position for the leaderboard.

local spawnedVeh = 0
local raceFinish = nil
local raceRunning = false

-- GetGameTimer() when race:go landed. Finishes are reported as a duration
-- measured against it, so the values compare against other clients' durations
-- without ever comparing clocks.
local goAt = nil

-- Finish reports retry until the standings acknowledge them, since every
-- server-side rejection is silent. finishNotified is separate so the retries
-- don't re-notify the player.
local lastFinishReport = 0
local finishAcked = false
local finishNotified = false

local function notify(message)
    TriggerEvent('chat:addMessage', {
        color = { 90, 200, 255 },
        multiline = true,
        args = { 'race', message },
    })
end

-- The car is drawn server-side and arrives in race:begin — see CAR_POOL in
-- race/server.lua. Nothing to choose here.

local function loadModel(model)
    local hash = GetHashKey(model)
    if not IsModelInCdimage(hash) then
        return nil
    end
    RequestModel(hash)
    local deadline = GetGameTimer() + 10000
    while not HasModelLoaded(hash) and GetGameTimer() < deadline do
        Wait(0)
    end
    if not HasModelLoaded(hash) then
        return nil
    end
    return hash
end

local function deleteRaceCar()
    if spawnedVeh and DoesEntityExist(spawnedVeh) then
        SetEntityAsMissionEntity(spawnedVeh, true, true)
        DeleteVehicle(spawnedVeh)
    end
    spawnedVeh = 0
end

-- The invoker's /race: read our own waypoint and ask the server to start.
-- `/race cancel` is forwarded to the server (client command otherwise shadows
-- the server's own cancel handler).
RegisterCommand('race', function(_, args)
    if args[1] == 'cancel' then
        TriggerServerEvent('race:cancel')
        return
    end

    local wp = GetFirstBlipInfoId(8) -- 8 = waypoint blip
    if not DoesBlipExist(wp) then
        notify('^1set a waypoint on your map first, then /race')
        return
    end

    local coords = GetBlipInfoIdCoord(wp)
    TriggerServerEvent('race:request', {
        x = coords.x,
        y = coords.y,
        z = coords.z,
        name = 'your waypoint',
    })
end, false)

-- Server: the race is starting; set everyone's waypoint to the finish, spawn
-- the car, get in, and freeze until GO. Reset leaderboard state so a second
-- race re-activates the NUI.
RegisterNetEvent('race:begin', function(finish, finishName, countdownMs, car)
    deleteRaceCar()
    raceFinish = finish
    raceRunning = false
    goAt = nil
    lastFinishReport = 0
    finishAcked = false
    finishNotified = false
    SendNUIMessage({ type = 'standings', data = { status = 'countdown', list = {}, leader = nil } })

    -- Point everyone at the finish.
    SetNewWaypoint(finish.x, finish.y)

    local model = loadModel(car)
    if not model then
        -- Everyone races the same model, so this isn't a personal problem —
        -- tell the server to abort rather than leave a countdown nobody joins.
        notify(('^1could not load race car (%s)'):format(tostring(car)))
        TriggerServerEvent('race:loadfailed', car)
        return
    end

    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    local veh = CreateVehicle(model, coords.x, coords.y, coords.z, GetEntityHeading(ped), true, false)
    SetModelAsNoLongerNeeded(model)
    if not DoesEntityExist(veh) then
        notify('^1could not spawn race car')
        return
    end

    spawnedVeh = veh
    SetVehicleNumberPlateText(veh, 'RACE')
    SetPedIntoVehicle(ped, veh, -1)
    SetVehicleOnGroundProperly(veh)
    SetEntityAsNoLongerNeeded(veh)

    notify(('race to %s starts in %.1fs'):format(finishName, countdownMs / 1000))
    TriggerServerEvent('race:ready')

    -- Held until the server says GO, not for a local countdownMs: this point is
    -- only reached once loadModel returns, so a local countdown would release
    -- each client whenever its model happened to stream in.
    CreateThread(function()
        while raceFinish and not raceRunning do
            Wait(0)
            SetVehicleForwardSpeed(veh, 0.0)
            SetVehicleHandbrake(veh, true)
            SetPedIntoVehicle(ped, veh, -1) -- keep seat
        end
        if DoesEntityExist(veh) then
            SetVehicleHandbrake(veh, false)
        end
    end)
end)

-- One event to everyone, so the field starts together however long each client
-- took to get ready.
RegisterNetEvent('race:go', function()
    goAt = GetGameTimer()
    raceRunning = true
end)

-- Server: standings update (live leaderboard).
RegisterNetEvent('race:standings', function(data)
    if not data or type(data) ~= 'table' then
        return
    end
    -- Self-highlight: tag our own row.
    local myId = GetPlayerServerId(PlayerId())
    for _, p in ipairs(data.list or {}) do
        p.me = (p.id == myId)
        -- The only acknowledgement a finish report gets.
        if p.me and p.finished then
            finishAcked = true
            raceRunning = false
        end
    end
    SendNUIMessage({ type = 'standings', data = data })
end)

-- Server: race ended / cancelled.
RegisterNetEvent('race:ended', function()
    deleteRaceCar()
    raceRunning = false
    raceFinish = nil
    SendNUIMessage({ type = 'standings', data = { status = 'idle', list = {}, leader = nil } })
end)

-- 2D on purpose. Measuring to vector3(fx, fy, 0) folds the player's altitude
-- into the distance, which puts a finish on Mount Chiliad permanently ~800m
-- away however close you stand.
local function distanceToFinish(coords)
    local dx = coords.x - raceFinish.x
    local dy = coords.y - raceFinish.y
    return math.sqrt(dx * dx + dy * dy)
end

-- Position reporting for the leaderboard, during the countdown as well so the
-- board starts out ordered. Gated on the race, not on the car still existing:
-- a racer whose car exploded is still in the race.
CreateThread(function()
    while true do
        Wait(500)
        if raceFinish then
            local coords = GetEntityCoords(PlayerPedId())
            TriggerServerEvent('race:position', coords.x, coords.y)
        end
    end
end)

-- Arrival detection, separate from the reporting loop because it needs a much
-- finer clock: at 500ms a car at 200 km/h moves 28m per tick, most of the 40m
-- finish radius, so a close finish would be decided by tick phase.
CreateThread(function()
    while true do
        local interval = 500

        if raceFinish and raceRunning then
            local dist = distanceToFinish(GetEntityCoords(PlayerPedId()))
            if dist < 400.0 then
                interval = 50
            end

            -- Keeps reporting until race:standings acknowledges it. raceRunning
            -- must not be cleared here: a rejected report would then lock this
            -- player out of finishing, and a stuck racer blocks the whole race.
            if dist < 40.0 and GetGameTimer() - lastFinishReport > 2000 then
                lastFinishReport = GetGameTimer()
                if not finishNotified then
                    finishNotified = true
                    notify('^2finished!')
                end
                TriggerServerEvent('race:finish', goAt and (GetGameTimer() - goAt) or nil)
            end
        end

        Wait(interval)
    end
end)

-- Chat suggestion.
AddEventHandler('onClientResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then
        return
    end
    TriggerEvent('chat:addSuggestion', '/race', 'Race to your map waypoint. Everyone spawns the same randomly drawn vehicle and the server ranks finishers.')
end)