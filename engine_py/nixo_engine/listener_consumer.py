"""Retry-safe consumer for the Telegram Listener SQLite queue.

This module only persists raw Telegram events in the Engine inbox. It does not
parse signals, create execution intents, or send commands to MetaTrader.
"""
from __future__ import annotations

import json
import sqlite3
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

from .db import NixoStore


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _parse_utc(value: str) -> datetime:
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


class ListenerQueueConsumer:
    """Move leased Listener rows into NixoStore without executing trades.

    The Listener queue and Engine store intentionally remain separate SQLite
    databases. A durable Engine insert always happens before the queue row is
    acknowledged. If the process crashes between those operations, the next
    attempt recognizes the already-stored composite event key and acknowledges
    it without inserting a duplicate.
    """

    def __init__(
        self,
        queue_db_path: str | Path,
        store: NixoStore,
        *,
        worker_id: str | None = None,
        lease_seconds: int = 30,
        max_attempts: int = 8,
    ):
        if lease_seconds < 1 or max_attempts < 1:
            raise ValueError("lease_seconds and max_attempts must be positive")
        self.queue_db_path = Path(queue_db_path)
        self.queue_db_path.parent.mkdir(parents=True, exist_ok=True)
        self.store = store
        self.worker_id = worker_id or uuid.uuid4().hex
        self.lease_seconds = int(lease_seconds)
        self.max_attempts = int(max_attempts)

    def _connect_queue(self) -> sqlite3.Connection:
        conn = sqlite3.connect(str(self.queue_db_path), timeout=10.0)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA busy_timeout=10000")
        return conn

    def _claim_one(self, now: datetime) -> dict[str, Any] | None:
        stamp = now.isoformat()
        lease_until = (now + timedelta(seconds=self.lease_seconds)).isoformat()
        with self._connect_queue() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute(
                """SELECT * FROM listener_queue
                   WHERE (state='pending'
                          OR (state='processing' AND
                              (lease_until_utc IS NULL OR lease_until_utc<=?)))
                     AND (next_attempt_utc IS NULL OR next_attempt_utc<=?)
                   ORDER BY id LIMIT 1""",
                (stamp, stamp),
            ).fetchone()
            if row is None:
                db.commit()
                return None
            cur = db.execute(
                """UPDATE listener_queue
                   SET state='processing', lease_owner=?, lease_until_utc=?,
                       attempts=COALESCE(attempts,0)+1
                   WHERE id=? AND
                     (state='pending' OR (state='processing' AND
                       (lease_until_utc IS NULL OR lease_until_utc<=?)))""",
                (self.worker_id, lease_until, row["id"], stamp),
            )
            if cur.rowcount != 1:
                db.rollback()
                return None
            claimed = dict(row)
            claimed["attempts"] = int(row["attempts"] or 0) + 1
            db.commit()
            return claimed

    def _finish(self, row_id: int, state: str, *, error: str | None = None) -> None:
        now = _utc_now().isoformat()
        with self._connect_queue() as db:
            db.execute(
                """UPDATE listener_queue
                   SET state=?, error=?, processed_at=?,
                       lease_owner=NULL, lease_until_utc=NULL,
                       next_attempt_utc=NULL
                   WHERE id=? AND state='processing' AND lease_owner=?""",
                (state, error, now, row_id, self.worker_id),
            )

    def _retry(self, row: dict[str, Any], exc: Exception, now: datetime) -> None:
        attempts = int(row["attempts"])
        if attempts >= self.max_attempts:
            self._finish(row["id"], "failed", error=str(exc)[:1000])
            return
        delay = min(300, 2 ** min(attempts, 8))
        next_try = (now + timedelta(seconds=delay)).isoformat()
        with self._connect_queue() as db:
            db.execute(
                """UPDATE listener_queue
                   SET state='pending', error=?, next_attempt_utc=?,
                       lease_owner=NULL, lease_until_utc=NULL
                   WHERE id=? AND state='processing' AND lease_owner=?""",
                (str(exc)[:1000], next_try, row["id"], self.worker_id),
            )

    def process_one(self, *, now: datetime | None = None) -> dict[str, Any] | None:
        """Process at most one row; returns a compact outcome or None."""
        current = (now or _utc_now()).astimezone(timezone.utc)
        row = self._claim_one(current)
        if row is None:
            return None

        try:
            event_type = str(row["update_type"] or "").lower()
            if event_type not in {"new", "edit", "delete"}:
                self._finish(row["id"], "ignored", error="unsupported_update_type")
                return {"queue_id": row["id"], "state": "ignored"}

            validity = int(row["validity_seconds"] or 180)
            if not 1 <= validity <= 86400:
                raise ValueError("queue validity_seconds outside allowed range")
            telegram_date = _parse_utc(str(row["date_utc"]))
            if current > telegram_date + timedelta(seconds=validity):
                self._finish(row["id"], "expired", error="signal_ttl_expired")
                return {"queue_id": row["id"], "state": "expired"}

            raw_text = row["text"] or row["caption"]
            payload = {
                "sender_id": row["sender_id"],
                "content_hash": row["content_hash"],
                "media_path": row["media_path"],
                "media_hash": row["media_hash"],
                "listener_queue_id": row["id"],
            }
            result = self.store.record_channel_signal(
                chat_id=int(row["chat_id"]),
                message_id=int(row["message_id"]),
                edit_version=int(row["edit_version"]),
                event_type=event_type,
                telegram_date_utc=telegram_date.isoformat(),
                validity_seconds=validity,
                raw_text=raw_text,
                payload=payload,
            )
            if result is not None:
                self._finish(row["id"], "processed")
                return {"queue_id": row["id"], "state": "processed", **result}

            # None means either an already-durable duplicate or an unconfigured/
            # disabled channel. Distinguish these so crash recovery is safe.
            if self.store.has_channel_event(
                chat_id=int(row["chat_id"]),
                message_id=int(row["message_id"]),
                edit_version=int(row["edit_version"]),
            ):
                self._finish(row["id"], "processed", error="duplicate_already_persisted")
                return {"queue_id": row["id"], "state": "duplicate"}
            self._finish(row["id"], "ignored", error="channel_not_configured_or_disabled")
            return {"queue_id": row["id"], "state": "ignored"}
        except Exception as exc:
            self._retry(row, exc, current)
            return {"queue_id": row["id"], "state": "retry", "error": str(exc)}
