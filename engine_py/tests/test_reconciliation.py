import tempfile
import unittest
from pathlib import Path

from nixo_engine.db import NixoStore


class TradeReconciliationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = NixoStore(Path(self.tmp.name) / "engine.db")
        self.store.ensure_account("demo", "Demo")
        for chat, label in [(-10011, "Channel A"), (-10022, "Channel B")]:
            self.store.ensure_channel(chat, label, "demo",
                roulette_config={"enabled": True, "model": "volume",
                                 "base_risk_pct": 0.5, "activation_trigger_pct": 0})
        with self.store.transaction() as db:
            db.execute("UPDATE channel_roulette_states SET step=2,activated=1,baseline_equity=10000")
        item = self.store.record_channel_signal(
            chat_id=-10011, message_id=99, edit_version=0, event_type="new",
            telegram_date_utc=None, validity_seconds=180, raw_text="BUY XAUUSD SL 2300")
        self.signal_id = item["signal_id"]

    def tearDown(self):
        self.tmp.cleanup()

    def add_intent(self, comments):
        plan = {"mt5_login": 123, "channel_id": -10011, "planned_risk": 100.0,
                "expected_positions": len(comments),
                "orders": [{"broker_comment": c} for c in comments]}
        self.assertTrue(self.store.create_intent(account_id="demo", signal_id=self.signal_id,
            client_order_id="NX-TG-test-batch", plan=plan, state="sent"))

    def close_event(self, ticket, position, comment, net):
        return self.store.ingest_mt5_trade_event(login=123, command="POSITION_CLOSED",
            payload={"DEAL_TICKET": str(ticket), "POSITION_ID": str(position),
                     "CLIENT_ORDER_ID": comment, "NET_PROFIT": str(net)})

    def test_batch_waits_for_all_positions_and_is_idempotent(self):
        self.add_intent(["NXABCDEF123456789012-01", "NXABCDEF123456789012-02"])
        event = {"DEAL_TICKET": "7001", "POSITION_ID": "8001", "ENTRY": "in"}
        self.assertEqual(self.store.ingest_mt5_trade_event(login=123, command="FILL",
            payload=event)["state"], "recorded")
        self.assertEqual(self.store.ingest_mt5_trade_event(login=123, command="FILL",
            payload=event)["state"], "duplicate")
        first = self.close_event(7101, 8001, "NXABCDEF123456789012-01", 20)
        self.assertEqual(first["state"], "position_closed_batch_pending")
        self.assertEqual(self.store.get_channel_roulette_state(-10011)["step"], 2)
        second = self.close_event(7102, 8002, "NXABCDEF123456789012-02", 25)
        self.assertEqual(second["state"], "batch_reconciled")
        self.assertEqual(second["net_profit"], 45.0)
        self.assertEqual(second["roulette_action"], "win")
        state = self.store.get_channel_roulette_state(-10011)
        self.assertEqual(state["step"], 3)
        self.assertEqual(state["completed_batches"], 1)
        self.assertEqual(self.close_event(7102, 8002, "NXABCDEF123456789012-02", 25)["state"],
                         "duplicate")
        self.assertEqual(self.store.get_channel_roulette_state(-10011)["step"], 3)

    def test_loss_updates_only_the_source_channel(self):
        self.add_intent(["NXLOSS1234567890123456-01"])
        result = self.close_event(7201, 8201, "NXLOSS1234567890123456-01", -30)
        self.assertEqual(result["state"], "batch_reconciled")
        self.assertEqual(result["outcome"], "loss")
        self.assertEqual(result["roulette_action"], "loss")
        self.assertEqual(self.store.get_channel_roulette_state(-10011)["step"], 1)
        self.assertEqual(self.store.get_channel_roulette_state(-10022)["step"], 2)

    def test_unmatched_event_is_still_persisted(self):
        result = self.close_event(7301, 8301, "UNKNOWN-COMMENT", 10)
        self.assertEqual(result["state"], "unmatched")
        with self.store.connect() as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM mt5_trade_events").fetchone()[0], 1)


if __name__ == "__main__":
    unittest.main()
