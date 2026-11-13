Config = {}

---------------------------------------------------------------------------
-- ta-arcade 共通
---------------------------------------------------------------------------

-- 管理者の権限（permissions.cfg に add_ace group.admin taArcade.admin allow）
Config.AdminAce = 'taArcade.admin'
-- 管理画面を開くコマンド
Config.AdminCommand = 'arcadeadmin'

-- この距離より近い台だけ置く（メートル）
Config.SpawnDistance = 80.0
-- 遊べる距離（サーバーで確かめる）
Config.UseDistance = 3.0

-- 画面の大きさ（画面の高さに対する倍率）
Config.UiScale = 1.0

-- 置けるゲームの種類。ゲームを足すときはここに 1 つ足し、server/ と client/ にそのゲームの処理を書く
--   model / chair: stream/ のモデル、chairOffset: 台から見た椅子の位置（台の正面は台の -Y 側）
--   width: 「隣にそろえる」ときの台の間隔（メートル）
Config.Games = {
    slot = {
        label = 'パチスロ 夜祭',
        model = `ta_slot_machine`,
        chair = `ta_slot_chair`,
        chairOffset = vec3(0.0, -0.80, 0.0),
        width = 0.62,
        settings = true, -- 設定 1〜6 がある
        defaultSetting = 1,
    },
    pachi = {
        label = 'パチンコ 宵花火',
        model = `ta_pachi_machine`,
        chair = `ta_slot_chair`, -- 椅子はパチスロと同じもの
        chairOffset = vec3(0.0, -0.80, 0.0),
        width = 0.62,
        settings = true,
        defaultSetting = 1,
    },
}
Config.GameOrder = { 'slot', 'pachi' }

---------------------------------------------------------------------------
-- パチスロ（slot）
---------------------------------------------------------------------------
Config.Slot = {}

-- お金（現金で直接遊ぶ）
Config.Slot.MedalPrice = 100000 -- メダル1枚の値段（円）。3枚掛けで1ゲーム 30万円（最低 BET）
Config.Slot.Bet = 3            -- 1ゲームに掛ける枚数
Config.Slot.MaxCredit = 50     -- 台にためておける枚数。超えた分はその場で現金で受け取る
Config.Slot.GameWait = 4100    -- 1ゲームの最短の間隔（ミリ秒）。サーバーでも確かめる

-- 台の設定（1〜6）。台を置くときに管理者が選ぶ。高いほど当たりやすい
Config.Slot.DefaultSetting = 1

-- 内部抽選（通常時）。数字は「何ゲームに1回」。設定ごとに書く
-- big_cherry / reg_cherry はチェリーとボーナスが同時に当たる（チェリーが揃い、ボーナスは次のゲームへ持ち越す）
-- 払い出しの割合の目安は README の表（tests/rtp.js で計算）
Config.Slot.Lottery = {
    [1] = { replay = 7.3, bell = 6.2, suika = 64, cherry = 40, big = 315, reg = 455, big_cherry = 1800, reg_cherry = 2400 },
    [2] = { replay = 7.3, bell = 6.1, suika = 64, cherry = 40, big = 300, reg = 420, big_cherry = 1700, reg_cherry = 2200 },
    [3] = { replay = 7.3, bell = 6.0, suika = 64, cherry = 40, big = 290, reg = 380, big_cherry = 1600, reg_cherry = 2000 },
    [4] = { replay = 7.3, bell = 5.9, suika = 60, cherry = 40, big = 275, reg = 340, big_cherry = 1500, reg_cherry = 1800 },
    [5] = { replay = 7.3, bell = 5.9, suika = 60, cherry = 38, big = 268, reg = 320, big_cherry = 1500, reg_cherry = 1700 },
    [6] = { replay = 7.3, bell = 5.8, suika = 56, cherry = 36, big = 255, reg = 290, big_cherry = 1400, reg_cherry = 1500 },
}

-- ボーナス。払い出しの合計が endPay 枚を超えたら終わる。毎ゲーム bellChance の確率でベル（15枚）
Config.Slot.Bonus = {
    big = { endPay = 252, bellChance = 0.92, label = 'BIG' },
    reg = { endPay = 96, bellChance = 0.92, label = 'REG' },
}

-- 告知ランプ。ボーナスが当たったゲームで、レバーを叩いた時に光らせる割合（残りは第3停止の後に光る）
Config.Slot.LampPreChance = 0.25

-- データカウンターに残すボーナスの履歴の数
Config.Slot.HistorySize = 10

-- 座った時の体の位置（台から見た位置）と、PROP_HUMAN_SEAT_CHAIR_MP_PLAYER の高さ合わせ
Config.Slot.SitOffset = vec3(0.0, -0.80, 0.60)
Config.Slot.SitScenario = 'PROP_HUMAN_SEAT_CHAIR_MP_PLAYER'

-- 告知ランプが光っている台は周りの人からも光って見える（台から見た位置・色・強さ）
Config.Slot.LampLight = { offset = vec3(-0.22, -0.30, 1.15), color = { 255, 90, 40 }, range = 1.6, intensity = 6.0 }

---------------------------------------------------------------------------
-- パチンコ（pachi）
---------------------------------------------------------------------------
Config.Pachi = {}

-- お金（現金で直接遊ぶ）
Config.Pachi.BallPrice = 20000  -- 玉1個の値段（円）
Config.Pachi.LendUnit = 25      -- 持ち玉が無いときに現金から借りる数（25玉 = 50万円）
Config.Pachi.MaxBalls = 2500    -- 持ち玉の上限。超えた分はその場で現金で受け取る
Config.Pachi.ShotInterval = 600 -- 打ち出しの間隔（ミリ秒）。サーバーでも確かめる
Config.Pachi.FallTime = 2400    -- 打った玉が入賞口に届くまでの時間（ミリ秒）。画面の玉の動きと合わせる

-- 台の設定（1〜6）。高いほど当たりやすい
Config.Pachi.DefaultSetting = 1

-- 大当たりの確率。数字は「何回転に1回」。通常時は設定ごと、確変中は共通
-- 払い出しの割合の目安は README の表（tests/pachi-rtp.lua で計算）
Config.Pachi.HitChance = { [1] = 228, [2] = 221, [3] = 214, [4] = 207, [5] = 201, [6] = 195 }
Config.Pachi.HighChance = 40

-- 大当たりのうち確変（奇数の図柄）になる割合。残りは通常当たり（偶数の図柄）で、時短が付く
Config.Pachi.KakuhenRate = 0.5
Config.Pachi.JitanSpins = 100 -- 時短の回転数

-- 保留の上限
Config.Pachi.HoldMax = 4

-- 玉1個が入賞口に入る割合と、入ったときの賞球
--   heso: 通常時のヘソ、denchu: 確変・時短中の電チュー、attacker: 大当たり中のアタッカー
Config.Pachi.Entry = { heso = 0.069, denchu = 0.33, attacker = 0.90 }
Config.Pachi.Pay = { heso = 3, denchu = 3, attacker = 15 }

-- 大当たり。1ラウンドはアタッカーに RoundCount 個入るまで
-- Rounds は { ラウンド数, 割合 } の並び。ヘソで当たったときと電チューで当たったときで分ける
Config.Pachi.RoundCount = 9
Config.Pachi.Rounds = {
    heso = { { 4, 0.8 }, { 10, 0.2 } },
    denchu = { { 4, 0.6 }, { 10, 0.4 } },
}

-- 時間（ミリ秒）
Config.Pachi.Time = {
    spin = 6000,         -- ハズレの変動
    spinShort = 3500,    -- 保留が2個以上あるときのハズレ
    spinSupport = 1800,  -- 確変・時短中のハズレ
    reach = 12000,       -- リーチがかかってハズレ
    reachSupport = 6000, -- 確変・時短中のリーチハズレ
    hit = 16000,         -- 大当たりの変動
    hitSupport = 9000,   -- 確変・時短中の大当たりの変動
    reachChance = 0.08,  -- ハズレのうちリーチになる割合
    fanfare = 2500,      -- 図柄が揃ってからアタッカーが開くまで
    roundGap = 1200,     -- ラウンドの間
    ending = 2500,       -- 大当たりが終わってから次の変動まで
}

-- データカウンターに残す大当たりの履歴の数
Config.Pachi.HistorySize = 10

-- 座った時の体の位置（台から見た位置）
Config.Pachi.SitOffset = vec3(0.0, -0.80, 0.60)
Config.Pachi.SitScenario = 'PROP_HUMAN_SEAT_CHAIR_MP_PLAYER'

-- 大当たり中・確変中・時短中の台は周りの人からも光って見える（台から見た位置・色・強さ）
Config.Pachi.LampLight = { offset = vec3(0.0, -0.30, 1.75), color = { 255, 120, 60 }, range = 1.8, intensity = 6.0 }
