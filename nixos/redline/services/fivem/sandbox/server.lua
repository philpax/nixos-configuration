-- /goto server half: resolves a player name to coords for the caller to
-- teleport to.
--
-- Teleporting itself is client-side; the server exists because name matching
-- over all connected players is far easier here than on the client, and
-- GetPlayerCoords gives us the target's (approximate) position even when they
-- are far out of the caller's scope.

local function notify(source, message)
    TriggerClientEvent('chat:addMessage', source, {
        color = { 255, 180, 0 },
        multiline = true,
        args = { 'sandbox', message },
    })
end

-- GetPlayers() yields server ids as strings, while `source` and anything a
-- client sends is a number. "3" ~= 3, silently.
local function playerIds()
    local ids = {}
    for _, id in ipairs(GetPlayers()) do
        ids[#ids + 1] = tonumber(id)
    end
    return ids
end

-- Exact match first, then a single unambiguous prefix match. Both sides
-- case-insensitive.
local function findPlayer(query)
    local lower = string.lower(query)
    local prefixes = {}

    for _, id in ipairs(playerIds()) do
        local name = GetPlayerName(id) or ''
        local lname = string.lower(name)

        if lname == lower then
            return id, name
        end

        if lname:sub(1, #lower) == lower then
            prefixes[#prefixes + 1] = { id = id, name = name }
        end
    end

    if #prefixes == 1 then
        return prefixes[1].id, prefixes[1].name
    end

    return nil, prefixes
end

RegisterNetEvent('sandbox:goto:request', function(query)
    local source = source
    if type(query) ~= 'string' or query == '' then
        notify(source, '^1usage: /goto <player>')
        return
    end

    local id, nameOrList = findPlayer(query)
    if id then
        if id == source then
            notify(source, "^1that's you")
            return
        end

        -- Via the ped: there is no server-side GetPlayerCoords. Approximate
        -- (positions sync a few times a second), but plenty to stand next to
        -- someone, and the client ground-snaps on arrival.
        local ped = GetPlayerPed(id)
        if not ped or ped == 0 then
            notify(source, ('^1%s has no ped right now — try again in a moment'):format(nameOrList))
            return
        end

        local coords = GetEntityCoords(ped)
        TriggerClientEvent('sandbox:goto:target', source, { x = coords.x, y = coords.y, z = coords.z }, nameOrList)
        return
    end

    if #nameOrList == 0 then
        notify(source, ('^1no player matching "%s"'):format(query))
        return
    end

    local names = {}
    for _, p in ipairs(nameOrList) do
        names[#names + 1] = p.name
    end
    notify(source, ('^1multiple players match: %s — be more specific'):format(table.concat(names, ', ')))
end)

-- ---------------------------------------------------------------------------
-- Live autocomplete for /goto
-- ---------------------------------------------------------------------------

-- Keep the chat suggestion list for /goto in sync with who's online. The chat
-- resource's `addSuggestion` accepts an array of { name, help } argument
-- hints; giving it each connected player's name makes the chat dropdown offer
-- them as you type `/goto <prefix>`. The static 'player' hint comes first so
-- it survives as the first dropdown entry, followed by live names.
local function refreshSuggestions()
    local suggestions = {
        { name = 'player', help = 'Name or unique prefix.' },
    }
    for _, id in ipairs(playerIds()) do
        local name = GetPlayerName(id)
        if name then
            suggestions[#suggestions + 1] = { name = name, help = 'Teleport to this player.' }
        end
    end
    TriggerClientEvent('chat:addSuggestion', -1, '/goto', 'Teleport to another player.', suggestions)
end

CreateThread(function()
    while true do
        refreshSuggestions()
        Wait(5000)
    end
end)