-- ta-arcade の起動: 表を作り、旧名（tani-arcade・tani-slot）の台を引き継ぎ、台を読み込む（ゲームの登録の後に読むこと）
local A = Arcade

local function hasTable(name)
    local r = MySQL.query.await(("SHOW TABLES LIKE '%s'"):format(name))
    return r ~= nil and #r > 0
end

-- 旧 tani-arcade（2026-11-13 の 1.x）の表は、新しい表と同じ形なので、そのまま写す
local function migrateFromTaniArcade()
    local rows = MySQL.query.await('SELECT * FROM tani_arcade_machines ORDER BY id') or {}
    for _, r in ipairs(rows) do
        MySQL.insert.await('INSERT INTO ta_arcade_machines (game, x, y, z, heading, setting, data, created_by) VALUES (?, ?, ?, ?, ?, ?, ?, ?)', {
            r.game or 'slot', r.x, r.y, r.z, r.heading, r.setting, r.data, r.created_by,
        })
    end
    if #rows > 0 then
        print(('[ta-arcade] 旧 tani-arcade の台を %d 台引き継ぎました（tani_arcade_machines は残しています）'):format(#rows))
    end
end

-- 旧 tani-slot（2026-11-13 の 1.0.0）の表は、データカウンターを JSON にまとめ直して写す
local function migrateFromTaniSlot()
    local rows = MySQL.query.await('SELECT * FROM tani_slot_machines') or {}
    for _, r in ipairs(rows) do
        local history = {}
        if r.history and r.history ~= '' then
            local ok, h = pcall(json.decode, r.history)
            if ok and type(h) == 'table' then history = h end
        end
        local data = { total = r.total_games or 0, big = r.big_count or 0, reg = r.reg_count or 0, since = r.since_bonus or 0, history = history }
        MySQL.insert.await('INSERT INTO ta_arcade_machines (game, x, y, z, heading, setting, data, created_by) VALUES (?, ?, ?, ?, ?, ?, ?, ?)', {
            'slot', r.x, r.y, r.z, r.heading, r.setting, json.encode(data), r.created_by,
        })
    end
    if #rows > 0 then
        print(('[ta-arcade] 旧 tani-slot の台を %d 台引き継ぎました（tani_slot_machines は残しています）'):format(#rows))
    end
end

-- 新しい表が空のときだけ、いちばん新しい旧名の表から一度だけ写す。旧い表は消さない
-- （tani-arcade の表があれば、台が 0 台でもそちらを正とし、tani-slot の表は見ない）
local function migrateOldTables()
    if (MySQL.scalar.await('SELECT COUNT(*) FROM ta_arcade_machines') or 0) > 0 then return end
    if hasTable('tani_arcade_machines') then
        migrateFromTaniArcade()
    elseif hasTable('tani_slot_machines') then
        migrateFromTaniSlot()
    end
end
A.migrateOldTables = migrateOldTables -- テストから呼ぶため

CreateThread(function()
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `ta_arcade_machines` (
            `id` INT NOT NULL AUTO_INCREMENT,
            `game` VARCHAR(32) NOT NULL DEFAULT 'slot',
            `x` DOUBLE NOT NULL,
            `y` DOUBLE NOT NULL,
            `z` DOUBLE NOT NULL,
            `heading` DOUBLE NOT NULL DEFAULT 0,
            `setting` TINYINT NOT NULL DEFAULT 1,
            `data` TEXT NULL,
            `created_by` VARCHAR(64) NULL,
            `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`)
        )
    ]])
    migrateOldTables()

    local rows = MySQL.query.await('SELECT * FROM ta_arcade_machines') or {}
    local count, skipped = 0, 0
    for _, row in ipairs(rows) do
        local m = A.newMachine(row)
        if m then
            A.machines[row.id] = m
            count = count + 1
        else
            skipped = skipped + 1
        end
    end
    print(('[ta-arcade] 台を %d 台読み込みました%s'):format(count,
        skipped > 0 and ('（知らないゲームの台 %d 台は出していません）'):format(skipped) or ''))
    A.broadcastList()

    -- ゲームの先回りの計算（1 回ごとに Wait を挟む）
    for _, mod in pairs(A.games) do
        if mod.warmup then mod.warmup(function() Wait(0) end) end
    end

    while true do
        Wait(60000)
        A.flushDirty()
    end
end)
