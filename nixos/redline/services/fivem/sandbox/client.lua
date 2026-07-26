-- Muscle-memory chat commands for the sandbox. vMenu covers everything else
-- (and much more) through its F7 menu; these exist because typing /car adder
-- is faster than navigating a menu.

local spawnedVehicle = nil

local function notify(message)
    TriggerEvent('chat:addMessage', {
        color = { 255, 180, 0 },
        multiline = true,
        args = { 'sandbox', message },
    })
end

local function deleteVehicle(vehicle)
    if vehicle and vehicle ~= 0 and DoesEntityExist(vehicle) then
        SetEntityAsMissionEntity(vehicle, true, true)
        DeleteVehicle(vehicle)
    end
end

local function currentVehicle()
    local vehicle = GetVehiclePedIsIn(PlayerPedId(), false)
    if vehicle ~= 0 then
        return vehicle
    end
    return spawnedVehicle
end

RegisterCommand('car', function(_, args)
    local name = args[1] or 'adder'
    local model = GetHashKey(name)

    if not IsModelInCdimage(model) or not IsModelAVehicle(model) then
        notify('^1no such vehicle: ' .. name)
        return
    end

    RequestModel(model)
    local deadline = GetGameTimer() + 10000
    while not HasModelLoaded(model) and GetGameTimer() < deadline do
        Wait(0)
    end

    if not HasModelLoaded(model) then
        notify('^1timed out loading ' .. name)
        return
    end

    -- One spawned car at a time, otherwise the world fills up with abandoned
    -- Adders within about five minutes.
    deleteVehicle(spawnedVehicle)

    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    local vehicle = CreateVehicle(model, coords.x, coords.y, coords.z, GetEntityHeading(ped), true, false)

    SetPedIntoVehicle(ped, vehicle, -1)
    SetVehicleNumberPlateText(vehicle, 'SANDBOX')
    SetVehicleOnGroundProperly(vehicle)
    SetEntityAsNoLongerNeeded(vehicle)
    SetModelAsNoLongerNeeded(model)

    spawnedVehicle = vehicle
    notify('spawned ' .. name)
end, false)

RegisterCommand('dv', function()
    local vehicle = currentVehicle()
    if not vehicle or vehicle == 0 then
        notify('^1not in a vehicle')
        return
    end

    deleteVehicle(vehicle)
    if vehicle == spawnedVehicle then
        spawnedVehicle = nil
    end
    notify('deleted')
end, false)

RegisterCommand('fix', function()
    local vehicle = GetVehiclePedIsIn(PlayerPedId(), false)
    if vehicle == 0 then
        notify('^1not in a vehicle')
        return
    end

    SetVehicleFixed(vehicle)
    SetVehicleDeformationFixed(vehicle)
    SetVehicleUndriveable(vehicle, false)
    SetVehicleDirtLevel(vehicle, 0.0)
    SetVehicleEngineOn(vehicle, true, true, false)
    notify('fixed')
end, false)

RegisterCommand('tp', function(_, args)
    local x, y, z = tonumber(args[1]), tonumber(args[2]), tonumber(args[3])
    if not x or not y or not z then
        notify('^1usage: /tp <x> <y> <z>')
        return
    end

    SetEntityCoords(PlayerPedId(), x, y, z, false, false, false, false)
    notify(('teleported to %.1f %.1f %.1f'):format(x, y, z))
end, false)

RegisterCommand('wp', function()
    local waypoint = GetFirstBlipInfoId(8)
    if not DoesBlipExist(waypoint) then
        notify('^1no waypoint set')
        return
    end

    local coords = GetBlipInfoIdCoord(waypoint)
    local ped = PlayerPedId()

    -- The map blip carries no usable Z, so walk down from the sky until the
    -- collision for that cell has streamed in and reports ground.
    for height = 1000, 0, -25 do
        SetEntityCoords(ped, coords.x, coords.y, height + 0.0, false, false, false, false)
        Wait(50)

        local found, ground = GetGroundZFor_3dCoord(coords.x, coords.y, height + 0.0, false)
        if found then
            SetEntityCoords(ped, coords.x, coords.y, ground + 1.0, false, false, false, false)
            notify('teleported to waypoint')
            return
        end
    end

    notify('^1could not find ground under the waypoint')
end, false)

RegisterCommand('heal', function()
    local ped = PlayerPedId()
    SetEntityHealth(ped, GetEntityMaxHealth(ped))
    SetPedArmour(ped, 100)
    ClearPedBloodDamage(ped)
    notify('healed')
end, false)

AddEventHandler('onClientResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then
        return
    end

    TriggerEvent('chat:addSuggestion', '/car', 'Spawn a vehicle and get in it.', {
        { name = 'model', help = 'Spawn name, e.g. adder, t20, dominator. Defaults to adder.' },
    })
    TriggerEvent('chat:addSuggestion', '/dv', 'Delete the vehicle you are in.')
    TriggerEvent('chat:addSuggestion', '/fix', 'Repair and clean the vehicle you are in.')
    TriggerEvent('chat:addSuggestion', '/tp', 'Teleport to coordinates.', {
        { name = 'x', help = 'X' },
        { name = 'y', help = 'Y' },
        { name = 'z', help = 'Z' },
    })
    TriggerEvent('chat:addSuggestion', '/wp', 'Teleport to your map waypoint.')
    TriggerEvent('chat:addSuggestion', '/heal', 'Full health and armour.')
end)
