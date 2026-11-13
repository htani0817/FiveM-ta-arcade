fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'ta-arcade'
description 'Arcade games for the town. Pachislot "Yomatsuri" and pachinko "Yoihanabi" with custom machine and chair props, admin console and cash betting'
author 'Tani'
version '3.1.0'

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/style.css',
    'html/app.js',
    'html/admin.css',
    'html/admin.js',
    'html/pachi.css',
    'html/pachi.js',
    'html/img/*.png',
    'stream/ta_slot.ytyp',
    'stream/ta_pachi.ytyp',
}

data_file 'DLC_ITYP_REQUEST' 'stream/ta_slot.ytyp'
data_file 'DLC_ITYP_REQUEST' 'stream/ta_pachi.ytyp'

shared_scripts {
    '@ox_lib/init.lua',
    'config.lua',
    'shared/slot_engine.lua',
}

client_scripts {
    'client/main.lua',
    'client/slot.lua',
    'client/pachi.lua',
}

-- start.lua はゲームを登録した後に読む
server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/main.lua',
    'server/slot.lua',
    'server/pachi_engine.lua',
    'server/pachi.lua',
    'server/start.lua',
}

dependencies {
    'ox_lib',
    'ox_target',
    'oxmysql',
    'qbx_core',
}
