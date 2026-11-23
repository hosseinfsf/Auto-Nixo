import contextlib
import sqlite3
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

from nixo_engine.db import NixoStore
from nixo_engine.listener_consumer import ListenerQueueConsumer


class ListenerConsumerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.queue_path = root / "listener_queue.db"
        self.store = NixoStore(root / "engine.db")
        self.store.ensure_account("mt5-demo", "MT5 Demo")
        self.store.ensure_channel(-100123, "Signals", "mt5-demo")
        self._create_queue()
        self.consumer = ListenerQueueConsumer(
            self.queue_path, self.store, worker_id="test-worker"
        )

    def tearDown(self):
        self.tmp.cleanup()

    def _create_queue(self):
        db = sqlite3.connect(self.queue_path)
        try:
            db.execute("""CREATE TABLE listener_queue (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                chat_id INTEGER NOT NULL,
                message_id INTEGER NOT NULL,
                edit_version INTEGER NOT NULL DEFAULT 0,
                date_utc TEXT NOT NULL,
                sender_id INTEGER,
                text TEXT,
                caption TEXT,
                media_path TEXT,
                media_hash TEXT,
                content_hash TEXT,
                update_type TEXT NOT NULL,
                ingested_at TEXT NOT NULL,
                state TEXT NOT NULL DEFAULT 'pending',
                error TEXT,
                validity_seconds INTEGER NOT NULL DEFAULT 180,
                lease_owner TEXT,
                lease_until_utc TEXT,
                attempts INTEGER NOT NULL DEFAULT 0,
                next_attempt_utc TEXT,
                processed_at TEXT,
                UNIQUE(chat_id, message_id, edit_version)
            )""")
            db.commit()
        finally:
            db.close()

    def _enqueue(self, *, message_id=55, edit_version=0, update_type="new",
                 date=None, validity=180, chat_id=-100123, text="BUY XAUUSD"):
        stamp = date or (datetime.now(timezone.utc) - timedelta(seconds=5))
        db = sqlite3.connect(self.queue_path)
        try:
            cur = db.execute(
                """INSERT INTO listener_queue
                   (chat_id,message_id,edit_version,date_utc,text,update_type,
                    ingested_at,validity_seconds)
                   VALUES(?,?,?,?,?,?,?,?)""",
                (chat_id, message_id, edit_version, stamp.isoformat(), text,
                 update_type, datetime.now(timezone.utc).isoformat(), validity),
            )
            db.commit()
            return cur.lastrowid
        finally:
            db.close()

    def _queue_row(self, queue_id):
        db = sqlite3.connect(self.queue_path)
        try:
            db.row_factory = sqlite3.Row
            return dict(db.execute(
                "SELECT * FROM listener_queue WHERE id=?", (queue_id,)
            ).fetchone())
        finally:
            db.close()

    def test_new_message_is_durably_routed_then_acknowledged(self):
        qid = self._enqueue()
        result = self.consumer.process_one()
        self.assertEqual(result["state"], "processed")
        self.assertEqual(result["trading_profile_id"], "mt5-demo")
        self.assertEqual(self._queue_row(qid)["state"], "processed")
        self.assertEqual(self._queue_row(qid)["attempts"], 1)
        self.assertTrue(self.store.has_channel_event(
            chat_id=-100123, message_id=55, edit_version=0
        ))

    def test_duplicate_after_engine_commit_is_acknowledged_safely(self):
        self.store.record_channel_signal(
            chat_id=-100123, message_id=56, edit_version=0,
            event_type="new", telegram_date_utc=None,
            validity_seconds=180, raw_text="BUY XAUUSD",
        )
        qid = self._enqueue(message_id=56)
        result = self.consumer.process_one()
        self.assertEqual(result["state"], "duplicate")
        self.assertEqual(self._queue_row(qid)["state"], "processed")

    def test_expired_message_never_enters_engine(self):
        old = datetime.now(timezone.utc) - timedelta(seconds=300)
        qid = self._enqueue(message_id=57, date=old, validity=180)
        result = self.consumer.process_one()
        self.assertEqual(result["state"], "expired")
        self.assertEqual(self._queue_row(qid)["state"], "expired")
        self.assertFalse(self.store.has_channel_event(
            chat_id=-100123, message_id=57, edit_version=0
        ))

    def test_disabled_or_unknown_channel_is_ignored(self):
        qid = self._enqueue(message_id=58, chat_id=-100999)
        result = self.consumer.process_one()
        self.assertEqual(result["state"], "ignored")
        self.assertEqual(self._queue_row(qid)["state"], "ignored")

    def test_edit_and_delete_are_inbox_events_not_execution_intents(self):
        self._enqueue(message_id=59, update_type="edit", edit_version=1,
                      text="BUY XAUUSD SL 4000")
        self._enqueue(message_id=60, update_type="delete", text=None)
        first = self.consumer.process_one()
        second = self.consumer.process_one()
        self.assertEqual(first["state"], "processed")
        self.assertEqual(second["state"], "processed")
        with self.store.connect() as db:
            events = db.execute(
                "SELECT event_type FROM signals ORDER BY signal_id"
            ).fetchall()
            intents = db.execute("SELECT COUNT(*) FROM execution_intents").fetchone()[0]
        self.assertEqual([row[0] for row in events], ["edit", "delete"])
        self.assertEqual(intents, 0)

    def test_failed_engine_write_is_retried_without_acknowledging(self):
        qid = self._enqueue(message_id=61)
        original = self.store.record_channel_signal

        def fail_once(**kwargs):
            self.store.record_channel_signal = original
            raise sqlite3.OperationalError("temporary database lock")

        self.store.record_channel_signal = fail_once
        result = self.consumer.process_one()
        self.assertEqual(result["state"], "retry")
        row = self._queue_row(qid)
        self.assertEqual(row["state"], "pending")
        self.assertIsNotNone(row["next_attempt_utc"])
        self.assertIsNone(row["processed_at"])

        later = datetime.now(timezone.utc) + timedelta(seconds=10)
        retried = self.consumer.process_one(now=later)
        self.assertEqual(retried["state"], "processed")
        self.assertEqual(self._queue_row(qid)["state"], "processed")


if __name__ == "__main__":
    unittest.main()
