"""Safe MT5 risk planner. This stage only persists dry-run plans; it never sends OPEN."""
from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import logging
import math
import time
from dataclasses import fields
from datetime import datetime, timezone
from typing import Any

from .db import NixoStore
from .mt5_protocol import Mt5Message
from .roulette import Roulette, RouletteConfig, RouletteState

log = logging.getLogger(__name__)


class ExecutionDeferred(RuntimeError):
    """A transient condition; leave the signal eligible for a later retry."""


class ExecutionReview(RuntimeError):
    """A signal needs human review and must not be sent to MT5."""


def _number(fields_map: dict[str, str], key: str, *, minimum: float | None = None) -> float:
    try:
        value = float(fields_map[key])
    except (KeyError, TypeError, ValueError) as exc:
        raise ExecutionReview(f"missing_or_invalid_{key.lower()}") from exc
    if not math.isfinite(value) or (minimum is not None and value < minimum):
        raise ExecutionReview(f"invalid_{key.lower()}")
    return value


def _volume_digits(step: float) -> int:
    text = f"{step:.10f}".rstrip("0").rstrip(".")
    return len(text.split(".", 1)[1]) if "." in text else 0


def floor_volume(value: float, step: float, maximum: float) -> float:
    if not all(math.isfinite(x) for x in (value, step, maximum)) or value <= 0 or step <= 0 or maximum <= 0:
        raise ExecutionReview("invalid_volume_constraints")
    bounded = min(value, maximum)
    units = math.floor(bounded / step + 1e-10)
    return round(units * step, _volume_digits(step))


class DryRunExecutionPlanner:
    """Build and persist channel-isolated, risk-sized MT5 dry-run intents."""

    def __init__(self, store: NixoStore, link: Any, *,
                 login_by_profile: dict[str, int] | None = None,
                 request_timeout: float = 5.0):
        if request_timeout <= 0:
            raise ValueError("request_timeout must be positive")
        self.store = store
        self.link = link
        self.login_by_profile = dict(login_by_profile or {})
        self.request_timeout = request_timeout

    def _resolve_login(self, profile_id: str) -> int:
        configured = self.login_by_profile.get(profile_id)
        if configured is not None:
            login = int(configured)
            if login not in self.link.connections:
                raise ExecutionDeferred(f"configured MT5 login {login} is not connected")
            return login
        if profile_id.isdigit():
            login = int(profile_id)
            if login in self.link.connections:
                return login
            raise ExecutionDeferred(f"configured profile login {login} is not connected")
        connected = sorted(int(x) for x in self.link.connections)
        if len(connected) == 1:
            return connected[0]
        if not connected:
            raise ExecutionDeferred("no MT5 terminal is connected")
        raise ExecutionDeferred(
            f"profile {profile_id!r} has no MT5 login mapping and multiple terminals are connected"
        )

    async def _request(self, login: int, command: str,
                       args: dict[str, Any] | None = None) -> dict[str, str]:
        try:
            response = await self.link.request(
                login, command, args or {}, timeout=self.request_timeout
            )
        except (ConnectionError, asyncio.TimeoutError, OSError) as exc:
            raise ExecutionDeferred(str(exc)) from exc
        if isinstance(response, Mt5Message):
            result = dict(response.fields)
        elif hasattr(response, "fields"):
            result = dict(response.fields)
        else:
            result = dict(response)
        if result.get("CMD") == "ERROR":
            raise ExecutionReview(
                f"mt5_{result.get('MSG', 'request_failed')}".lower()
            )
        return result

    @staticmethod
    def _client_order_id(context: dict[str, Any]) -> str:
        raw = f"{context['source_chat_id']}:{context['source_message_id']}:{context['edit_version']}"
        digest = hashlib.sha256(raw.encode("utf-8")).hexdigest()[:24]
        return "NX-TG-" + digest

    def _roulette(self, context: dict[str, Any]) -> Roulette:
        try:
            stored = json.loads(context["channel_roulette_config_json"] or "{}")
        except (TypeError, json.JSONDecodeError):
            raise ExecutionReview("invalid_channel_roulette_config")
        if not isinstance(stored, dict):
            raise ExecutionReview("invalid_channel_roulette_config")
        stored["enabled"] = bool(context["channel_roulette_enabled"]) and bool(
            stored.get("enabled", True)
        )
        stored["model"] = str(context["channel_roulette_model"])
        allowed = {item.name for item in fields(RouletteConfig)}
        cfg = RouletteConfig(**{k: v for k, v in stored.items() if k in allowed})
        state = RouletteState(
            channel_id=str(context["source_chat_id"]),
            step=int(context["roulette_step"]),
            activated=bool(context["roulette_activated"]),
            baseline_equity=float(context["roulette_baseline_equity"]),
            completed_batches=int(context["roulette_completed_batches"]),
        )
        try:
            return Roulette(cfg, state)
        except (TypeError, ValueError) as exc:
            raise ExecutionReview(f"invalid_roulette_settings:{exc}") from exc

    async def process_signal(self, signal_id: int) -> dict[str, Any]:
        context = self.store.get_signal_execution_context(signal_id)
        if context["status"] != "parsed" or context["parse_state"] != "parsed":
            return {"signal_id": signal_id, "state": "not_eligible"}
        if context["channel_enabled"] != 1 or context["profile_enabled"] != 1:
            return {"signal_id": signal_id, "state": "blocked", "reason": "source_disabled"}
        if context.get("latest_edit_version") is None or int(context["latest_edit_version"]) != int(context["edit_version"]):
            return {"signal_id": signal_id, "state": "blocked", "reason": "superseded"}

        try:
            parsed = json.loads(context["parsed_json"])
            if not isinstance(parsed, dict):
                raise ValueError("parsed result must be an object")
            login = self._resolve_login(str(context["account_id"]))
            account = await self._request(login, "GET_ACCOUNT")
            if account.get("CMD") != "ACCOUNT":
                raise ExecutionDeferred("MT5 did not return an account snapshot")
            if int(account.get("LOGIN", "0") or 0) != login:
                raise ExecutionDeferred("MT5 account snapshot login mismatch")
            trade_mode = account.get("TRADE_MODE", "").lower()
            if trade_mode == "real":
                raise ExecutionReview("real_account_not_allowed_in_dry_run_stage")
            if trade_mode not in {"demo", "contest"}:
                raise ExecutionReview("unknown_or_unsupported_account_mode")
            equity = _number(account, "EQUITY", minimum=0.0000001)

            symbol = str(parsed.get("symbol", "")).strip().upper()
            side = str(parsed.get("side", "")).lower()
            order_type = str(parsed.get("order_type", "")).lower()
            if not symbol or side not in {"buy", "sell"}:
                raise ExecutionReview("invalid_parsed_symbol_or_side")
            if order_type not in {"market", "limit", "stop"}:
                raise ExecutionReview("invalid_order_type")

            info = await self._request(login, "GET_SYMBOL_INFO", {"SYMBOL": symbol})
            if info.get("CMD") != "SYMBOL_INFO":
                raise ExecutionDeferred("MT5 did not return symbol information")
            if info.get("MARKET_OPEN", "0") != "1":
                raise ExecutionReview("market_closed")
            tick_age = _number(info, "TICK_AGE")
            if tick_age < 0 or tick_age > 180:
                raise ExecutionReview("stale_or_missing_market_quote")
            bid = _number(info, "BID", minimum=0.0000001)
            ask = _number(info, "ASK", minimum=0.0000001)
            if ask < bid:
                raise ExecutionReview("invalid_bid_ask")
            if order_type == "market":
                if parsed.get("entry_low") is not None or parsed.get("entry_high") is not None:
                    raise ExecutionReview("market_signal_must_not_contain_entry_price")
                entry = ask if side == "buy" else bid
            else:
                low = parsed.get("entry_low")
                high = parsed.get("entry_high")
                if low is None or high is None or abs(float(high) - float(low)) > 1e-10:
                    raise ExecutionReview("entry_zone_requires_manual_price_selection")
                entry = float(low)
                if order_type == "limit":
                    if side == "buy" and entry >= ask:
                        raise ExecutionReview("buy_limit_must_be_below_ask")
                    if side == "sell" and entry <= bid:
                        raise ExecutionReview("sell_limit_must_be_above_bid")
                else:
                    if side == "buy" and entry <= ask:
                        raise ExecutionReview("buy_stop_must_be_above_ask")
                    if side == "sell" and entry >= bid:
                        raise ExecutionReview("sell_stop_must_be_below_bid")

            sl = _number({"SL": parsed.get("stop_loss")}, "SL", minimum=0.0000001)
            # Exactly one engine-derived TP at a fixed 3R reward:risk ratio.
            # Provider TP levels remain in parsed_json for audit, never execution.
            if side == "buy":
                if sl >= entry:
                    raise ExecutionReview("sl_on_wrong_side")
                raw_tp = entry + 3.0 * (entry - sl)
            else:
                if sl <= entry:
                    raise ExecutionReview("sl_on_wrong_side")
                raw_tp = entry - 3.0 * (sl - entry)
            digits = int(_number(info, "DIGITS", minimum=0))
            tp = round(raw_tp, digits)
            if not math.isfinite(tp) or tp <= 0 or (side == "buy" and tp <= entry) or (side == "sell" and tp >= entry):
                raise ExecutionReview("invalid_derived_3r_take_profit")
            tps = [tp]

            risk_reply = await self._request(login, "GET_RISK_PER_LOT", {
                "SYMBOL": symbol, "SIDE": side, "ENTRY": entry, "SL": sl,
            })
            if risk_reply.get("CMD") != "OK":
                raise ExecutionDeferred("MT5 did not return risk-per-lot")
            risk_per_lot = _number(risk_reply, "RISK_PER_LOT", minimum=0.0000001)

            roulette = self._roulette(context)
            roulette.check_activation(equity)
            self.store.save_channel_roulette_snapshot(
                int(context["source_chat_id"]), step=roulette.state.step,
                activated=roulette.state.activated,
                baseline_equity=roulette.state.baseline_equity,
            )
            risk_pct = roulette.current_risk_pct()
            order_count = roulette.order_count()
            risk_budget = equity * risk_pct / 100.0
            info_limits = {
                "min": _number(info, "VOL_MIN", minimum=0.0000001),
                "max": _number(info, "VOL_MAX", minimum=0.0000001),
                "step": _number(info, "VOL_STEP", minimum=0.0000001),
            }
            if info_limits["max"] < info_limits["min"]:
                raise ExecutionReview("invalid_broker_volume_limits")
            raw_lots_each = risk_budget / order_count / risk_per_lot
            lots_each = floor_volume(raw_lots_each, info_limits["step"], info_limits["max"])
            if lots_each < info_limits["min"]:
                raise ExecutionReview("risk_budget_below_minimum_lot")
            planned_risk = lots_each * order_count * risk_per_lot
            if planned_risk > risk_budget + max(1e-8, risk_budget * 1e-9):
                raise ExecutionReview("rounded_volume_exceeds_risk_budget")

            client_id = self._client_order_id(context)
            digest = client_id.removeprefix("NX-TG-")
            orders = [{
                "client_order_id": f"{client_id}-{index + 1:02d}",
                "broker_comment": f"NX{digest[:18]}-{index + 1:02d}",
                "symbol": symbol, "side": side, "order_type": order_type,
                "lots": lots_each, "entry": entry, "sl": sl, "tps": tps,
            } for index in range(order_count)]
            margin_mode = str(account.get("MARGIN_MODE", "hedging")).lower()
            expected_positions = 1 if margin_mode == "netting" else order_count
            plan = {
                "dry_run": True, "execution_enabled": False,
                "account_id": context["account_id"], "mt5_login": login,
                "trade_mode": trade_mode, "channel_id": int(context["source_chat_id"]),
                "channel_label": context["channel_label"],
                "telegram_message_id": int(context["source_message_id"]),
                "edit_version": int(context["edit_version"]),
                "symbol": symbol, "side": side, "order_type": order_type,
                "entry": entry, "sl": sl, "tp": tp, "tps": tps,
                "risk_reward_ratio": 3.0, "take_profit_count_per_position": 1,
                "equity": equity, "risk_pct": risk_pct,
                "risk_budget": risk_budget, "risk_per_lot": risk_per_lot,
                "planned_risk": planned_risk, "roulette_step": roulette.state.step,
                "roulette_activated": roulette.state.activated,
                "roulette_model": roulette.config.model,
                "order_count": order_count, "expected_positions": expected_positions,
                "margin_mode": margin_mode, "lots_each": lots_each,
                "aggregate_lots": lots_each * order_count,
                "volume_limits": info_limits, "orders": orders,
            }
            result = self.store.create_dry_run_intent(
                signal_id=signal_id, client_order_id=client_id, plan=plan,
                now_utc=datetime.now(timezone.utc).isoformat(),
            )
            if result != "created":
                return {"signal_id": signal_id, "state": "blocked", "reason": result}
            return {"signal_id": signal_id, "state": "dry_run",
                    "client_order_id": client_id, "risk_pct": risk_pct,
                    "planned_risk": planned_risk, "order_count": order_count}
        except ExecutionDeferred as exc:
            return {"signal_id": signal_id, "state": "deferred", "reason": str(exc)}
        except ExecutionReview as exc:
            client_id = self._client_order_id(context)
            review_plan = {
                "dry_run": True, "execution_enabled": False,
                "review_required": True, "review_code": str(exc),
                "account_id": context["account_id"],
                "channel_id": int(context["source_chat_id"]),
                "telegram_message_id": int(context["source_message_id"]),
            }
            result = self.store.create_dry_run_intent(
                signal_id=signal_id, client_order_id=client_id, plan=review_plan,
                now_utc=datetime.now(timezone.utc).isoformat(), intent_state="manual_review",
            )
            return {"signal_id": signal_id, "state": "manual_review",
                    "reason": str(exc), "recorded": result == "created"}


class DryRunWorker:
    def __init__(self, planner: DryRunExecutionPlanner):
        self.planner = planner

    def next_signal_id(self) -> int | None:
        with self.planner.store.connect() as db:
            row = db.execute(
                "SELECT signal_id FROM signals WHERE status='parsed' ORDER BY signal_id LIMIT 1"
            ).fetchone()
            return int(row["signal_id"]) if row else None

    async def process_one(self) -> dict[str, Any] | None:
        signal_id = self.next_signal_id()
        if signal_id is None:
            return None
        return await self.planner.process_signal(signal_id)


async def _run(args) -> int:
    from .server import NixoLinkServer

    config = json.loads(open(args.config, encoding="utf-8").read())
    db_path = args.engine_db
    token = str(config.get("api_token", ""))
    host = str(config.get("host", "127.0.0.1"))
    port = int(config.get("port", 9123))
    store = NixoStore(db_path)

    def on_mt5_event(command: str, payload: dict[str, str]) -> None:
        if command not in {"FILL", "POSITION_CLOSED"}:
            return
        try:
            result = store.ingest_mt5_trade_event(
                login=int(payload.get("LOGIN", "0") or 0), command=command, payload=payload,
            )
            logging.info("MT5 %s reconciliation event: %s", command, result)
        except (TypeError, ValueError) as exc:
            logging.warning("Rejected malformed MT5 %s event: %s", command, exc)

    server = NixoLinkServer(host, port, token, dry_run=True, on_event=on_mt5_event)
    planner = DryRunExecutionPlanner(
        store, server, login_by_profile=config.get("profile_login_map", {}),
    )
    worker = DryRunWorker(planner)
    await server.start()
    logging.info("Nixo dry-run planner listening on %s:%s; OPEN is disabled", host, server.port)
    try:
        while True:
            result = await worker.process_one()
            if args.once:
                if result is not None:
                    logging.info("Dry-run result: %s", result)
                return 0
            if result is None or result.get("state") == "deferred":
                await asyncio.sleep(args.poll_interval)
            else:
                logging.info("Dry-run result: %s", result)
    except KeyboardInterrupt:
        return 0
    finally:
        await server.stop()


def main() -> int:
    parser = argparse.ArgumentParser(description="Nixo risk planner (dry-run only; no OPEN commands).")
    parser.add_argument("--config", required=True, help="engine JSON config")
    parser.add_argument("--engine-db", required=True)
    parser.add_argument("--poll-interval", type=float, default=0.5)
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args()
    if args.poll_interval <= 0:
        parser.error("--poll-interval must be positive")
    logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
    try:
        return asyncio.run(_run(args))
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
