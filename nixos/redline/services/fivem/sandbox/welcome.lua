-- Prints the command list in chat once, the first time you spawn.
--
-- Lives in `sandbox` but covers the `npc` resource's commands too: a player
-- doesn't care which resource a command came from, and one list beats two.
-- Keep it in sync when commands are added on either side.

local COMMANDS = {
    { 'F7', 'vMenu — peds, vehicles, weapons, teleports, settings.' },
    { 'F2', 'Toggle noclip.' },
    { '/car <model>', 'Spawn a vehicle and get in it. Defaults to adder.' },
    { '/dv', 'Delete the vehicle you are in.' },
    { '/fix', 'Repair and clean the vehicle you are in.' },
    { '/tp <x> <y> <z>', 'Teleport to coordinates.' },
    { '/wp', 'Teleport to your map waypoint.' },
    { '/heal', 'Full health and armour.' },
    { '/squad [n] [tier]', 'Spawn hostile NPCs. tier 1-5. /squad clear removes them.' },
    { '/survival', 'Escalating waves of hostiles. Run again to stop.' },
    { '/bounty', 'Put a target on the map. First to kill it wins.' },
    { '/bounties', 'Show the bounty scoreboard.' },
}

local shown = false

AddEventHandler('playerSpawned', function()
    if shown then
        return
    end
    shown = true

    CreateThread(function()
        -- The chat resource renders nothing while the loading screen is still
        -- up, so an immediate message is simply lost.
        Wait(3000)

        TriggerEvent('chat:addMessage', {
            color = { 120, 200, 255 },
            multiline = true,
            args = { 'redline', 'Welcome. Commands:' },
        })

        for _, command in ipairs(COMMANDS) do
            TriggerEvent('chat:addMessage', {
                color = { 120, 200, 255 },
                multiline = true,
                args = { command[1], command[2] },
            })
            Wait(50)
        end
    end)
end)
