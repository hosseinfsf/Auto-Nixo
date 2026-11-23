"""Durable SQLite persistence with per-channel roulette isolation."""
from __future__ import annotations

import json
import sqlite3
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterator

SCHEMA_VERSION = 5


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
            if current < 5:
                conn.execute("CREATE INDEX idx_intents_signal ON execution_intents(signal_id)")
                conn.execute("INSERT INTO schema_migrations(version) VALUES (5)")
                current = 5
            if current < 6:
                conn.execute("""CREATE TABLE mt5_trade_events (
                    event_key TEXT PRIMARY KEY, login INTEGER NOT NULL, command TEXT NOT NULL,
                    payload_json TEXT NOT NULL, received_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                )""")
                conn.execute("""CREATE TABLE mt5_position_closures (
                    login INTEGER NOT NULL, position_id INTEGER NOT NULL,
                    intent_id INTEGER NOT NULL REFERENCES execution_intents(intent_id),
                    net_profit REAL NOT NULL, event_key TEXT NOT NULL REFERENCES mt5_trade_events(event_key),
                    closed_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY(login, position_id)
                )""")
                conn.execute("""CREATE TABLE signal_batch_results (
                    signal_id INTEGER PRIMARY KEY REFERENCES signals(signal_id),
                    chat_id INTEGER NOT NULL REFERENCES telegram_channels(chat_id),
                    net_profit REAL NOT NULL, risk_money REAL NOT NULL, outcome TEXT NOT NULL,
                    roulette_action TEXT NOT NULL, applied_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                )""")
                conn.execute("CREATE INDEX idx_trade_events_login ON mt5_trade_events(login, received_at)")
                conn.execute("CREATE INDEX idx_position_closures_intent ON mt5_position_closures(intent_id)")
                conn.execute("INSERT INTO schema_migrations(version) VALUES (6)")
                current = 6
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

    def save_channel_roulette_snapshot(self, chat_id: int, *, step: int,
                                       activated: bool, baseline_equity: float) -> None:
        """Persist activation/baseline without counting a completed trading batch."""
        if step < 1 or baseline_equity < 0:
            raise ValueError("invalid roulette state")
        with self.transaction() as db:
            cur = db.execute("""UPDATE channel_roulette_states SET step=?, activated=?,
                baseline_equity=?, updated_at=CURRENT_TIMESTAMP WHERE chat_id=?""",
                (step, int(activated), baseline_equity, int(chat_id)))
            if cur.rowcount != 1:
                raise KeyError(chat_id)

    def get_signal_execution_context(self, signal_id: int) -> dict[str, Any]:
        with self.connect() as db:
            row = db.execute(
                """SELECT s.*, c.label AS channel_label, c.enabled AS channel_enabled,
                          c.roulette_enabled AS channel_roulette_enabled,
                          c.roulette_model AS channel_roulette_model,
                          c.roulette_config_json AS channel_roulette_config_json,
                          a.enabled AS profile_enabled,
                          p.parse_state, p.parsed_json,
                          r.step AS roulette_step, r.activated AS roulette_activated,
                          r.baseline_equity AS roulette_baseline_equity,
                          r.completed_batches AS roulette_completed_batches,
                          (SELECT MAX(e.edit_version) FROM channel_post_events e
                           WHERE e.chat_id=s.source_chat_id
                             AND e.message_id=s.source_message_id) AS latest_edit_version
                   FROM signals s
                   JOIN telegram_channels c ON c.chat_id=s.source_chat_id
                   JOIN telegram_accounts a ON a.account_id=s.account_id
                   JOIN signal_parse_results p ON p.signal_id=s.signal_id
                   JOIN channel_roulette_states r ON r.chat_id=c.chat_id
                   WHERE s.signal_id=?""", (int(signal_id),)
            ).fetchone()
            if row is None:
                raise KeyError(signal_id)
            return dict(row)

    def create_dry_run_intent(self, *, signal_id: int, client_order_id: str,
                              plan: dict[str, Any], now_utc: str,
                              intent_state: str = "dry_run") -> str:
        """Atomically revalidate source/version/TTL and persist one non-live intent."""
        from datetime import datetime, timezone

        if intent_state not in {"dry_run", "manual_review"}:
            raise ValueError("intent_state must be dry_run or manual_review")
        now = datetime.fromisoformat(now_utc.replace("Z", "+00:00"))
        if now.tzinfo is None:
            now = now.replace(tzinfo=timezone.utc)
        with self.transaction() as db:
            row = db.execute(
                """SELECT s.*, c.enabled AS channel_enabled, a.enabled AS profile_enabled,
                          p.parse_state,
                          (SELECT MAX(e.edit_version) FROM channel_post_events e
                           WHERE e.chat_id=s.source_chat_id
                             AND e.message_id=s.source_message_id) AS latest_version
                   FROM signals s
                   JOIN telegram_channels c ON c.chat_id=s.source_chat_id
                   JOIN telegram_accounts a ON a.account_id=s.account_id
                   JOIN signal_parse_results p ON p.signal_id=s.signal_id
                   WHERE s.signal_id=?""", (int(signal_id),)
            ).fetchone()
            if row is None:
                raise KeyError(signal_id)
            if row["status"] != "parsed" or row["parse_state"] != "parsed":
                return "not_eligible"
            if str(row["event_type"]).lower() != "new":
                return "not_new_event"
            if row["channel_enabled"] != 1 or row["profile_enabled"] != 1:
                return "source_disabled"
            if row["latest_version"] is None or int(row["latest_version"]) != int(row["edit_version"]):
                return "superseded"
            stamp = row["telegram_date_utc"] or row["received_at"]
            try:
                created = datetime.fromisoformat(str(stamp).replace("Z", "+00:00"))
                if created.tzinfo is None:
                    created = created.replace(tzinfo=timezone.utc)
            except ValueError:
                return "invalid_timestamp"
            age = (now - created.astimezone(timezone.utc)).total_seconds()
            if age < -60 or age > int(row["validity_seconds"]):
                db.execute("UPDATE signals SET status='expired' WHERE signal_id=?",
                           (int(signal_id),))
                return "expired"
            existing = db.execute(
                "SELECT 1 FROM execution_intents WHERE signal_id=?", (int(signal_id),)
            ).fetchone()
            if existing:
                return "duplicate"
            cur = db.execute(
                """INSERT OR IGNORE INTO execution_intents
                   (account_id,signal_id,client_order_id,state,plan_json)
                   VALUES(?,?,?,?,?)""",
                (row["account_id"], int(signal_id), client_order_id, intent_state,
                 json.dumps(plan, ensure_ascii=False, separators=(",", ":"), sort_keys=True)),
            )
            if cur.rowcount != 1:
                return "duplicate"
            status = "dry_run_planned" if intent_state == "dry_run" else "manual_review"
            db.execute("UPDATE signals SET status=? WHERE signal_id=?",
                       (status, int(signal_id)))
            return "created"

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


    def ingest_mt5_trade_event(self, *, login: int, command: str,
                               payload: dict[str, Any]) -> dict[str, Any]:
        """Persist MT5 deal events idempotently and apply roulette only at full batch close."""
        import math
        from dataclasses import fields
        from .roulette import Roulette, RouletteConfig, RouletteState

        cmd = str(command).upper()
        if cmd not in {"FILL", "POSITION_CLOSED"}:
            raise ValueError("unsupported trade event")
        deal_ticket = int(payload.get("DEAL_TICKET", 0) or 0)
        position_id = int(payload.get("POSITION_ID", 0) or 0)
        if int(login) <= 0 or deal_ticket <= 0 or position_id <= 0:
            raise ValueError("LOGIN, DEAL_TICKET and POSITION_ID are required")
        net_profit = 0.0
        if cmd == "POSITION_CLOSED":
            net_profit = float(payload.get("NET_PROFIT", "nan"))
            if not math.isfinite(net_profit):
                raise ValueError("NET_PROFIT must be finite")
        event_key = f"{int(login)}:{cmd}:{deal_ticket}"

        with self.transaction() as db:
            inserted = db.execute(
                """INSERT OR IGNORE INTO mt5_trade_events
                   (event_key,login,command,payload_json) VALUES(?,?,?,?)""",
                (event_key, int(login), cmd,
                 json.dumps(payload, ensure_ascii=False, separators=(",", ":"), sort_keys=True)),
            ).rowcount == 1
            if not inserted:
                return {"state": "duplicate", "event_key": event_key}
            if cmd == "FILL":
                return {"state": "recorded", "event_key": event_key}

            broker_comment = str(payload.get("CLIENT_ORDER_ID", "")).strip()
            if not broker_comment:
                return {"state": "unmatched", "event_key": event_key,
                        "reason": "missing_client_order_id"}
            candidates = db.execute("SELECT intent_id,plan_json FROM execution_intents ORDER BY intent_id").fetchall()
            matched = matched_plan = None
            for candidate in candidates:
                try:
                    plan = json.loads(candidate["plan_json"])
                except (TypeError, json.JSONDecodeError):
                    continue
                if int(plan.get("mt5_login", 0) or 0) != int(login):
                    continue
                comments = {str(o.get("broker_comment", "")) for o in plan.get("orders", [])
                            if isinstance(o, dict)}
                if broker_comment in comments:
                    matched, matched_plan = candidate, plan
                    break
            if matched is None:
                return {"state": "unmatched", "event_key": event_key,
                        "reason": "no_intent_matches_broker_comment"}

            inserted_close = db.execute(
                """INSERT OR IGNORE INTO mt5_position_closures
                   (login,position_id,intent_id,net_profit,event_key) VALUES(?,?,?,?,?)""",
                (int(login), position_id, int(matched["intent_id"]), net_profit, event_key),
            ).rowcount
            if not inserted_close:
                return {"state": "duplicate_position_close", "event_key": event_key}
            expected = max(1, int(matched_plan.get(
                "expected_positions", len(matched_plan.get("orders", [])) or 1)))
            closed = int(db.execute(
                "SELECT COUNT(*) FROM mt5_position_closures WHERE intent_id=?",
                (int(matched["intent_id"]),),
            ).fetchone()[0])
            if closed < expected:
                return {"state": "position_closed_batch_pending",
                        "closed_positions": closed, "expected_positions": expected}

            intent = db.execute(
                """SELECT i.signal_id,s.source_chat_id FROM execution_intents i
                   JOIN signals s ON s.signal_id=i.signal_id WHERE i.intent_id=?""",
                (int(matched["intent_id"]),),
            ).fetchone()
            if intent is None or intent["signal_id"] is None:
                return {"state": "unmatched", "event_key": event_key, "reason": "intent_has_no_signal"}
            signal_id, chat_id = int(intent["signal_id"]), int(intent["source_chat_id"])
            if db.execute("SELECT 1 FROM signal_batch_results WHERE signal_id=?", (signal_id,)).fetchone():
                return {"state": "batch_already_reconciled", "event_key": event_key}
            total_profit = float(db.execute(
                "SELECT COALESCE(SUM(net_profit),0) FROM mt5_position_closures WHERE intent_id=?",
                (int(matched["intent_id"]),),
            ).fetchone()[0])
            risk_money = float(matched_plan.get("planned_risk", matched_plan.get("risk_budget", 0)) or 0)
            if not math.isfinite(risk_money) or risk_money < 0:
                raise ValueError("stored risk budget is invalid")
            outcome = "win" if total_profit > 0 else "loss" if total_profit < 0 else "flat"
            channel = db.execute(
                """SELECT c.roulette_enabled,c.roulette_model,c.roulette_config_json,
                          r.step,r.activated,r.baseline_equity,r.completed_batches
                   FROM telegram_channels c JOIN channel_roulette_states r ON r.chat_id=c.chat_id
                   WHERE c.chat_id=?""", (chat_id,),
            ).fetchone()
            action = "not_activated"
            if channel is not None:
                cfg_data = json.loads(channel["roulette_config_json"] or "{}")
                cfg_data["enabled"] = bool(channel["roulette_enabled"]) and bool(cfg_data.get("enabled", True))
                cfg_data["model"] = str(channel["roulette_model"])
                allowed = {x.name for x in fields(RouletteConfig)}
                cfg = RouletteConfig(**{k: v for k, v in cfg_data.items() if k in allowed})
                state = RouletteState(
                    channel_id=str(chat_id), step=int(channel["step"]),
                    activated=bool(channel["activated"]),
                    baseline_equity=float(channel["baseline_equity"]),
                    completed_batches=int(channel["completed_batches"]),
                )
                action = Roulette(cfg, state).on_batch_result(total_profit, risk_money)
                if action != "not_activated":
                    db.execute(
                        """UPDATE channel_roulette_states SET step=?,completed_batches=completed_batches+1,
                           last_action=?,updated_at=CURRENT_TIMESTAMP WHERE chat_id=?""",
                        (state.step, action, chat_id),
                    )
            db.execute(
                """INSERT INTO signal_batch_results
                   (signal_id,chat_id,net_profit,risk_money,outcome,roulette_action) VALUES(?,?,?,?,?,?)""",
                (signal_id, chat_id, total_profit, risk_money, outcome, action),
            )
            db.execute("UPDATE execution_intents SET state='closed',updated_at=CURRENT_TIMESTAMP WHERE intent_id=?",
                       (int(matched["intent_id"]),))
            return {"state": "batch_reconciled", "signal_id": signal_id, "chat_id": chat_id,
                    "net_profit": total_profit, "risk_money": risk_money, "outcome": outcome,
                    "roulette_action": action, "event_key": event_key}
