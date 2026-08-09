-- Race server (co-op point-to-point race).
--
-- Lifecycle:
--   /race            -> the invoker's map waypoint becomes the finish; a
--                       countdown runs and everyone spawns the same car.
--   /race turtle     -> same, but the invoker is handicapped: the field draws
--                       from the fast end of the pool and they draw from the
--                       slow end.
--   /race cancel     -> abort.
--
-- The server owns race state (finish coords, car, participants, standings,
-- current leader). Clients: request the race (race:request with their
-- waypoint), register ready (race:ready), report live position
-- (race:position) for the leaderboard, and report crossing the finish
-- (race:finish).

-- Spawn names, grouped by pace. A normal race draws one model from all of them
-- at once; turtle mode draws the field from FAST and the host from SLOW. A
-- model missing from the enforced game build kills the race for everyone who
-- drew it, not just one player.
local SPORTS = {
    'elegy2', 'futo', 'comet2', 'ninef', 'jester', 'massacro', 'seven70',
    'pariah', 'sultan', 'kuruma', 'feltzer2', 'buffalo2', 'banshee',
    'carbonizzare', 'rapidgt', 'alpha', 'penumbra', 'schafter3', 'sentinel3',
    'italigto', 'jugular', 'komoda', 'neo', 'paragon', 'sugoi', 'vstr',
    'coquette', 'furoregt', 'lynx', 'omnis', 'tropos', 'verlierer2',
}

local SMALL = {
    'panto', 'issi2', 'blista', 'brioso', 'weevil', 'veto', 'veto2', 'dilettante',
}

local OFFROAD = {
    'dune', 'bifta', 'bfinjection', 'blazer', 'rebel2', 'sandking', 'monster',
    'nightshark', 'insurgent', 'rallytruck', 'brawler',
}

local MOTORBIKES = { 'sanchez', 'bati' }

-- Working vehicles, pedal power and one moped: the slow end. Every one of
-- these loses to anything in SPORTS over any distance, which is what turtle
-- mode is buying.
local SLOW = {
    'caddy', 'caddy2', 'airtug', 'forklift', 'mower', 'tractor2', 'towtruck',
    'ripley', 'docktug', 'utillitruck', 'flatbed', 'trash', 'rubble',
    'bulldozer', 'dumper', 'phantom', 'packer',
    'faggio2', 'bmx', 'tribike', 'cruiser', 'scorcher',
}

-- Public transport and other bad ideas.
local TRANSPORT = {
    'bus', 'coach', 'taxi', 'stretch', 'romero', 'journey', 'surfer',
    'ambulance', 'firetruk', 'police', 'boxville5', 'brickade', 'rhino',
}

local function joinPools(...)
    local out = {}
    for _, group in ipairs({ ... }) do
        for _, model in ipairs(group) do
            out[#out + 1] = model
        end
    end
    return out
end

local CAR_POOL = joinPools(SPORTS, SMALL, OFFROAD, MOTORBIKES, SLOW, TRANSPORT)

-- Disjoint by construction, which is what keeps the host's car strictly slower
-- than the field's without having to compare the two draws.
local FAST_POOL = SPORTS
local TURTLE_POOL = SLOW

local function drawCar(pool)
    return pool[math.random(#pool)]
end

local race = nil

-- Forward declaration: race:finish calls this before its definition below.
local finishRace

-- Everyone races race.car except the host of a turtle race, who races the one
-- slow draw. Only ever called with a real player id — the console can't reach
-- race:request, so startedBy is always someone's server id.
local function carFor(playerId)
    if race and race.turtleCar and playerId == race.startedBy then
        return race.turtleCar
    end
    return race and race.car or nil
end

local function ordinal(n)
    local mod10 = n % 10
    local mod100 = n % 100
    if mod10 == 1 and mod100 ~= 11 then return n .. 'st' end
    if mod10 == 2 and mod100 ~= 12 then return n .. 'nd' end
    if mod10 == 3 and mod100 ~= 13 then return n .. 'rd' end
    return n .. 'th'
end

-- m:ss.hh, no hour field.
local function formatTime(ms)
    if type(ms) ~= 'number' or ms < 0 then
        return '--:--'
    end
    local hundredths = math.floor(ms / 10)
    local seconds = math.floor(hundredths / 100)
    return ('%d:%02d.%02d'):format(
        math.floor(seconds / 60), seconds % 60, hundredths % 100)
end

local function broadcast(message)
    TriggerClientEvent('chat:addMessage', -1, {
        color = { 90, 200, 255 },
        multiline = true,
        args = { 'race', message },
    })
end

local function finishOrder(list)
    -- Finished first (by order), then still going (by live distance to finish,
    -- closest = leading), then DNFs.
    table.sort(list, function(a, b)
        if a.finished ~= b.finished then return a.finished end
        if a.finished then return a.order < b.order end
        if a.dnf ~= b.dnf then return b.dnf end
        return (a.distance or math.huge) < (b.distance or math.huge)
    end)
end

local function broadcastStandings()
    if not race then
        return
    end
    -- Finishers keep their final time, everyone else gets a live clock. nil
    -- during the countdown, which the NUI renders as a dash.
    local now = GetGameTimer()
    local list = {}
    for id, p in pairs(race.participants) do
        local elapsedMs = nil
        if p.elapsedMs then
            elapsedMs = p.elapsedMs
        elseif race.startedAt then
            elapsedMs = now - race.startedAt
        end

        list[#list + 1] = {
            id = id,
            name = p.name,
            car = p.vehicleModel,
            finished = p.finishedAt ~= nil,
            dnf = p.dnf == true,
            order = p.order or 0,
            distance = p.distance,
            elapsedMs = elapsedMs,
        }
    end
    finishOrder(list)
    -- Current leader = first still going (or the winner if everyone's done).
    local leader = nil
    for _, entry in ipairs(list) do
        if not entry.finished and not entry.dnf then
            leader = entry.id
            break
        end
    end
    -- Falls back to the winner once everyone's home, but never to a DNF: an
    -- all-DNF field has no leader to name.
    leader = leader or (list[1] and list[1].finished and list[1].id) or nil

    TriggerClientEvent('race:standings', -1, {
        status = race.status,
        car = race.car,
        turtleCar = race.turtleCar,
        leader = leader,
        list = list,
    })
end

-- Standings order by distance, which changes continuously, so they need a timer
-- of their own — every other caller of broadcastStandings is a discrete event.
CreateThread(function()
    while true do
        Wait(1000)
        if race and (race.status == 'countdown' or race.status == 'running') then
            broadcastStandings()
        end
    end
end)

-- Client -> server: "start a race to my waypoint."
RegisterNetEvent('race:request', function(wp, mode)
    local source = source
    if race then
        TriggerClientEvent('chat:addMessage', source, {
            color = { 90, 200, 255 },
            multiline = true,
            args = { 'race', '^1a race is already running — /race cancel to stop it' },
        })
        return
    end

    if not wp or type(wp) ~= 'table' or not wp.x or not wp.y then
        race = nil
        TriggerClientEvent('chat:addMessage', source, {
            color = { 90, 200, 255 },
            multiline = true,
            args = { 'race', '^1set a waypoint on your map first, then /race' },
        })
        return
    end

    -- The field's draw is narrowed to FAST_POOL in turtle mode, so the handicap
    -- doesn't get undone by the field drawing a bulldozer.
    local turtle = mode == 'turtle'

    race = {
        finish = { x = wp.x, y = wp.y, z = wp.z or 0.0 },
        finishName = wp.name or 'the waypoint',
        car = drawCar(turtle and FAST_POOL or CAR_POOL),
        turtleCar = turtle and drawCar(TURTLE_POOL) or nil,
        startedBy = source,
        startedByName = GetPlayerName(source) or 'console',
        status = 'countdown',
        countdownEndsAt = GetGameTimer() + 5000,
        participants = {},
    }

    if race.turtleCar then
        broadcast(('%s is running a turtle race to %s — the field gets the %s, they get the %s — GO in 5s!'):format(
            race.startedByName, race.finishName, race.car, race.turtleCar))
    else
        broadcast(('%s is running a race to %s in the %s — GO in 5s!'):format(
            race.startedByName, race.finishName, race.car))
    end

    -- Sent per player rather than broadcast: in turtle mode the host's model
    -- differs from everyone else's, and a second race:begin to the same client
    -- would delete the car the first one just spawned.
    for _, id in ipairs(GetPlayers()) do
        local playerId = tonumber(id)
        TriggerClientEvent('race:begin', playerId, race.finish, race.finishName, 5000, carFor(playerId))
    end
    -- Re-activate the leaderboard NUI immediately for a new race (so a second
    -- race after a previous one gets live standings from the start).
    broadcastStandings()
end)

-- Client -> server: "I got the begin and I'm in a car." The model isn't taken
-- from the client — everyone races race.car by construction.
RegisterNetEvent('race:ready', function()
    local source = source
    -- 'running' counts too: the client only readies once loadModel returns,
    -- which can take longer than the 5s countdown on a cold model. Entering
    -- late beats not being in the race at all.
    if not race or (race.status ~= 'countdown' and race.status ~= 'running') then
        return
    end
    if race.participants[source] then
        return
    end
    race.participants[source] = {
        name = GetPlayerName(source) or 'Unknown',
        vehicleModel = carFor(source),
        finishedAt = nil,
        order = 0,
        distance = nil,
    }
end)

-- At most two models are in play and both are drawn once for the whole race, so
-- one that won't load means that race can't run. Named in chat and the log
-- because removing it from the pools is the only fix.
RegisterNetEvent('race:loadfailed', function(car)
    if not race or race.status ~= 'countdown' then
        return
    end
    if car ~= race.car and car ~= race.turtleCar then
        return
    end
    broadcast(('^1"%s" failed to load — race cancelled'):format(tostring(car)))
    print(('[race] model %s failed to load on a client; consider removing it from CAR_POOL'):format(tostring(car)))
    race = nil
    TriggerClientEvent('race:ended', -1)
end)

-- Live position for the leaderboard, 2/sec. Accepted during the countdown so
-- the board is ordered before GO.
RegisterNetEvent('race:position', function(x, y)
    local source = source
    if not race or (race.status ~= 'running' and race.status ~= 'countdown') then
        return
    end
    local p = race.participants[source]
    if not p or p.finishedAt or p.dnf then
        return
    end
    -- `x ~= x` rejects NaN, which is type "number" and compares false against
    -- every bound below, including the finish-distance check.
    if type(x) == 'number' and type(y) == 'number' and x == x and y == y then
        p.distance = #(vector3(x, y, 0) - vector3(race.finish.x, race.finish.y, 0))
    end
end)

-- How far a client's self-reported elapsed time may sit below the server's own
-- measurement before it's treated as a lie. Legitimately it runs short by one
-- network hop plus the race:go broadcast spread, i.e. tens of milliseconds.
local MAX_CLOCK_SKEW_MS = 2000

-- Slack on purpose: the server's view of a player's position is up to 500ms
-- stale, ~30m at racing speed. It rejects nonsense, it doesn't judge close calls.
local MAX_FINISH_DISTANCE = 250.0

-- Counted with pairs: `participants` is keyed by server id, so `#` on it is
-- meaningless. A DNF counts as settled — otherwise a wrecked field holds the
-- race open until MAX_RACE_MS.
local function raceIsComplete()
    local total, settled = 0, 0
    for _, p in pairs(race.participants) do
        total = total + 1
        if p.finishedAt or p.dnf then
            settled = settled + 1
        end
    end
    return total > 0 and settled >= total
end

-- Places come from elapsed times, never from arrival order — the latter ranks
-- by ping, and permanently, since a report is only ever seen once.
local function recomputeOrder()
    local finishers = {}
    for id, p in pairs(race.participants) do
        if p.finishedAt then
            finishers[#finishers + 1] = { id = id, elapsedMs = p.elapsedMs or math.huge }
        end
    end

    table.sort(finishers, function(a, b)
        if a.elapsedMs ~= b.elapsedMs then
            return a.elapsedMs < b.elapsedMs
        end
        -- Dead heat: settle it deterministically.
        return a.id < b.id
    end)

    for i, entry in ipairs(finishers) do
        race.participants[entry.id].order = i
    end
end

-- "I crossed the finish", with the elapsed time the client measured against its
-- own race:go.
RegisterNetEvent('race:finish', function(clientElapsedMs)
    local source = source
    if not race or race.status ~= 'running' then
        return
    end
    local p = race.participants[source]
    if not p or p.finishedAt or p.dnf then
        return
    end

    -- Not proof — p.distance is self-reported too — but it costs nothing.
    if p.distance and p.distance > MAX_FINISH_DISTANCE then
        print(('[race] ignoring finish from %s: last known distance %.0fm'):format(p.name, p.distance))
        return
    end

    p.finishedAt = GetGameTimer()
    p.distance = 0

    -- The server's own measure is the ceiling: a report cannot describe a
    -- crossing later than its own arrival. `elapsed ~= elapsed` rejects NaN,
    -- which fails both bounds and would otherwise throw in formatTime's "%d"
    -- after finishedAt was set, stranding the race.
    local serverElapsed = race.startedAt and (p.finishedAt - race.startedAt) or 0
    local elapsed = tonumber(clientElapsedMs)
    if not elapsed or elapsed ~= elapsed
        or elapsed > serverElapsed or elapsed < serverElapsed - MAX_CLOCK_SKEW_MS then
        elapsed = serverElapsed
    end
    p.elapsedMs = elapsed

    recomputeOrder()

    -- Provisional: an in-flight report from someone who crossed earlier can
    -- still reorder this. The podium is the authority.
    broadcast(('%s finished %s in %s'):format(
        p.name, ordinal(p.order), formatTime(p.elapsedMs)))
    broadcastStandings()

    if raceIsComplete() then
        finishRace()
    end
end)

-- Client -> server: "my car is a write-off." Self-reported, like every other
-- client claim here — it costs the reporter their own race, so there's nothing
-- to gain by lying.
RegisterNetEvent('race:dnf', function()
    local source = source
    if not race or (race.status ~= 'running' and race.status ~= 'countdown') then
        return
    end
    local p = race.participants[source]
    if not p or p.finishedAt or p.dnf then
        return
    end

    p.dnf = true
    -- Otherwise they keep a leading distance on the board forever.
    p.distance = nil
    broadcast(('^1%s is out — wrecked car'):format(p.name))
    broadcastStandings()

    if race.status == 'running' and raceIsComplete() then
        finishRace()
    end
end)

local function cancelRace(source, notifyClients)
    if not race then
        if notifyClients and source ~= 0 then
            TriggerClientEvent('chat:addMessage', source, {
                color = { 90, 200, 255 },
                multiline = true,
                args = { 'race', 'no race running' },
            })
        end
        return
    end
    race = nil
    TriggerClientEvent('race:ended', -1)
    if notifyClients then
        broadcast('race cancelled')
    end
end

-- Assigns the local forward-declared at the top of the file.
function finishRace()
    if not race then
        return
    end
    race.status = 'finished'
    broadcastStandings()

    local order = {}
    for _, p in pairs(race.participants) do
        if p.finishedAt then
            order[p.order] = { name = p.name, elapsedMs = p.elapsedMs }
        end
    end

    -- Winner's time in full, everyone else as a gap behind them.
    local winnerMs = order[1] and order[1].elapsedMs or nil
    local podium = {}
    for i, entry in ipairs(order) do
        local time
        if i == 1 or not winnerMs or not entry.elapsedMs then
            time = formatTime(entry.elapsedMs)
        else
            time = ('+%s'):format(formatTime(entry.elapsedMs - winnerMs))
        end
        podium[#podium + 1] = ('%s. %s (%s)'):format(ordinal(i), entry.name, time)
    end

    -- Reachable now that DNFs settle the race: a field that all wrecks gets
    -- here with nobody to put on the podium.
    if #podium == 0 then
        broadcast('^1race over — nobody made it to the finish')
    else
        broadcast('^2Race finished! ' .. table.concat(podium, ' | '))
    end

    -- Captured, because the current race 15s from now may be a different one —
    -- cancelling and restarting inside the window is enough.
    local thisRace = race
    CreateThread(function()
        Wait(15000)
        if race == thisRace then
            race = nil
            TriggerClientEvent('race:ended', -1)
        end
    end)
end

-- Completion is only evaluated when someone finishes or drops, so one AFK
-- racer would otherwise hold `race` forever and block /race server-wide.
local MAX_RACE_MS = 20 * 60 * 1000

CreateThread(function()
    while true do
        Wait(5000)
        if race and race.status == 'running' and race.startedAt
            and GetGameTimer() - race.startedAt > MAX_RACE_MS then
            local anyFinished = false
            for _, p in pairs(race.participants) do
                if p.finishedAt then
                    anyFinished = true
                    break
                end
            end

            if anyFinished then
                broadcast('^3race timed out — closing with the finishers so far')
                finishRace()
            else
                broadcast('^1race timed out with nobody finishing — cancelled')
                race = nil
                TriggerClientEvent('race:ended', -1)
            end
        end
    end
end)

-- Countdown -> running.
CreateThread(function()
    while true do
        Wait(100)
        if race and race.status == 'countdown' and GetGameTimer() >= race.countdownEndsAt then
            race.status = 'running'
            -- The scheduled instant, not GetGameTimer(): this thread polls at
            -- 100ms and every finish time is measured from here.
            race.startedAt = race.countdownEndsAt
            TriggerClientEvent('race:go', -1)
            broadcast('^2GO!')
            broadcastStandings()
        end
    end
end)

-- /race cancel (and a fallback hint for starting).
RegisterCommand('race', function(source, args)
    if args[1] == 'cancel' then
        cancelRace(source, true)
        return
    end

    -- Starting is client-side (the client has the waypoint).
    TriggerClientEvent('chat:addMessage', source, {
        color = { 90, 200, 255 },
        multiline = true,
        args = { 'race', 'set a waypoint and use /race in-game to start.' },
    })
end, false)

-- Client-forwarded cancel (the client's /race command forwards `cancel` here
-- so it isn't shadowed by the client-side command).
RegisterNetEvent('race:cancel', function()
    cancelRace(source, true)
end)

-- Cleanup when someone drops.
AddEventHandler('playerDropped', function()
    if not race then
        return
    end

    -- Not once 'finished': the podium is on screen for 15s and the teardown
    -- thread will clear it on schedule.
    if source == race.startedBy and race.status ~= 'finished' then
        broadcast('the race host left — race cancelled')
        race = nil
        TriggerClientEvent('race:ended', -1)
        return
    end

    -- Unfinished leavers are dropped, or they hold the completion check open
    -- forever. Finishers stay: removing one leaves a hole in the 1..n order
    -- array, which truncates the podium's ipairs.
    if race.participants[source] and not race.participants[source].finishedAt then
        race.participants[source] = nil
        broadcastStandings()

        if race.status == 'running' and raceIsComplete() then
            finishRace()
        end
    end
end)