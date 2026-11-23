import json
import tempfile
import unittest
from pathlib import Path

from nixo_engine.db import NixoStore
from nixo_engine.signal_processor import SignalProcessor


class SignalProcessorTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = NixoStore(Path(self.tmp.name) / "engine.db")
        self.store.ensure_account("mt5-demo", "MT5 Demo")
        self.store.ensure_channel(-100123, "Gold Signals", "mt5-demo")
        self.worker = SignalProcessor(self.store)

    def tearDown(self):
        self.tmp.cleanup()

    def _record(self, *, message=10, version=0, event="new", raw=None):
        return self.store.record_channel_signal(
            chat_id=-100123, message_id=message, edit_version=version,
            event_type=event, telegram_date_utc=None, validity_seconds=180,
            raw_text=raw or "BUY GOLD ENTRY 2350 SL 2340 TP1 2360",
        )

    def _parse_row(self, signal_id):
        with self.store.connect() as db:
            row = db.execute(
                "SELECT * FROM signal_parse_results WHERE signal_id=?", (signal_id,)
            ).fetchone()
            return dict(row) if row else None

    def test_valid_new_signal_is_parsed_without_execution_intent(self):
        item = self._record()
        result = self.worker.process_one()
        self.assertEqual(result["state"], "parsed")
        parsed = json.loads(self._parse_row(item["signal_id"])["parsed_json"])
        self.assertEqual(parsed["symbol"], "XAUUSD")
        with self.store.connect() as db:
            count = db.execute("SELECT COUNT(*) FROM execution_intents").fetchone()[0]
        self.assertEqual(count, 0)

    def test_malformed_signal_is_rejected_and_audited(self):
        item = self._record(raw="BUY GOLD maybe soon")
        result = self.worker.process_one()
        self.assertEqual(result["state"], "rejected")
        self.assertEqual(self._parse_row(item["signal_id"])["parse_state"], "rejected")

    def test_edit_and_delete_events_never_become_trade_signals(self):
        self._record(message=11, event="edit")
        self._record(message=12, event="delete", raw=None)
        first = self.worker.process_one()
        second = self.worker.process_one()
        self.assertEqual(first["reason"], "non_new_event")
        self.assertEqual(second["reason"], "non_new_event")

    def test_original_message_superseded_by_edit_is_blocked(self):
        original = self._record(message=13, version=0)
        self._record(message=13, version=1, event="edit",
                     raw="BUY GOLD ENTRY 2351 SL 2340 TP1 2365")
        result = self.worker.process_one()
        self.assertEqual(result["signal_id"], original["signal_id"])
        self.assertEqual(result["reason"], "superseded_by_edit")

    def test_disabled_channel_is_revalidated_at_parse_time(self):
        item = self._record(message=14)
        with self.store.transaction() as db:
            db.execute("UPDATE telegram_channels SET enabled=0 WHERE chat_id=-100123")
        result = self.worker.process_one()
        self.assertEqual(result["reason"], "source_or_profile_disabled")
        self.assertEqual(self._parse_row(item["signal_id"])["parse_state"], "blocked")

    def test_empty_inbox_returns_none(self):
        self.assertIsNone(self.worker.process_one())


if __name__ == "__main__":
    unittest.main()
