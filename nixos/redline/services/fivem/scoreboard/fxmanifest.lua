fx_version 'cerulean'
game 'gta5'

name 'scoreboard'
author 'philpax'
description 'Live player scoreboard: kills/deaths/K-D, kill breakdown, ping, vehicle.'
version '1.0.0'

ui_page 'nui/index.html'

client_script 'client.lua'
server_script 'server.lua'

files {
    'nui/index.html',
    'nui/style.css',
    'nui/app.js',
}