"""Durable SQLite persistence with per-channel roulette isolation."""
from __future__ import annotations

import json
import sqlite3
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterator

SCHEMA_VERSION = 4


class NixoStore:
    def __init__(self, path: str | Path):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.migrate()

    def connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(str(self.path), timeout=10.0)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA foreign_keys=ON")
        conn.execute("PRAGMA busy_timeout=10000")
        return conn

    @contextmanager
    def transaction(self) -> Iterator[sqlite3.Connection]:
        conn = self.connect()
        try:
            conn.execute("BEGIN IMMEDIATE")
            yield conn
            conn.commit()
        except Exception:
            conn.rollback()
            raise
        finally:
            conn.close()

    def migrate(self) -> None:
        conn = self.connect()
        try:
            conn.execute("PRAGMA journal_mode=WAL")
            conn.execute("BEGIN IMMEDIATE")
            conn.execute("""CREATE TABLE IF NOT EXISTS schema_migrations (
                version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
            )""")
            current = conn.execute(
                "SELECT COALESCE(MAX(version), 0) FROM schema_migrations"
            ).fetchone()[0]
            if current < 1:
                statements = [
                    """CREATE TABLE telegram_accounts (
                        account_id TEXT PRIMARY KEY, label TEXT NOT NULL,
                        enabled INTEGER NOT NULL DEFAULT 1 CHECK(enabled IN (0,1)),
                        roulette_enabled INTEGER NOT NULL DEFAULT 1 CHECK(roulette_enabled IN (0,1)),
                        roulette_model TEXT NOT NULL DEFAULT 'volume',
                        roulette_config_json TEXT NOT NULL DEFAULT '{}',
                        created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
                        updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                    )""",
                    """CREATE TABLE roulette_states (
                        account_id TEXT PRIMARY KEY REFERENCES telegram_accounts(account_id) ON DELETE CASCADE,
                        step INTEGER NOT NULL DEFAULT 1 CHECK(step >= 1),
                        activated INTEGER NOT NULL DEFAULT 0 CHECK(activated IN (0,1)),
                        baseline_equity REAL NOT NULL DEFAULT 0,
                        completed_batches INTEGER NOT NULL DEFAULT 0,
                        last_action TEXT, updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                    )""",
                    """CREATE TABLE signals (
                        signal_id INTEGER PRIMARY KEY AUTOINCREMENT,
                        account_id TEXT NOT NULL REFERENCES telegram_accounts(account_id),
                        source_chat_id INTEGER NOT NULL, source_message_id INTEGER NOT NULL,
                        edit_version INTEGER NOT NULL DEFAULT 0, event_type TEXT NOT NULL,
                        received_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, telegram_date_utc TEXT,
                        validity_seconds INTEGER NOT NULL DEFAULT 180, raw_text TEXT,
                        payload_json TEXT NOT NULL DEFAULT '{}', status TEXT NOT NULL DEFAULT 'received',
                        UNIQUE(account_id, source_chat_id, source_message_id, edit_version)
                    )""",
                    "CREATE INDEX idx_signals_status ON signals(status, signal_id)",
                    """CREATE TABLE execution_intents (
                        intent_id INTEGER PRIMARY KEY AUTOINCREMENT,
                        account_id TEXT NOT NULL REFERENCES telegram_accounts(account_id),
                        signal_id INTEGER REFERENCES signals(signal_id),
                        client_order_id TEXT NOT NULL UNIQUE, state TEXT NOT NULL,
                        plan_json TEXT NOT NULL, response_json TEXT,
                        created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
                        updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                    )""",
                    "CREATE INDEX idx_intents_state ON execution_intents(state, intent_id)",
                ]
                for statement in statements:
                    conn.execute(statement)
                conn.execute("INSERT INTO schema_migrations(version) VALUES (1)")
                current = 1
            if current < 2:
                conn.execute("""CREATE TABLE telegram_channels (
                    chat_id INTEGER PRIMARY KEY,
                    label TEXT NOT NULL,
                    trading_profile_id TEXT NOT NULL REFERENCES telegram_accounts(account_id),
                    enabled INTEGER NOT NULL DEFAULT 1 CHECK(enabled IN (0,1)),
                    roulette_enabled INTEGER NOT NULL DEFAULT 1 CHECK(roulette_enabled IN (0,1)),
                    roulette_model TEXT NOT NULL DEFAULT 'volume',
                    roulette_config_json TEXT NOT NULL DEFAULT '{}',
                    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
                    updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                )""")
                conn.execute("""CREATE TABLE channel_roulette_states (
                    chat_id INTEGER PRIMARY KEY REFERENCES telegram_channels(chat_id) ON DELETE CASCADE,
                    step INTEGER NOT NULL DEFAULT 1 CHECK(step >= 1),
                    activated INTEGER NOT NULL DEFAULT 0 CHECK(activated IN (0,1)),
                    baseline_equity REAL NOT NULL DEFAULT 0,
                    completed_batches INTEGER NOT NULL DEFAULT 0,
                    last_action TEXT,
                    updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                )""")
                conn.execute("CREATE INDEX idx_channels_profile ON telegram_channels(trading_profile_id)")
                conn.execute("INSERT INTO schema_migrations(version) VALUES (2)")
            if current < 3:
                conn.execute("""CREATE TABLE channel_post_events (
                    event_id INTEGER PRIMARY KEY AUTOINCREMENT,
                    chat_id INTEGER NOT NULL REFERENCES telegram_channels(chat_id),
                    message_id INTEGER NOT NULL CHECK(message_id > 0),
                    edit_version INTEGER NOT NULL DEFAULT 0 CHECK(edit_version >= 0),
                    event_type TEXT NOT NULL,
                    signal_id INTEGER REFERENCES signals(signal_id),
                    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
                    UNIQUE(chat_id, message_id, edit_version)
                )""")
                conn.execute("CREATE INDEX idx_channel_events_signal ON channel_post_events(signal_id)")
                conn.execute("INSERT INTO schema_migrations(version) VALUES (3)")
            if current < 4:
                conn.execute("""CREATE TABLE signal_parse_results (
                    signal_id INTEGER PRIMARY KEY REFERENCES signals(signal_id) ON DELETE CASCADE,
                    parse_state TEXT NOT NULL,
                    parsed_json TEXT, error_code TEXT, error_message TEXT,
                    processed_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                )""")
                conn.execute("CREATE INDEX idx_signals_processing ON signals(status, signal_id)")
                conn.execute("INSERT INTO schema_migrations(version) VALUES (4)")
            conn.commit()
        except Exception:
            conn.rollback()
            raise
        finally:
            conn.close()

    @staticmethod
    def _validate_roulette_config(cfg: dict[str, Any]) -> str:
        model = str(cfg.get("model", "volume"))
        if model not in {"volume", "order", "combined", "off"}:
            raise ValueError("unsupported roulette model")
        return model

    def ensure_account(self, account_id: str, label: str,
                       roulette_config: dict[str, Any] | None = None,
                       enabled: bool = True) -> None:
        if not account_id.strip():
            raise ValueError("account_id is required")
        cfg = roulette_config or {}
        model = self._validate_roulette_config(cfg)
        with self.transaction() as db:
            db.execute("""INSERT INTO telegram_accounts
                (account_id,label,enabled,roulette_enabled,roulette_model,roulette_config_json)
                VALUES(?,?,?,?,?,?)
                ON CONFLICT(account_id) DO UPDATE SET label=excluded.label,
                  enabled=excluded.enabled, roulette_enabled=excluded.roulette_enabled,
                  roulette_model=excluded.roulette_model,
                  roulette_config_json=excluded.roulette_config_json,
                  updated_at=CURRENT_TIMESTAMP""",
                (account_id, label, int(enabled), int(cfg.get("enabled", True)),
                 model, json.dumps(cfg, separators=(",", ":"), sort_keys=True)))
            db.execute("INSERT OR IGNORE INTO roulette_states(account_id) VALUES (?)",
                       (account_id,))

    def ensure_channel(self, chat_id: int, label: str, trading_profile_id: str,
                       roulette_config: dict[str, Any] | None = None,
                       enabled: bool = True) -> None:
        """Create/update one Telegram channel; roulette state is keyed by chat_id."""
        cfg = roulette_config or {}
        model = self._validate_roulette_config(cfg)
        if not label.strip() or not trading_profile_id.strip():
            raise ValueError("channel label and trading_profile_id are required")
        with self.transaction() as db:
            profile = db.execute(
                "SELECT 1 FROM telegram_accounts WHERE account_id=?",
                (trading_profile_id,),
            ).fetchone()
            if profile is None:
                raise KeyError(f"unknown trading profile: {trading_profile_id}")
            db.execute("""INSERT INTO telegram_channels
                (chat_id,label,trading_profile_id,enabled,roulette_enabled,
                 roulette_model,roulette_config_json)
                VALUES(?,?,?,?,?,?,?)
                ON CONFLICT(chat_id) DO UPDATE SET label=excluded.label,
                  trading_profile_id=excluded.trading_profile_id,
                  enabled=excluded.enabled, roulette_enabled=excluded.roulette_enabled,
                  roulette_model=excluded.roulette_model,
                  roulette_config_json=excluded.roulette_config_json,
                  updated_at=CURRENT_TIMESTAMP""",
                (int(chat_id), label, trading_profile_id, int(enabled),
                 int(cfg.get("enabled", True)), model,
                 json.dumps(cfg, separators=(",", ":"), sort_keys=True)))
            db.execute("INSERT OR IGNORE INTO channel_roulette_states(chat_id) VALUES (?)",
                       (int(chat_id),))

    def get_channel(self, chat_id: int) -> dict[str, Any]:
        with self.connect() as db:
            row = db.execute("SELECT * FROM telegram_channels WHERE chat_id=?",
                             (int(chat_id),)).fetchone()
            if row is None:
                raise KeyError(chat_id)
            return dict(row)

    def get_channel_roulette_state(self, chat_id: int) -> dict[str, Any]:
        with self.connect() as db:
            row = db.execute("SELECT * FROM channel_roulette_states WHERE chat_id=?",
                             (int(chat_id),)).fetchone()
            if row is None:
                raise KeyError(chat_id)
            return dict(row)

    def update_channel_roulette_state(self, chat_id: int, *, step: int,
                                      activated: bool, baseline_equity: float,
                                      action: str | None) -> None:
        if step < 1 or baseline_equity < 0:
            raise ValueError("invalid roulette state")
        with self.transaction() as db:
            cur = db.execute("""UPDATE channel_roulette_states SET step=?, activated=?,
                baseline_equity=?, completed_batches=completed_batches+1,
                last_action=?, updated_at=CURRENT_TIMESTAMP WHERE chat_id=?""",
                (step, int(activated), baseline_equity, action, int(chat_id)))
            if cur.rowcount != 1:
                raise KeyError(chat_id)

    def record_channel_signal(self, *, chat_id: int, message_id: int,
                              edit_version: int, event_type: str,
                              telegram_date_utc: str | None,
                              validity_seconds: int, raw_text: str | None,
                              payload: dict[str, Any] | None = None) -> dict[str, Any] | None:
        """Route a channel post to its configured MT5 profile exactly once.

        Telegram message IDs are only unique within a channel, so deduplication
        always uses the composite (chat_id, message_id, edit_version) identity.
        """
        if int(message_id) <= 0 or int(edit_version) < 0:
            raise ValueError("message_id must be positive and edit_version non-negative")
        if not 1 <= int(validity_seconds) <= 86400:
            raise ValueError("validity_seconds must be between 1 and 86400")
        with self.transaction() as db:
            channel = db.execute(
                """SELECT trading_profile_id FROM telegram_channels
                   WHERE chat_id=? AND enabled=1""", (int(chat_id),)
            ).fetchone()
            if channel is None:
                return None
            profile_id = str(channel["trading_profile_id"])
            cur = db.execute(
                """INSERT OR IGNORE INTO channel_post_events
                   (chat_id,message_id,edit_version,event_type)
                   VALUES(?,?,?,?)""",
                (int(chat_id), int(message_id), int(edit_version), str(event_type)),
            )
            if cur.rowcount != 1:
                return None
            sig = db.execute(
                """INSERT INTO signals
                   (account_id,source_chat_id,source_message_id,edit_version,event_type,
                    telegram_date_utc,validity_seconds,raw_text,payload_json)
                   VALUES(?,?,?,?,?,?,?,?,?)""",
                (profile_id, int(chat_id), int(message_id), int(edit_version),
                 str(event_type), telegram_date_utc, int(validity_seconds), raw_text,
                 json.dumps(payload or {}, separators=(",", ":"), sort_keys=True)),
            )
            signal_id = int(sig.lastrowid)
            db.execute("UPDATE channel_post_events SET signal_id=? WHERE event_id=?",
                       (signal_id, int(cur.lastrowid)))
            return {"signal_id": signal_id, "trading_profile_id": profile_id,
                    "chat_id": int(chat_id), "message_id": int(message_id),
                    "edit_version": int(edit_version)}

    def has_channel_event(self, *, chat_id: int, message_id: int, edit_version: int) -> bool:
        """Return whether this exact channel post version is already durable."""
        with self.connect() as db:
            row = db.execute(
                """SELECT 1 FROM channel_post_events
                   WHERE chat_id=? AND message_id=? AND edit_version=?""",
                (int(chat_id), int(message_id), int(edit_version)),
            ).fetchone()
            return row is not None

    def record_signal(self, *, account_id: str, chat_id: int, message_id: int,
                      edit_version: int, event_type: str, telegram_date_utc: str | None,
                      validity_seconds: int, raw_text: str | None,
                      payload: dict[str, Any] | None = None) -> int | None:
        with self.transaction() as db:
            cur = db.execute("""INSERT OR IGNORE INTO signals
                (account_id,source_chat_id,source_message_id,edit_version,event_type,
                 telegram_date_utc,validity_seconds,raw_text,payload_json)
                VALUES(?,?,?,?,?,?,?,?,?)""",
                (account_id, chat_id, message_id, edit_version, event_type,
                 telegram_date_utc, validity_seconds, raw_text,
                 json.dumps(payload or {}, separators=(",", ":"), sort_keys=True)))
            return int(cur.lastrowid) if cur.rowcount else None

    def create_intent(self, *, account_id: str, signal_id: int | None,
                      client_order_id: str, plan: dict[str, Any],
                      state: str = "planned") -> bool:
        if state not in {"planned", "dry_run", "sent", "acknowledged",
                         "rejected", "uncertain", "manual_review"}:
            raise ValueError("invalid execution intent state")
        with self.transaction() as db:
            cur = db.execute("""INSERT OR IGNORE INTO execution_intents
                (account_id,signal_id,client_order_id,state,plan_json)
                VALUES(?,?,?,?,?)""",
                (account_id, signal_id, client_order_id, state,
                 json.dumps(plan, separators=(",", ":"), sort_keys=True)))
            return cur.rowcount == 1

    def get_roulette_state(self, account_id: str) -> dict[str, Any]:
        with self.connect() as db:
            row = db.execute("SELECT * FROM roulette_states WHERE account_id=?",
                             (account_id,)).fetchone()
            if row is None:
                raise KeyError(account_id)
            return dict(row)

    def update_roulette_state(self, account_id: str, *, step: int,
                              activated: bool, baseline_equity: float,
                              action: str | None) -> None:
        if step < 1 or baseline_equity < 0:
            raise ValueError("invalid roulette state")
        with self.transaction() as db:
            cur = db.execute("""UPDATE roulette_states SET step=?, activated=?,
                baseline_equity=?, completed_batches=completed_batches+1,
                last_action=?, updated_at=CURRENT_TIMESTAMP WHERE account_id=?""",
                (step, int(activated), baseline_equity, action, account_id))
            if cur.rowcount != 1:
                raise KeyError(account_id)
