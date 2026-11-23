import tempfile
import unittest
from pathlib import Path

from nixo_engine.db import NixoStore


class StoreTests(unittest.TestCase):
    def test_account_roulette_defaults_and_independent_state(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = NixoStore(Path(tmp) / "db.sqlite")
            store.ensure_account("A", "Account A")
            store.ensure_account("B", "Account B")
            self.assertEqual(store.get_roulette_state("A")["step"], 1)
            store.update_roulette_state("A", step=2, activated=True,
                                        baseline_equity=1000, action="win")
            self.assertEqual(store.get_roulette_state("A")["step"], 2)
            self.assertEqual(store.get_roulette_state("B")["step"], 1)

    def test_signal_and_intent_are_idempotent(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = NixoStore(Path(tmp) / "db.sqlite")
            store.ensure_account("A", "Account A")
            args = dict(account_id="A", chat_id=-1001, message_id=42,
                        edit_version=0, event_type="new", telegram_date_utc=None,
                        validity_seconds=180, raw_text="BUY XAUUSD")
            sid = store.record_signal(**args)
            self.assertIsNotNone(sid)
            self.assertIsNone(store.record_signal(**args))
            intent = dict(account_id="A", signal_id=sid, client_order_id="tg-A:-1001:42:0",
                          plan={"symbol": "XAUUSD", "side": "buy"})
            self.assertTrue(store.create_intent(**intent))
            self.assertFalse(store.create_intent(**intent))


if __name__ == "__main__":
    unittest.main()
