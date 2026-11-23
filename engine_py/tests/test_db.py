import tempfile
import unittest
from pathlib import Path

from nixo_engine.db import NixoStore


class StoreTests(unittest.TestCase):
    def test_account_roulette_defaults_and_independent_state(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = NixoStore(Path(tmp) / "db.sqlite")
            store.ensure_account("A", "MT5 A")
            store.ensure_account("B", "MT5 B")
            self.assertEqual(store.get_roulette_state("A")["step"], 1)
            store.update_roulette_state("A", step=2, activated=True,
                                        baseline_equity=1000, action="win")
            self.assertEqual(store.get_roulette_state("A")["step"], 2)
            self.assertEqual(store.get_roulette_state("B")["step"], 1)

    def test_each_telegram_channel_has_independent_roulette_even_on_same_mt5_profile(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = NixoStore(Path(tmp) / "db.sqlite")
            store.ensure_account("mt5-demo-1", "MT5 Demo 1")
            store.ensure_channel(-100111, "Gold Signals", "mt5-demo-1")
            store.ensure_channel(-100222, "Forex Signals", "mt5-demo-1")
            self.assertEqual(store.get_channel(-100111)["trading_profile_id"], "mt5-demo-1")
            self.assertEqual(store.get_channel(-100222)["trading_profile_id"], "mt5-demo-1")
            self.assertEqual(store.get_channel_roulette_state(-100111)["step"], 1)
            store.update_channel_roulette_state(
                -100111, step=3, activated=True, baseline_equity=1000, action="win"
            )
            self.assertEqual(store.get_channel_roulette_state(-100111)["step"], 3)
            self.assertEqual(store.get_channel_roulette_state(-100222)["step"], 1)

    def test_post_identity_is_channel_plus_message_id_and_routes_to_profile(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = NixoStore(Path(tmp) / "db.sqlite")
            store.ensure_account("mt5-a", "MT5 A")
            store.ensure_account("mt5-b", "MT5 B")
            store.ensure_channel(-10011, "Channel A", "mt5-a")
            store.ensure_channel(-10022, "Channel B", "mt5-b")

            a = store.record_channel_signal(
                chat_id=-10011, message_id=125, edit_version=0,
                event_type="new", telegram_date_utc=None,
                validity_seconds=180, raw_text="BUY XAUUSD",
            )
            b = store.record_channel_signal(
                chat_id=-10022, message_id=125, edit_version=0,
                event_type="new", telegram_date_utc=None,
                validity_seconds=180, raw_text="BUY XAUUSD",
            )
            self.assertIsNotNone(a)
            self.assertIsNotNone(b)
            self.assertNotEqual(a["signal_id"], b["signal_id"])
            self.assertEqual(a["trading_profile_id"], "mt5-a")
            self.assertEqual(b["trading_profile_id"], "mt5-b")

            duplicate = store.record_channel_signal(
                chat_id=-10011, message_id=125, edit_version=0,
                event_type="new", telegram_date_utc=None,
                validity_seconds=180, raw_text="BUY XAUUSD",
            )
            self.assertIsNone(duplicate)

            edited = store.record_channel_signal(
                chat_id=-10011, message_id=125, edit_version=1,
                event_type="edit", telegram_date_utc=None,
                validity_seconds=180, raw_text="BUY XAUUSD SL 4000",
            )
            self.assertIsNotNone(edited)
            self.assertNotEqual(edited["signal_id"], a["signal_id"])

    def test_unconfigured_or_disabled_channel_is_not_routed(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = NixoStore(Path(tmp) / "db.sqlite")
            store.ensure_account("mt5-a", "MT5 A")
            store.ensure_channel(-10011, "Channel A", "mt5-a", enabled=False)
            result = store.record_channel_signal(
                chat_id=-10011, message_id=1, edit_version=0,
                event_type="new", telegram_date_utc=None,
                validity_seconds=180, raw_text="BUY XAUUSD",
            )
            self.assertIsNone(result)

    def test_channel_can_route_to_different_mt5_profiles(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = NixoStore(Path(tmp) / "db.sqlite")
            store.ensure_account("mt5-a", "MT5 A")
            store.ensure_account("mt5-b", "MT5 B")
            store.ensure_channel(-1001, "Channel A", "mt5-a")
            store.ensure_channel(-1002, "Channel B", "mt5-b")
            self.assertEqual(store.get_channel(-1001)["trading_profile_id"], "mt5-a")
            self.assertEqual(store.get_channel(-1002)["trading_profile_id"], "mt5-b")

    def test_channel_requires_existing_trading_profile(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = NixoStore(Path(tmp) / "db.sqlite")
            with self.assertRaises(KeyError):
                store.ensure_channel(-1001, "Channel A", "missing-profile")

    def test_signal_and_intent_are_idempotent(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = NixoStore(Path(tmp) / "db.sqlite")
            store.ensure_account("mt5-demo-1", "MT5 Demo 1")
            args = dict(account_id="mt5-demo-1", chat_id=-1001, message_id=42,
                        edit_version=0, event_type="new", telegram_date_utc=None,
                        validity_seconds=180, raw_text="BUY XAUUSD")
            sid = store.record_signal(**args)
            self.assertIsNotNone(sid)
            self.assertIsNone(store.record_signal(**args))
            intent = dict(account_id="mt5-demo-1", signal_id=sid,
                          client_order_id="tg:-1001:42:0",
                          plan={"symbol": "XAUUSD", "side": "buy"})
            self.assertTrue(store.create_intent(**intent))
            self.assertFalse(store.create_intent(**intent))


if __name__ == "__main__":
    unittest.main()
