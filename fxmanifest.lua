fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'solis_tv'
author 'Solis (base: Ac Loaf / Mew Team)'
description 'Solis TV — Controle remoto e tela 3D DUI'
version '3.0.0'

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/tv_screen.html', -- player DUI local
    'html/style.css',
    'html/script.js'
}

shared_scripts {
    '@vrp/lib/utils.lua',
    'config.lua'
}

client_scripts {
    'client.lua'
}

server_scripts {
    'server.lua'
}

dependencies {
    'oxmysql'
}
