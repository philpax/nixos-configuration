fx_version 'cerulean'
game 'gta5'

name 'npc'
author 'philpax'
description 'NPC gameplay for the freeroam sandbox: /squad, /survival, /bounty. Reports spawns to the scoreboard resource.'
version '1.1.0'

client_scripts {
    'hostiles.lua',
    'bounty_client.lua',
}

server_script 'bounty_server.lua'
