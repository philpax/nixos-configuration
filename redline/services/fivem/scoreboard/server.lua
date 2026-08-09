-- Live scoreboard server.
--
-- Authoritative store for per-player stats (kills, deaths, kill breakdown by
-- target class, bounty score) plus server context (live hostiles, active
-- bounty). Clients report their own ped state once a second; kills come from
-- the client that witnessed them so classification can happen where the
-- killer's perception of the victim lives. Nothing here is trusted beyond
-- best effort — this is a password-protected 12-slot freeroam sandbox, and
-- each client already knows everything these events carry about the world.

local MAX_PLAYERS = 12

-- netId -> { kind = "squad" | "survival" | "bounty", at = epoch_ms },
-- registered by the `npc` resource as its peds come into existence. Pruned
-- when the ped dies (scoreboard:kill / scoreboard:npc:dead) or when it goes
-- stale (see the tick below), so a reused netId or an un-witnessed death can
-- never misclassify an NPC kill or inflate the alive count forever.
local hostileNpcs = {}

-- source -> player record
local players = {}

local bounty = {
    live = false,
    name = nil,
}

local function nowMs()
    return os.time() * 1000
end

local function recordFor(source)
    local p = players[source]
    if not p then
        p = {
            source = source,
            name = GetPlayerName(source) or 'Unknown',
            ping = 0,
            vehicle = '',
            alive = true,
            pedModel = '',
            kills = { player = 0, squad = 0, survival = 0, bounty = 0, police = 0, misc_npc = 0, ambient = 0 },
            totalKills = 0,
            deaths = 0,
            bounty = 0,
            lastSeenMs = nowMs(),
            _reportedOnce = false,
        }
        players[source] = p
    end
    return p
end

local function creditKill(source, kind)
    local p = recordFor(source)
    p.totalKills = p.totalKills + 1
    p.kills[kind] = p.kills[kind] + 1
    p.lastSeenMs = nowMs()
end

local function serializePlayer(p)
    local total = p.totalKills
    local kd = nil
    if p.deaths > 0 then
        kd = math.floor((total / p.deaths) * 100) / 100
    end

    return {
        id = p.source,
        name = p.name,
        ping = p.ping,
        vehicle = p.vehicle,
        alive = p.alive,
        kills = {
            total = total,
            player = p.kills.player,
            squad = p.kills.squad,
            survival = p.kills.survival,
            bounty = p.kills.bounty,
            police = p.kills.police,
            misc_npc = p.kills.misc_npc,
            ambient = p.kills.ambient,
        },
        deaths = p.deaths,
        kd = kd,
        bounty = p.bounty,
    }
end

local function playerList()
    local list = {}
    for source in pairs(players) do
        list[#list + 1] = serializePlayer(players[source])
    end
    table.sort(list, function(a, b)
        if a.kills.total ~= b.kills.total then
            return a.kills.total > b.kills.total
        end
        return (a.name or '') < (b.name or '')
    end)
    return list
end

-- How many hostile NPCs the spawning resources currently believe are alive.
-- The registry only holds netIds of peds that were created; dead peds leave
-- the registry in the scoreboard:kill handler.
local function liveHostileCount()
    local n = 0
    for _ in pairs(hostileNpcs) do
        n = n + 1
    end
    return n
end

-- Bounty/survival lifecycles are short (squads die fast; the bounty target
-- despawns on timeout at 10 min), so anything older than this was never
-- reported dead and is safe to forget. Keeps the registry bounded even if a
-- spawning client crashes mid-hunt.
local NPC_STALE_MS = 15 * 60 * 1000

local function broadcast()
    TriggerClientEvent('scoreboard:data', -1, {
        serverName = 'redline sandbox',
        players = playerList(),
        hostiles = liveHostileCount(),
        bounty = bounty.live and bounty.name or nil,
        updatedAt = nowMs(),
    })
end

-- Client says it loaded; log it so a dead scoreboard is diagnosable.
RegisterNetEvent('scoreboard:hello', function()
    print(('[scoreboard] client %s (%d) reporting in'):format(GetPlayerName(source) or 'Unknown', source))
end)

-- Tick: purge stale players, then push the snapshot to everyone.
CreateThread(function()
    while true do
        Wait(1000)
        local t = nowMs()
        local stale = {}
        for source, p in pairs(players) do
            if p.leftAt and t - p.leftAt > 3000 then
                stale[#stale + 1] = source
            elseif t - p.lastSeenMs > 10000 then
                stale[#stale + 1] = source
            end
        end
        for _, source in ipairs(stale) do
            players[source] = nil
        end

        -- Forget stale hostile registrations (see NPC_STALE_MS).
        for netId, entry in pairs(hostileNpcs) do
            if t - entry.at > NPC_STALE_MS then
                hostileNpcs[netId] = nil
            end
        end

        broadcast()
    end
end)

-- ---------------------------------------------------------------------------
-- Client reports
-- ---------------------------------------------------------------------------

RegisterNetEvent('scoreboard:report', function(data)
    local source = source
    if not data or type(data) ~= 'table' then
        return
    end

    local p = recordFor(source)
    -- One line per player per session. Distinguishes "the client script never
    -- loaded" from "reports aren't arriving", which is otherwise invisible here.
    if not p._reportedOnce then
        p._reportedOnce = true
        print(('[scoreboard] first report from %d (%s)'):format(source, p.name))
    end
    p.name = GetPlayerName(source) or p.name
    p.leftAt = nil
    p.lastSeenMs = nowMs()

    -- Ping is read here, not sent by the client: GetPlayerPing is server-only.
    p.ping = GetPlayerPing(source) or 0

    if type(data.vehicle) == 'string' then
        p.vehicle = data.vehicle
    end
    if type(data.alive) == 'boolean' then
        p.alive = data.alive
    end
end)

-- ---------------------------------------------------------------------------
-- Kill / death attribution
-- ---------------------------------------------------------------------------

-- data.victimIsPlayer: the victim was a player (we still distinguish at the
--   receiving client which player; this just routes to the right bucket).
-- data.victimNetId:  the netId of the dead ped, when it had one. Player peds
--   are only networked when relevant; ambient world NPCs and animals have no
--   netId at all, which is how they fall into the ambient bucket.
RegisterNetEvent('scoreboard:kill', function(data)
    local killerSource = source
    if not data or type(data) ~= 'table' then
        return
    end

    if data.victimIsPlayer then
        creditKill(killerSource, 'player')
        return
    end

    -- An NPC with a police model is a cop (vMenu-spawned, ambient, script-
    -- spawned), whatever its netId. The hostile registry never contains police
    -- models (gangs/mob boss only), so this can't override squad/bounty kind.
    if data.victimIsPolice then
        creditKill(killerSource, 'police')
        return
    end

    local netId = tonumber(data.victimNetId)
    if not netId then
        -- No netId: the victim couldn't be a script NPC, so it was ambient.
        creditKill(killerSource, 'ambient')
        return
    end

    -- The spawning client may not have registered the ped yet (network race),
    -- and an un-owned NPC may surface a netId only after the kill. Handle the
    -- common case immediately; defer the rest through a short queue.
    local function classify(nid)
        local entry = hostileNpcs[nid]
        if entry then
            hostileNpcs[nid] = nil
            return entry.kind
        end
        return nil
    end

    local kind = classify(netId)
    if kind then
        creditKill(killerSource, kind)
        return
    end

    -- Unknown NPC netId: try once more shortly in case a registration from
    -- the spawning client is in flight. If it never lands, count as misc NPC.
    CreateThread(function()
        Wait(200)
        -- Don't resurrect a ghost record for a player who left during the
        -- defer window (creditKill recreates via recordFor).
        local p = players[killerSource]
        if not p or p.leftAt then
            return
        end
        local late = classify(netId)
        creditKill(killerSource, late or 'misc_npc')
    end)
end)

-- Own death, reported by the client that died (CEventPlayerDeath only fires
-- there). Guarded client-side against double-fires within 2s.
RegisterNetEvent('scoreboard:death', function()
    local source = source
    local p = recordFor(source)
    p.deaths = p.deaths + 1
    p.lastSeenMs = nowMs()
end)

-- ---------------------------------------------------------------------------
-- NPC resource integration
-- ---------------------------------------------------------------------------

-- The `npc` resource's client registers peds it spawns (per-netId) as they
-- appear, and clears them when they die, so the scoreboard's hostile counter
-- and NPC kill buckets stay honest. Client-originated: uses RegisterNetEvent.
RegisterNetEvent('scoreboard:npc:spawned', function(netId, kind)
    if type(netId) ~= 'number' or netId == 0 then
        return
    end
    if kind ~= 'squad' and kind ~= 'survival' and kind ~= 'bounty' then
        return
    end
    hostileNpcs[netId] = { kind = kind, at = nowMs() }
end)

RegisterNetEvent('scoreboard:npc:dead', function(netId)
    if type(netId) ~= 'number' then
        return
    end
    hostileNpcs[netId] = nil
end)

-- Bounty state comes from the `npc` resource's *server* script, so this is a
-- server-internal event (AddEventHandler, not RegisterNetEvent):
--   { live = bool, name = string|nil, winner = serverId|nil }
AddEventHandler('scoreboard:bounty', function(state)
    if not state or type(state) ~= 'table' then
        return
    end

    if state.winner then
        local p = players[state.winner]
        if p then
            p.bounty = p.bounty + 1
        end
    end

    -- Only when the sender says something about it: /mark and the shared NPC
    -- bounty both credit winners through this event, and a /mark payout must
    -- not blank a live NPC bounty's footer.
    if state.live ~= nil then
        bounty.live = state.live == true
        bounty.name = type(state.name) == 'string' and state.name or nil
    end
end)

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

AddEventHandler('playerDropped', function()
    local p = players[source]
    if p then
        p.leftAt = nowMs()
        p.alive = false
    end
end)

-- Local sanity check of the client's report cadence (paranoid but useful for
-- a server that double-reports kills): nothing to do here at startup.
CreateThread(function()
    Wait(0)
    print('[scoreboard] ready (' .. MAX_PLAYERS .. ' slots)')
end)