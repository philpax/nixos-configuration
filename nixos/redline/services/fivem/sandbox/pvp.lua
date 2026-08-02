-- Keeps friendly fire applied.
--
-- vMenu applies vmenu_pvp_mode once, during its post-permission setup.
-- SetCanAttackFriendly is a per-ped flag, so any ped swap drops it — and
-- spawnmanager calls SetPlayerModel on every respawn, because
-- fivem-map-skater attaches a ped model to its spawnpoints. Without this, PvP
-- stops working for a player the first time they die.
--
-- Mirrors vMenu's calls off the same convar so the two can't disagree about
-- what PvP means. Reasserted unconditionally rather than on ped change: ped
-- handles come from a reused index pool, so a new ped can land on the old
-- handle and defeat change-detection. These are flag setters and cost
-- nothing.

CreateThread(function()
    while true do
        Wait(1000)

        local pvpMode = GetConvarInt('vmenu_pvp_mode', 0)
        if pvpMode == 1 then
            NetworkSetFriendlyFireOption(true)
            SetCanAttackFriendly(PlayerPedId(), true, false)
        elseif pvpMode == 2 then
            NetworkSetFriendlyFireOption(false)
            SetCanAttackFriendly(PlayerPedId(), false, false)
        end
    end
end)
