-- Shared bounty target: one NPC somewhere on the map, blipped for everyone,
-- first to kill it wins. The server only agrees on which target is live and
-- who killed it first; everything visible is client-side. Scores are
-- in-memory and reset with the server.

-- Rough coordinates of recognisable places. Z is approximate: the spawning
-- client ground-snaps before creating the ped, so these only need to be close
-- enough to find the right patch of map.
local LOCATIONS = {
    { name = 'Vinewood Sign', coords = vector3(711.0, 1198.0, 348.0) },
    { name = 'Mount Chiliad', coords = vector3(501.0, 5604.0, 797.0) },
    { name = 'LS International', coords = vector3(-1037.0, -2737.0, 20.0) },
    { name = 'Sandy Shores airfield', coords = vector3(1747.0, 3273.0, 41.0) },
    { name = 'Paleto Bay', coords = vector3(-275.0, 6635.0, 7.0) },
    { name = 'Del Perro Pier', coords = vector3(-1850.0, -1231.0, 13.0) },
    { name = 'Vespucci Beach', coords = vector3(-1223.0, -1493.0, 4.0) },
    { name = 'Grapeseed', coords = vector3(1698.0, 4924.0, 42.0) },
    { name = 'Chumash', coords = vector3(-3192.0, 1088.0, 20.0) },
    { name = 'Maze Bank roof', coords = vector3(-75.0, -818.0, 326.0) },
}

local TIMEOUT_MS = 10 * 60 * 1000

local active = nil
local nextId = 1
local scores = {}

local function broadcast(message)
    TriggerClientEvent('chat:addMessage', -1, {
        color = { 255, 200, 0 },
        multiline = true,
        args = { 'bounty', message },
    })
end

local function finish(message)
    if not active then
        return
    end

    active = nil
    TriggerClientEvent('npc:bounty:end', -1)
    broadcast(message)
end

RegisterNetEvent('npc:bounty:request', function()
    local source = source

    if active then
        broadcast(('a bounty is already up at %s'):format(active.name))
        return
    end

    local place = LOCATIONS[math.random(#LOCATIONS)]

    active = {
        id = nextId,
        name = place.name,
        coords = place.coords,
        -- The requesting client spawns the ped, because only a client can.
        -- If they disconnect mid-hunt the target goes with them; the timeout
        -- below is what stops that from wedging the next bounty forever.
        owner = source,
        netId = nil,
        startedAt = GetGameTimer(),
    }
    nextId = nextId + 1

    TriggerClientEvent('npc:bounty:begin', -1, active.id, active.coords, active.name)
    TriggerClientEvent('npc:bounty:spawn', source, active.id, active.coords)
    broadcast(('target sighted at %s'):format(place.name))
end)

-- The owner tells everyone else which entity to watch, once it exists.
RegisterNetEvent('npc:bounty:spawned', function(id, netId)
    if not active or active.id ~= id or active.owner ~= source then
        return
    end

    active.netId = netId
    TriggerClientEvent('npc:bounty:track', -1, id, netId)
end)

RegisterNetEvent('npc:bounty:failed', function(id)
    if not active or active.id ~= id or active.owner ~= source then
        return
    end

    finish('^1target could not be reached — try again')
end)

RegisterNetEvent('npc:bounty:claim', function(id)
    local source = source

    -- Every client watching the target reports the kill, so all but the first
    -- report lands here after `active` has already been cleared.
    if not active or active.id ~= id then
        return
    end

    local name = GetPlayerName(source)
    scores[name] = (scores[name] or 0) + 1

    finish(('%s claimed the bounty at %s (%d total)'):format(name, active.name, scores[name]))
end)

RegisterCommand('bounties', function(source)
    local lines = {}
    for name, count in pairs(scores) do
        lines[#lines + 1] = ('%s: %d'):format(name, count)
    end

    table.sort(lines)

    local body = #lines > 0 and table.concat(lines, ', ') or 'nobody yet'
    if source == 0 then
        print(body)
    else
        TriggerClientEvent('chat:addMessage', source, {
            color = { 255, 200, 0 },
            multiline = true,
            args = { 'bounty', body },
        })
    end
end, false)

CreateThread(function()
    while true do
        Wait(5000)
        if active and GetGameTimer() - active.startedAt > TIMEOUT_MS then
            finish('target got away')
        end
    end
end)
