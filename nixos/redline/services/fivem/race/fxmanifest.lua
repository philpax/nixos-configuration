fx_version 'cerulean'
game 'gta5'

name 'race'
author 'philpax'
description 'Co-op point-to-point races: host waypoint as finish, fair sports cars, live leaderboard.'
version '1.0.0'

ui_page 'nui/index.html'

client_script 'client.lua'
server_script 'server.lua'

files {
    'nui/index.html',
    'nui/style.css',
    'nui/app.js',
}