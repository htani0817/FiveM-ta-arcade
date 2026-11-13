-- ta-arcade の台の置き場所とデータ。サーバーの起動時に自動で作るので、普段は流さなくてよい
-- data はゲームごとのデータカウンター（JSON）。旧名の表（tani-arcade の tani_arcade_machines、tani-slot の tani_slot_machines）は、この表が空のときに起動時に一度だけ写す
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
);
