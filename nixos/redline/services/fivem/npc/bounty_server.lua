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

-- ---------------------------------------------------------------------------
-- Cross-client hostility relay
--
-- A client that spawns hostile peds reports their netId (npc:hostile:spawned).
-- We relay it to everyone so each client applies the hostile relationship
-- locally (it doesn't replicate). Also relays clears when peds go away.
-- ---------------------------------------------------------------------------

RegisterNetEvent('npc:hostile:spawned', function(netId)
    if type(netId) ~= 'number' or netId == 0 then
        return
    end
    TriggerClientEvent('npc:hostile:apply', -1, netId)
end)

RegisterNetEvent('npc:hostile:dead', function(netId)
    if type(netId) ~= 'number' then
        return
    end
    TriggerClientEvent('npc:hostile:clear', -1, netId)
end)

local function broadcast(message)
    TriggerClientEvent('chat:addMessage', -1, {
        color = { 255, 200, 0 },
        multiline = true,
        args = { 'bounty', message },
    })
end

-- GetPlayers() yields server ids as strings, while `source` and anything a
-- client sends is a number. "3" ~= 3 and t["3"] is a different slot from t[3],
-- both silently, so normalise here and deal in numbers everywhere else.
local function playerIds()
    local ids = {}
    for _, id in ipairs(GetPlayers()) do
        ids[#ids + 1] = tonumber(id)
    end
    return ids
end

-- Score name resolution for /mark (player bounties). Exact first, then a
-- single unambiguous prefix, case-insensitive.
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

-- ---------------------------------------------------------------------------
-- Player bounties (/mark): place a bounty on a *player*. Everyone gets a blip
-- on them; the first kill by another player claims it and credits the winner's
-- bounty counter on the scoreboard. Parallel to, but separate from, the shared
-- NPC bounty above — only one of each can be live at a time.
-- ---------------------------------------------------------------------------

local playerBounty = nil

local function pbNotify(message)
    TriggerClientEvent('chat:addMessage', -1, {
        color = { 255, 120, 120 },
        multiline = true,
        args = { 'bounty', message },
    })
end

local function clearPlayerBounty(message)
    if not playerBounty then
        return
    end
    playerBounty = nil
    TriggerClientEvent('npc:pbounty:clear', -1)
    if message then
        pbNotify(message)
    end
end

RegisterCommand('mark', function(source, args)
    local query = table.concat(args, ' ')
    if query == '' then
        TriggerClientEvent('chat:addMessage', source, {
            color = { 255, 200, 0 },
            multiline = true,
            args = { 'bounty', '^1usage: /mark <player>' },
        })
        return
    end

    if playerBounty then
        TriggerClientEvent('chat:addMessage', source, {
            color = { 255, 200, 0 },
            multiline = true,
            args = { 'bounty', '^1a player bounty is already up' },
        })
        return
    end

    local id, nameOrList = findPlayer(query)
    if not id then
        local msg = #nameOrList == 0
            and ('^1no player matching "%s"'):format(query)
            or ('^1multiple players match: %s'):format(
                table.concat((function()
                    local n = {}
                    for _, p in ipairs(nameOrList) do n[#n + 1] = p.name end
                    return n
                end)(), ', '))
        TriggerClientEvent('chat:addMessage', source, {
            color = { 255, 200, 0 },
            multiline = true,
            args = { 'bounty', msg },
        })
        return
    end

    if id == source then
        TriggerClientEvent('chat:addMessage', source, {
            color = { 255, 200, 0 },
            multiline = true,
            args = { 'bounty', "^1you can't mark yourself" },
        })
        return
    end

    playerBounty = {
        target = id,
        targetName = nameOrList,
        placedBy = source,
        placedByName = GetPlayerName(source) or 'console',
        startedAt = GetGameTimer(),
    }

    pbNotify(('%s placed a bounty on %s — first to kill them claims it!'):format(
        playerBounty.placedByName, nameOrList))
    TriggerClientEvent('npc:pbounty:set', -1, id)
end, false)

-- Corroboration set for player-bounty claims: source -> expiry time of a
-- death the victim's client reported. A claim is only honoured if the target
-- actually died recently (see below), so a client can't forge a kill they
-- didn't deal.
local recentPlayerDeaths = {}

RegisterNetEvent('npc:pbounty:deathnotify', function(target)
    if type(target) ~= 'number' then
        return
    end
    recentPlayerDeaths[target] = GetGameTimer() + 15000
end)

-- Prune expired death notifications.
CreateThread(function()
    while true do
        Wait(60000)
        local t = GetGameTimer()
        for id, expiry in pairs(recentPlayerDeaths) do
            if t > expiry then
                recentPlayerDeaths[id] = nil
            end
        end
    end
end)

-- A client reports that the marked player died and THIS client delivered the
-- killing blow (or was the first to claim). Only the first claim wins.
-- The claim is corroborated server-side: the target's OWN client reported the
-- death (npc:pbounty:deathnotify) within the last 15s, so the marked player
-- genuinely died.
RegisterNetEvent('npc:pbounty:claim', function(target)
    local source = source
    if not playerBounty or playerBounty.target ~= target or source == target then
        return
    end
    if source == playerBounty.placedBy then
        -- The placer killing their own mark: no reward (or allow? keep simple:
        -- no reward, but it still clears the bounty).
        clearPlayerBounty(('%s took down their own mark'):format(GetPlayerName(source) or 'console'))
        return
    end

    -- Corroborate: the victim must have died recently (via the victim's own
    -- death report). Without this, any client could claim a bounty on a target
    -- who never died.
    if not recentPlayerDeaths[target] then
        return
    end
    -- Spent, or it lingers for its full 15s and a second /mark on the same
    -- player inside that window is claimable off the previous death.
    recentPlayerDeaths[target] = nil

    local winner = GetPlayerName(source) or 'console'
    -- No live/name fields: those describe the separate NPC bounty (`active`),
    -- which this payout must not clear.
    TriggerEvent('scoreboard:bounty', { winner = source })
    clearPlayerBounty(('%s claimed the bounty on %s!'):format(winner, playerBounty.targetName))
end)

-- /mark timeout: 10 minutes, same as the NPC bounty.
CreateThread(function()
    while true do
        Wait(5000)
        if playerBounty and GetGameTimer() - playerBounty.startedAt > TIMEOUT_MS then
            clearPlayerBounty(('the bounty on %s expired'):format(playerBounty.targetName))
        end
    end
end)

-- If the marked target leaves, drop the bounty.
AddEventHandler('playerDropped', function()
    if playerBounty and (source == playerBounty.target or source == playerBounty.placedBy) then
        clearPlayerBounty(('the player bounty was removed (%s left)'):format(
            source == playerBounty.target and playerBounty.targetName or (playerBounty.placedByName or 'console')))
    end
end)

-- ---------------------------------------------------------------------------
-- Co-op survival (/survival): server-owned wave driver.
--
-- Previously /survival was client-local (each player ran their own wave
-- against their own spawns, ending when THEY died). Now the server owns the
-- event: every alive connected player is a participant, hostiles spawn around
-- each of them (via npc:survival:wave), and the event only ends when ALL
-- participants are dead or someone stops it.
-- ---------------------------------------------------------------------------

-- State: nil when idle. While active, every connected player is a participant
-- and hostiles spawn around each of them every wave.
local coOpSurvival = nil

-- Death marks: source -> true while that player is down in the current run.
-- Hoisted next to coOpSurvival so the /survival command's reset, the
-- npc:survival:dead handler, and the wave thread all share the SAME table
-- (a late `local` here would shadow the command's reset into a global).
local deadParticipants = {}

-- Wave-clear aggregation: source -> last reported alive-hostile count.
local pendingAlive = {}

local function survivalBroadcast(message)
    TriggerClientEvent('chat:addMessage', -1, {
        color = { 255, 90, 90 },
        multiline = true,
        args = { 'npc', message },
    })
end

local function stopCoOpSurvival(message)
    if not coOpSurvival then
        return
    end
    coOpSurvival = nil
    TriggerClientEvent('npc:survival:stop', -1)
    if message then
        survivalBroadcast(message)
    end
end

-- Server-owned /survival command. Any player can start/stop; the event is
-- shared by everyone connected.
RegisterCommand('survival', function(source, args)
    if args[1] == 'stop' or coOpSurvival then
        stopCoOpSurvival('survival stopped')
        return
    end

    coOpSurvival = { wave = 0 }
    deadParticipants = {}
    TriggerClientEvent('npc:survival:started', -1)
    survivalBroadcast(('co-op survival started by %s — all connected players fight together; /survival stops it'):format(GetPlayerName(source) or 'console'))
end, false)

-- Track which players are currently dead so the server can end the event when
-- everyone is down. Clients report their own death via npc:survival:dead.
RegisterNetEvent('npc:survival:dead', function()
    if coOpSurvival then
        deadParticipants[source] = true
    end
end)

-- Wave driver: while survival is active, run waves. Each wave tells every
-- client to spawn `count` hostiles of `tier` around itself, then polls until
-- all hostiles are down (across all clients) before the next wave. Ends when
-- all participants are dead or stopped.
CreateThread(function()
    while true do
        Wait(4000)
        -- Idle short-circuits: when no run is active, skip the whole wave body
        -- and loop. WITHOUT this guard, the code below would deref the nil
        -- coOpSurvival and kill the thread on boot / after every stop.
        if not coOpSurvival then
            goto continue
        end

        coOpSurvival.wave = coOpSurvival.wave + 1
        local wave = coOpSurvival.wave
        local tier = math.min(math.ceil(wave / 2), 5)
        local count = math.min(2 + wave, 10)

        survivalBroadcast(('wave %d — %d hostiles each, tier %d'):format(wave, count, tier))
        TriggerClientEvent('npc:survival:wave', -1, wave, count, tier)
        pendingAlive = {}

        -- Poll every 3s: ask each alive participant for its alive count; when
        -- everyone alive reports 0 (or everyone is dead), the wave is done.
        -- A per-wave hard timeout (and a missed-poll grace) prevents a hung
        -- client from wedging the run forever.
        local waveClear = false
        local waveStart = GetGameTimer()
        local missedPolls = {}
        while coOpSurvival and not waveClear do
            Wait(3000)

            local anyAlivePlayer = false
            local everyoneReportedZero = true
            for _, id in ipairs(playerIds()) do
                if not deadParticipants[id] then
                    anyAlivePlayer = true
                    TriggerClientEvent('npc:survival:reportalive', id)
                    if pendingAlive[id] == nil then
                        -- Silence. After 3 consecutive misses treat the client
                        -- as unresponsive and count it clear, so one bad client
                        -- can't wedge the wave. Only silence counts as a miss —
                        -- "I still have N alive" is a working client, and
                        -- treating it as a miss cleared every wave on schedule
                        -- regardless of what was happening.
                        missedPolls[id] = (missedPolls[id] or 0) + 1
                        if missedPolls[id] <= 3 then
                            everyoneReportedZero = false
                        end
                    elseif pendingAlive[id] > 0 then
                        missedPolls[id] = nil
                        everyoneReportedZero = false
                    else
                        missedPolls[id] = nil
                    end
                end
            end

            -- Hard backstop: a wave that runs over 120s force-clears.
            if GetGameTimer() - waveStart > 120000 then
                survivalBroadcast('^1wave timed out — forcing next wave')
                waveClear = true
            elseif not anyAlivePlayer then
                -- `break`, never `return`: a return exits the enclosing
                -- CreateThread and kills the wave driver for the rest of the
                -- server's life, so the next /survival would drive nothing.
                stopCoOpSurvival('^1everyone is down — survival over')
                break
            elseif everyoneReportedZero then
                waveClear = true
                -- Players who died this wave respawn between waves; let them
                -- back into the fight so the run continues until a wave
                -- genuinely wipes everyone at once.
                deadParticipants = {}
                survivalBroadcast(('wave %d cleared'):format(wave))
                Wait(5000)
            end
        end
        ::continue::
    end
end)

-- Aggregate per-client alive-hostile reports from the wave driver.
RegisterNetEvent('npc:survival:alive', function(count)
    if not coOpSurvival then
        return
    end
    pendingAlive[source] = count or 0
end)

-- Keep the scoreboard resource's "bounty live" footer and bounty counts in
-- sync. Server-internal event (the scoreboard handles it via AddEventHandler).
local function announceBounty(live, name, winner)
    TriggerEvent('scoreboard:bounty', {
        live = live,
        name = name,
        winner = winner,
    })
end

local function finish(message)
    if not active then
        return
    end

    -- Drop the target from the scoreboard's hostile registry on ANY end of the
    -- bounty (timeout, owner drop, target unreachable), not just a claim —
    -- otherwise the "N hostile NPCs alive" chip shows a ghost for up to the
    -- scoreboard's 15-minute prune. Also stops a later-reused netId from being
    -- misclassified against this stale entry.
    if active.netId then
        TriggerEvent('scoreboard:npc:dead', active.netId)
        TriggerClientEvent('npc:hostile:clear', -1, active.netId)
    end

    active = nil
    announceBounty(false)
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

    announceBounty(true, place.name)
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
    -- Register the target in the scoreboard's hostile registry so a kill on
    -- it classifies as "bounty", and (once the target dies) so the registry
    -- entry is dropped.
    TriggerEvent('scoreboard:npc:spawned', netId, 'bounty')
    -- Make the bounty target hostile to EVERY player (it should fight back,
    -- not stand there). Relationship groups don't replicate, so broadcast the
    -- netId and each client applies it locally.
    TriggerClientEvent('npc:hostile:apply', -1, netId)
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

    -- nil if they dropped between claiming and this running, and scores[nil]
    -- throws, which would leave `active` set until the 10-minute timeout.
    local name = GetPlayerName(source) or 'someone'
    scores[name] = (scores[name] or 0) + 1

    -- Tell the scoreboard who won (credits their bounty counter) and drop the
    -- target from the hostile registry (it's dead now).
    if active.netId then
        TriggerEvent('scoreboard:npc:dead', active.netId)
    end
    announceBounty(false, nil, source)

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
