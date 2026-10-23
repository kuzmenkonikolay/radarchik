import Foundation

/// Схема базы и миграции — одни на все репозитории: деньги (v1), наблюдение (v2),
/// советы (v3), ресурсы мака (v4), «Защита» (v5), день списания у трат (v6)
/// и «Сетевой надзор» (v7).
/// Номер версии лежит в PRAGMA user_version. Миграции только добавляются,
/// старые не меняются: у пользователя уже есть база версии 1.
public enum DatabaseSchema {
    public static var latestVersion: Int { migrations.count }

    /// Догоняет базу до `target` (по умолчанию до последней версии) одной транзакцией.
    public static func migrate(_ db: Database, upTo target: Int = latestVersion) throws {
        let current = try db.userVersion()
        guard current < target else { return }
        try db.transaction {
            for version in (current + 1)...target {
                try db.execute(migrations[version - 1])
            }
            try db.setUserVersion(target)
        }
    }

    private static let migrations = [v1Money, v2Activity, v3Reviews, v4Resources, v5Guard, v6DueDay, v7Network]

    /// v7 («Сетевой надзор», 2026-10-22): кто куда ходил — пара «источник → адрес»
    /// со счётчиком, чтобы говорить только о новом. Источник — скрипт с путём или
    /// инструмент агента, адрес — имя из DNS или IP. Чистится вместе с журналом (60 дней).
    private static let v7Network = """
        CREATE TABLE network_seen (
            identity TEXT NOT NULL,          -- net|script|/opt/homebrew/bin/node /…/install.js
            name TEXT NOT NULL,              -- «node install.js», «Claude Code · curl»
            host TEXT NOT NULL,              -- имя из DNS или адрес
            project TEXT,                    -- папка репозитория, где это случилось
            first_seen REAL NOT NULL,
            last_seen REAL NOT NULL,
            count INTEGER NOT NULL DEFAULT 1,
            level TEXT NOT NULL DEFAULT 'info',
            PRIMARY KEY (identity, host)
        );
        CREATE INDEX network_seen_last ON network_seen(last_seen);
        """

    /// v6 (дизайн v2, 2026-10-20): день месяца, когда списывают регулярную трату, —
    /// по нему за пару дней приходит алерт «Пора платить». NULL — день не задан.
    private static let v6DueDay = """
        ALTER TABLE recurring_costs ADD COLUMN due_day INTEGER;
        """

    /// v5: «Защита» (SPEC §3б). Журнал того, что заметил Радарчик (процессы,
    /// проверка кода, настройки Claude), с твоими ответами — 60 дней,
    /// и список «разрешать всегда» — бессрочно. Секретов здесь нет: командные
    /// строки и куски кода вычищаются до записи.
    private static let v5Guard = """
        CREATE TABLE guard_events (
            id INTEGER PRIMARY KEY,
            kind TEXT NOT NULL,              -- process | code | audit | keys
            level TEXT NOT NULL,             -- info | warning | critical
            at REAL NOT NULL,
            title TEXT NOT NULL,             -- фраза Радарчика
            detail TEXT,                     -- командная строка или файл:строка, без секретов
            allow_key TEXT,                  -- угроза|программа|родитель — для «Разрешать всегда»
            status TEXT NOT NULL DEFAULT 'active',  -- active | killed | allowedOnce | allowedAlways | dismissed | resolved | logged
            status_changed_at REAL
        );
        CREATE INDEX guard_events_at ON guard_events(at);
        CREATE INDEX guard_events_allow_key ON guard_events(allow_key);
        CREATE TABLE guard_allowed (
            allow_key TEXT PRIMARY KEY,
            created_at REAL NOT NULL
        );
        """

    /// v4 (этап 6): ресурсы мака. Сводки по приложениям за пятиминутки
    /// и мака по минутам живут 8 дней (нормы — за 7), тревоги — 60 дней.
    private static let v4Resources = """
        CREATE TABLE app_usage (
            bucket_start REAL NOT NULL,      -- начало пятиминутки, unix time
            app_key TEXT NOT NULL,           -- bundle id или process:<имя>
            app_name TEXT NOT NULL,
            cpu_avg REAL NOT NULL,           -- % одного ядра
            cpu_max REAL NOT NULL,
            memory_avg REAL NOT NULL,        -- байты (phys_footprint)
            memory_max REAL NOT NULL,
            power_avg REAL NOT NULL,         -- ватты
            samples INTEGER NOT NULL,
            PRIMARY KEY (app_key, bucket_start)
        );
        CREATE INDEX app_usage_bucket ON app_usage(bucket_start);
        CREATE TABLE system_usage (
            minute_start REAL PRIMARY KEY,
            cpu REAL NOT NULL,               -- 0–100 всего процессора
            memory_used REAL,                -- байты
            memory_pressure INTEGER NOT NULL,-- 0 хватает, 1 впритык, 2 не хватает
            battery_level REAL,              -- NULL — батареи нет
            on_battery INTEGER NOT NULL,
            drain_rate REAL,                 -- % в час, только на батарее
            temperature REAL,                -- °C, NULL — датчики недоступны
            thermal_state INTEGER NOT NULL   -- 0 норма … 3 критично
        );
        CREATE TABLE resource_alerts (
            id INTEGER PRIMARY KEY,
            kind TEXT NOT NULL,              -- cpu | memory | battery | pressure | thermal
            app_key TEXT,                    -- NULL — про мак целиком
            app_name TEXT,
            value REAL NOT NULL,
            usual REAL,                      -- медиана за неделю, NULL — нормы ещё нет
            started_at REAL NOT NULL,
            created_at REAL NOT NULL,
            title TEXT NOT NULL,
            detail TEXT,
            status TEXT NOT NULL DEFAULT 'active',  -- active | later | normal | resolved
            status_changed_at REAL
        );
        CREATE INDEX resource_alerts_created ON resource_alerts(created_at);
        CREATE TABLE resource_overrides (     -- «это нормально»: ниже этого уровня не тревожим
            kind TEXT NOT NULL,
            app_key TEXT NOT NULL,           -- '' — мак целиком
            level REAL NOT NULL,
            created_at REAL NOT NULL,
            PRIMARY KEY (kind, app_key)
        );
        """

    /// v3 (этап 4): разборы дня и советы. Не чистятся через 30 дней, как лог:
    /// по ним Радарчик помнит, какие советы ты отклонил.
    private static let v3Reviews = """
        CREATE TABLE daily_reviews (
            id INTEGER PRIMARY KEY,
            period_start REAL NOT NULL,
            period_end REAL NOT NULL,
            created_at REAL NOT NULL,
            model TEXT NOT NULL,
            prompt TEXT NOT NULL,            -- ровно то, что ушло в Claude
            input_tokens INTEGER NOT NULL,
            output_tokens INTEGER NOT NULL,
            cost_usd REAL NOT NULL
        );
        CREATE TABLE tips (
            id INTEGER PRIMARY KEY,
            review_id INTEGER NOT NULL REFERENCES daily_reviews(id) ON DELETE CASCADE,
            title TEXT NOT NULL,
            observation TEXT NOT NULL,
            suggestion TEXT NOT NULL,
            effort TEXT NOT NULL,            -- низкий | средний | высокий
            time_saved_per_week_min INTEGER NOT NULL,
            tool_hint TEXT,
            status TEXT NOT NULL DEFAULT 'new',  -- new | planned | done | dismissed
            created_at REAL NOT NULL,
            status_changed_at REAL
        );
        CREATE INDEX tips_review ON tips(review_id);
        CREATE INDEX tips_created ON tips(created_at);
        """

    /// v1 (этапы 1–2): проекты, регулярные траты с историей цен, разовые траты, доходы.
    private static let v1Money = """
        CREATE TABLE projects (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            color_hex TEXT NOT NULL,
            currency TEXT NOT NULL,          -- RUB | USD | EUR
            created_at REAL NOT NULL,        -- unix time
            is_archived INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE recurring_costs (
            id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
            name TEXT NOT NULL,
            url TEXT,
            period TEXT NOT NULL,            -- monthly | yearly
            start_month TEXT NOT NULL,       -- 2026-10
            end_month TEXT,                  -- последний оплачиваемый месяц, NULL — активна
            created_at REAL NOT NULL
        );
        CREATE TABLE recurring_cost_prices (
            cost_id TEXT NOT NULL REFERENCES recurring_costs(id) ON DELETE CASCADE,
            effective_from TEXT NOT NULL,    -- цена действует с этого месяца
            amount INTEGER NOT NULL,         -- копейки/центы
            PRIMARY KEY (cost_id, effective_from)
        );
        CREATE TABLE one_off_costs (
            id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
            name TEXT NOT NULL,
            url TEXT,
            amount INTEGER NOT NULL,
            date TEXT NOT NULL,              -- 2026-10-18
            created_at REAL NOT NULL
        );
        CREATE TABLE incomes (
            id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
            name TEXT NOT NULL,
            amount INTEGER NOT NULL,
            date TEXT NOT NULL,
            created_at REAL NOT NULL
        );
        CREATE INDEX recurring_costs_project ON recurring_costs(project_id);
        CREATE INDEX one_off_costs_project ON one_off_costs(project_id);
        CREATE INDEX incomes_project ON incomes(project_id);
        """

    /// v2 (этап 3): лог наблюдения. Хранится 30 дней. Секретов здесь нет:
    /// команды вычищены до записи, URL без query и id, приватные окна без заголовка и адреса.
    private static let v2Activity = """
        CREATE TABLE activity_sessions (
            id INTEGER PRIMARY KEY,
            bundle_id TEXT NOT NULL,
            app_name TEXT NOT NULL,
            window_title TEXT,
            url TEXT,                        -- github.com/acme/app/pull/:id
            is_private INTEGER NOT NULL DEFAULT 0,
            started_at REAL NOT NULL,
            ended_at REAL NOT NULL
        );
        CREATE INDEX activity_sessions_started ON activity_sessions(started_at);
        CREATE TABLE app_events (
            id INTEGER PRIMARY KEY,
            bundle_id TEXT NOT NULL,
            app_name TEXT NOT NULL,
            kind TEXT NOT NULL,              -- launched | terminated | running
            at REAL NOT NULL
        );
        CREATE INDEX app_events_at ON app_events(at);
        CREATE TABLE paste_events (
            id INTEGER PRIMARY KEY,
            from_bundle_id TEXT,
            to_bundle_id TEXT,               -- оценка: куда перешёл в течение минуты
            at REAL NOT NULL
        );
        CREATE INDEX paste_events_at ON paste_events(at);
        CREATE TABLE call_sessions (
            id INTEGER PRIMARY KEY,
            bundle_id TEXT,
            service TEXT,                    -- Zoom, meet.google.com…
            uses_camera INTEGER NOT NULL DEFAULT 0,
            started_at REAL NOT NULL,
            ended_at REAL
        );
        CREATE INDEX call_sessions_started ON call_sessions(started_at);
        CREATE TABLE shell_commands (
            id INTEGER PRIMARY KEY,
            command TEXT NOT NULL,           -- уже без секретов
            template TEXT NOT NULL,          -- без значений: для поиска повторов
            cwd TEXT,
            started_at REAL NOT NULL,
            duration_ms INTEGER NOT NULL,
            exit_code INTEGER NOT NULL
        );
        CREATE INDEX shell_commands_started ON shell_commands(started_at);
        """
}
