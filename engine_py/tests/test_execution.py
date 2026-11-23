import asyncio
import json
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

from nixo_engine.db import NixoStore
from nixo_engine.execution import DryRunExecutionPlanner
from nixo_engine.mt5_protocol import Mt5Message, authenticated
from nixo_engine.server import NixoLinkServer
from nixo_engine.signal_processor import SignalProcessor


class FakeLink:
    def __init__(self, *, login=123, trade_mode="demo", equity=10000,
                 risk_per_lot=100, extra_logins=()):
        self.connections = {int(login): object()}
        for item in extra_logins:
            self.connections[int(item)] = object()
        self.login = int(login)
        self.trade_mode = trade_mode
        self.equity = equity
        self.risk_per_lot = risk_per_lot
        self.calls = []

    async def request(self, login, command, fields=None, timeout=5.0):
        self.calls.append((int(login), command, dict(fields or {})))
        if command == "GET_ACCOUNT":
            return Mt5Message({"CMD": "ACCOUNT", "LOGIN": str(login),
                               "EQUITY": str(self.equity), "BALANCE": str(self.equity),
                               "TRADE_MODE": self.trade_mode, "FREE_MARGIN": "9000"})
        if command == "GET_SYMBOL_INFO":
            return Mt5Message({"CMD": "SYMBOL_INFO", "SYMBOL": fields["SYMBOL"],
                               "BID": "2349.9", "ASK": "2350.1", "MARKET_OPEN": "1",
                               "TICK_AGE": "1", "VOL_MIN": "0.01", "VOL_MAX": "100",
                               "VOL_STEP": "0.01", "DIGITS": "2"})
        if command == "GET_RISK_PER_LOT":
            return Mt5Message({"CMD": "OK", "RISK_PER_LOT": str(self.risk_per_lot)})
        raise AssertionError(f"unexpected command {command}")


class ExecutionPlannerTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = NixoStore(Path(self.tmp.name) / "engine.db")
        self.store.ensure_account("mt5-demo", "Demo Profile")
        self.store.ensure_channel(-100123, "Gold Signals", "mt5-demo")
        self.link = FakeLink()
        self.planner = DryRunExecutionPlanner(self.store, self.link)
        self.parser = SignalProcessor(self.store)

    def tearDown(self):
        self.tmp.cleanup()

    def add_signal(self, *, chat=-100123, message=10, version=0,
                   event="new", text="BUY GOLD NOW SL 2340 TP1 2360",
                   validity=180, telegram_date=None):
        item = self.store.record_channel_signal(
            chat_id=chat, message_id=message, edit_version=version,
            event_type=event, telegram_date_utc=telegram_date,
            validity_seconds=validity, raw_text=text,
        )
        self.assertIsNotNone(item)
        return item["signal_id"]

    def parse(self, signal_id):
        result = self.parser.process_one()
        self.assertEqual(result["signal_id"], signal_id)
        self.assertEqual(result["state"], "parsed")

    def intent(self, signal_id):
        with self.store.connect() as db:
            row = db.execute(
                "SELECT * FROM execution_intents WHERE signal_id=?", (signal_id,)
            ).fetchone()
            return dict(row) if row else None

    async def test_creates_risk_sized_dry_run_intent_without_open_command(self):
        signal_id = self.add_signal()
        self.parse(signal_id)
        result = await self.planner.process_signal(signal_id)
        self.assertEqual(result["state"], "dry_run")
        record = self.intent(signal_id)
        self.assertEqual(record["state"], "dry_run")
        plan = json.loads(record["plan_json"])
        self.assertFalse(plan["execution_enabled"])
        self.assertEqual(plan["risk_pct"], 0.5)
        self.assertEqual(plan["risk_budget"], 50.0)
        self.assertEqual(plan["lots_each"], 0.5)
        self.assertEqual(plan["planned_risk"], 50.0)
        self.assertNotIn("OPEN", [call[1] for call in self.link.calls])

    async def test_market_entry_uses_ask_for_buy_and_bid_for_sell(self):
        buy_id = self.add_signal(message=20, text="BUY GOLD NOW SL 2340 TP1 2360")
        self.parse(buy_id)
        buy = await self.planner.process_signal(buy_id)
        self.assertEqual(buy["state"], "dry_run")
        buy_plan = json.loads(self.intent(buy_id)["plan_json"])
        self.assertEqual(buy_plan["entry"], 2350.1)
        self.assertEqual(buy_plan["tp"], 2380.4)
        self.assertEqual(buy_plan["tps"], [2380.4])
        self.assertEqual(buy_plan["risk_reward_ratio"], 3.0)
        self.assertEqual(buy_plan["take_profit_count_per_position"], 1)

        sell_id = self.add_signal(message=21, text="SELL GOLD NOW SL 2360 TP1 2340")
        self.parse(sell_id)
        sell = await self.planner.process_signal(sell_id)
        self.assertEqual(sell["state"], "dry_run")
        sell_plan = json.loads(self.intent(sell_id)["plan_json"])
        self.assertEqual(sell_plan["entry"], 2349.9)
        self.assertEqual(sell_plan["tp"], 2319.6)
        self.assertEqual(sell_plan["tps"], [2319.6])

    async def test_roulette_state_is_independent_per_channel(self):
        self.store.ensure_channel(-100222, "Forex Signals", "mt5-demo",
                                  roulette_config={"model": "volume", "enabled": True,
                                                   "base_risk_pct": 0.25,
                                                   "max_risk_pct": 5,
                                                   "activation_trigger_pct": 3,
                                                   "volume_step_factor": 2})
        with self.store.transaction() as db:
            db.execute("""UPDATE channel_roulette_states
                          SET step=2, activated=1, baseline_equity=10000
                          WHERE chat_id=-100123""")
            db.execute("""UPDATE channel_roulette_states
                          SET step=1, activated=1, baseline_equity=10000
                          WHERE chat_id=-100222""")
        a = self.add_signal(message=30)
        b = self.add_signal(chat=-100222, message=30)
        self.parse(a)
        self.parse(b)
        ra = await self.planner.process_signal(a)
        rb = await self.planner.process_signal(b)
        self.assertEqual(ra["risk_pct"], 1.0)
        self.assertEqual(rb["risk_pct"], 0.25)
        self.assertNotEqual(ra["client_order_id"], rb["client_order_id"])

    async def test_order_roulette_splits_total_risk_across_order_count(self):
        self.store.ensure_channel(-100123, "Gold Signals", "mt5-demo",
                                  roulette_config={"model": "order", "enabled": True,
                                                   "base_risk_pct": 0.5,
                                                   "activation_trigger_pct": 3,
                                                   "max_order_count": 8})
        with self.store.transaction() as db:
            db.execute("""UPDATE channel_roulette_states
                          SET step=3, activated=1, baseline_equity=10000
                          WHERE chat_id=-100123""")
        signal_id = self.add_signal(message=40)
        self.parse(signal_id)
        result = await self.planner.process_signal(signal_id)
        plan = json.loads(self.intent(signal_id)["plan_json"])
        self.assertEqual(result["order_count"], 3)
        self.assertEqual(plan["order_count"], 3)
        self.assertEqual(len(plan["orders"]), 3)
        self.assertLessEqual(plan["planned_risk"], plan["risk_budget"])

    async def test_entry_zone_requires_manual_review_not_guessed_midpoint(self):
        signal_id = self.add_signal(message=50,
            text="BUY XAUUSD ENTRY 2348-2352 SL 2340 TP1 2360")
        self.parse(signal_id)
        result = await self.planner.process_signal(signal_id)
        self.assertEqual(result["state"], "manual_review")
        self.assertEqual(result["reason"], "entry_zone_requires_manual_price_selection")
        self.assertEqual(self.intent(signal_id)["state"], "manual_review")

    async def test_real_account_is_blocked_and_audited(self):
        self.link.trade_mode = "real"
        signal_id = self.add_signal(message=60)
        self.parse(signal_id)
        result = await self.planner.process_signal(signal_id)
        self.assertEqual(result["state"], "manual_review")
        self.assertEqual(result["reason"], "real_account_not_allowed_in_dry_run_stage")
        self.assertEqual(self.intent(signal_id)["state"], "manual_review")
        self.assertNotIn("OPEN", [call[1] for call in self.link.calls])

    async def test_expired_signal_is_not_planned(self):
        old = (datetime.now(timezone.utc) - timedelta(minutes=10)).isoformat()
        signal_id = self.add_signal(message=70, telegram_date=old, validity=180)
        self.parse(signal_id)
        result = await self.planner.process_signal(signal_id)
        self.assertEqual(result["state"], "blocked")
        self.assertEqual(result["reason"], "expired")
        with self.store.connect() as db:
            status = db.execute("SELECT status FROM signals WHERE signal_id=?",
                                (signal_id,)).fetchone()["status"]
        self.assertEqual(status, "expired")
        self.assertIsNone(self.intent(signal_id))

    async def test_newer_edit_blocks_original_before_mt5_queries(self):
        signal_id = self.add_signal(message=80)
        self.parse(signal_id)
        self.store.record_channel_signal(
            chat_id=-100123, message_id=80, edit_version=1, event_type="edit",
            telegram_date_utc=None, validity_seconds=180,
            raw_text="BUY GOLD NOW SL 2340 TP1 2360",
        )
        result = await self.planner.process_signal(signal_id)
        self.assertEqual(result["state"], "blocked")
        self.assertEqual(result["reason"], "superseded")
        self.assertEqual(self.link.calls, [])
        self.assertIsNone(self.intent(signal_id))

    async def test_disabled_channel_is_rechecked_before_planning(self):
        signal_id = self.add_signal(message=90)
        self.parse(signal_id)
        with self.store.transaction() as db:
            db.execute("UPDATE telegram_channels SET enabled=0 WHERE chat_id=-100123")
        result = await self.planner.process_signal(signal_id)
        self.assertEqual(result["state"], "blocked")
        self.assertEqual(result["reason"], "source_disabled")
        self.assertEqual(self.link.calls, [])

    async def test_multiple_terminals_require_explicit_profile_mapping(self):
        self.link = FakeLink(extra_logins=(456,))
        self.planner = DryRunExecutionPlanner(self.store, self.link)
        signal_id = self.add_signal(message=100)
        self.parse(signal_id)
        result = await self.planner.process_signal(signal_id)
        self.assertEqual(result["state"], "deferred")
        self.assertIn("no MT5 login mapping", result["reason"])
        self.assertIsNone(self.intent(signal_id))

    async def test_risk_below_broker_minimum_is_not_rounded_up(self):
        self.link.risk_per_lot = 100000
        signal_id = self.add_signal(message=110)
        self.parse(signal_id)
        result = await self.planner.process_signal(signal_id)
        self.assertEqual(result["state"], "manual_review")
        self.assertEqual(result["reason"], "risk_budget_below_minimum_lot")
        self.assertEqual(self.intent(signal_id)["state"], "manual_review")

    async def test_volume_is_rounded_down_and_never_exceeds_risk_budget(self):
        self.link.risk_per_lot = 99
        signal_id = self.add_signal(message=115)
        self.parse(signal_id)
        result = await self.planner.process_signal(signal_id)
        plan = json.loads(self.intent(signal_id)["plan_json"])
        self.assertEqual(result["state"], "dry_run")
        self.assertEqual(plan["lots_each"], 0.5)
        self.assertLessEqual(plan["planned_risk"], plan["risk_budget"])

    async def test_stale_quote_is_sent_to_manual_review(self):
        self.link.request = self._stale_quote_request
        signal_id = self.add_signal(message=116)
        self.parse(signal_id)
        result = await self.planner.process_signal(signal_id)
        self.assertEqual(result["state"], "manual_review")
        self.assertEqual(result["reason"], "stale_or_missing_market_quote")

    async def _stale_quote_request(self, login, command, fields=None, timeout=5.0):
        self.link.calls.append((int(login), command, dict(fields or {})))
        if command == "GET_ACCOUNT":
            return Mt5Message({"CMD": "ACCOUNT", "LOGIN": str(login),
                               "EQUITY": "10000", "TRADE_MODE": "demo"})
        if command == "GET_SYMBOL_INFO":
            return Mt5Message({"CMD": "SYMBOL_INFO", "BID": "2349.9", "ASK": "2350.1",
                               "MARKET_OPEN": "1", "TICK_AGE": "181", "VOL_MIN": "0.01",
                               "VOL_MAX": "100", "VOL_STEP": "0.01"})
        raise AssertionError(f"unexpected command {command}")

    async def test_numeric_profile_login_is_not_replaced_by_an_unrelated_terminal(self):
        self.store.ensure_account("999", "Mapped Numeric Profile")
        self.store.ensure_channel(-100999, "Numeric Channel", "999")
        signal_id = self.add_signal(chat=-100999, message=117)
        self.parse(signal_id)
        result = await self.planner.process_signal(signal_id)
        self.assertEqual(result["state"], "deferred")
        self.assertIn("profile login 999 is not connected", result["reason"])
        self.assertEqual(self.link.calls, [])

    async def test_duplicate_processing_does_not_create_second_intent(self):
        signal_id = self.add_signal(message=120)
        self.parse(signal_id)
        first = await self.planner.process_signal(signal_id)
        second = await self.planner.process_signal(signal_id)
        self.assertEqual(first["state"], "dry_run")
        self.assertEqual(second["state"], "not_eligible")
        self.assertEqual(self.intent(signal_id)["state"], "dry_run")
        with self.store.connect() as db:
            count = db.execute("SELECT COUNT(*) FROM execution_intents WHERE signal_id=?",
                               (signal_id,)).fetchone()[0]
        self.assertEqual(count, 1)



class NixoLinkDryRunIntegrationTests(unittest.IsolatedAsyncioTestCase):
    async def test_real_tcp_protocol_runs_read_only_plan_and_never_sends_open(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = NixoStore(Path(tmp) / "engine.db")
            store.ensure_account("mt5-demo", "Demo Profile")
            store.ensure_channel(-100123, "Gold Signals", "mt5-demo")
            item = store.record_channel_signal(
                chat_id=-100123, message_id=700, edit_version=0, event_type="new",
                telegram_date_utc=None, validity_seconds=180,
                raw_text="BUY GOLD NOW SL 2340 TP1 2360",
            )
            SignalProcessor(store).process_one()
            token = "integration-test-token-123456"
            server = NixoLinkServer("127.0.0.1", 0, token, dry_run=True)
            await server.start()
            commands = []

            async def mock_ea():
                reader, writer = await asyncio.open_connection("127.0.0.1", server.port)
                writer.write(authenticated(token).encode())
                await writer.drain()
                auth_reply = Mt5Message.decode(await asyncio.wait_for(reader.readline(), 2))
                if auth_reply.command != "AUTH_OK":
                    raise AssertionError("NixoLink authentication failed")
                writer.write(Mt5Message({
                    "CMD": "ACCOUNT", "LOGIN": "123", "EQUITY": "10000",
                    "BALANCE": "10000", "TRADE_MODE": "demo",
                }).encode())
                await writer.drain()
                try:
                    for _ in range(3):
                        request = Mt5Message.decode(await asyncio.wait_for(reader.readline(), 2))
                        commands.append(request.command)
                        req_id = request.fields["REQ_ID"]
                        if request.command == "GET_ACCOUNT":
                            response = {"CMD": "ACCOUNT", "REQ_ID": req_id, "LOGIN": "123",
                                        "EQUITY": "10000", "BALANCE": "10000",
                                        "TRADE_MODE": "demo"}
                        elif request.command == "GET_SYMBOL_INFO":
                            response = {"CMD": "SYMBOL_INFO", "REQ_ID": req_id,
                                         "SYMBOL": "XAUUSD", "BID": "2349.9", "ASK": "2350.1",
                                         "MARKET_OPEN": "1", "TICK_AGE": "1",
                                         "VOL_MIN": "0.01", "VOL_MAX": "100", "VOL_STEP": "0.01"}
                        elif request.command == "GET_RISK_PER_LOT":
                            response = {"CMD": "OK", "REQ_ID": req_id, "RISK_PER_LOT": "100"}
                        else:
                            raise AssertionError(f"unexpected command: {request.command}")
                        writer.write(Mt5Message(response).encode())
                        await writer.drain()
                finally:
                    writer.close()
                    await writer.wait_closed()

            ea_task = asyncio.create_task(mock_ea())
            try:
                for _ in range(100):
                    if server.connections:
                        break
                    await asyncio.sleep(0.01)
                planner = DryRunExecutionPlanner(store, server)
                result = await planner.process_signal(item["signal_id"])
                await asyncio.wait_for(ea_task, 3)
                self.assertEqual(result["state"], "dry_run")
                self.assertEqual(commands, ["GET_ACCOUNT", "GET_SYMBOL_INFO", "GET_RISK_PER_LOT"])
                self.assertNotIn("OPEN", commands)
                self.assertTrue(server.dry_run)
            finally:
                if not ea_task.done():
                    ea_task.cancel()
                    await asyncio.gather(ea_task, return_exceptions=True)
                await server.stop()


if __name__ == "__main__":
    unittest.main()
