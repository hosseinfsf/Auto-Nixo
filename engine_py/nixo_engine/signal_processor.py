"""Deterministic, non-executing parser stage for the durable signal inbox."""
from __future__ import annotations

import argparse
import json
import logging
import time
from typing import Any

from .db import NixoStore
from .signal_parser import SignalParseError, parse_signal


class SignalProcessor:
    """Parse only the current original post; never create or send trade intents."""

    def __init__(self, store: NixoStore):
        self.store = store

    def process_one(self) -> dict[str, Any] | None:
        with self.store.transaction() as db:
            row = db.execute(
                """SELECT s.*, c.enabled AS channel_enabled,
                          a.enabled AS profile_enabled
                   FROM signals s
                   LEFT JOIN telegram_channels c ON c.chat_id=s.source_chat_id
                   LEFT JOIN telegram_accounts a ON a.account_id=s.account_id
                   WHERE s.status='received'
                   ORDER BY s.signal_id LIMIT 1"""
            ).fetchone()
            if row is None:
                return None

            signal_id = int(row["signal_id"])
            latest = db.execute(
                """SELECT MAX(edit_version) FROM channel_post_events
                   WHERE chat_id=? AND message_id=?""",
                (row["source_chat_id"], row["source_message_id"]),
            ).fetchone()[0]

            reason = None
            if str(row["event_type"]).lower() != "new":
                reason = "non_new_event"
            elif latest is not None and int(latest) > int(row["edit_version"]):
                reason = "superseded_by_edit"
            elif row["channel_enabled"] != 1 or row["profile_enabled"] != 1:
                reason = "source_or_profile_disabled"

            if reason:
                db.execute("UPDATE signals SET status='blocked' WHERE signal_id=?",
                           (signal_id,))
                db.execute(
                    """INSERT INTO signal_parse_results
                       (signal_id,parse_state,error_code,error_message)
                       VALUES(?,?,?,?)""",
                    (signal_id, "blocked", reason, reason),
                )
                return {"signal_id": signal_id, "state": "blocked", "reason": reason}

            try:
                parsed = parse_signal(row["raw_text"] or "")
            except SignalParseError as exc:
                db.execute("UPDATE signals SET status='parse_rejected' WHERE signal_id=?",
                           (signal_id,))
                db.execute(
                    """INSERT INTO signal_parse_results
                       (signal_id,parse_state,error_code,error_message)
                       VALUES(?,?,?,?)""",
                    (signal_id, "rejected", exc.code, str(exc)[:500]),
                )
                return {"signal_id": signal_id, "state": "rejected", "reason": exc.code}

            db.execute("UPDATE signals SET status='parsed' WHERE signal_id=?",
                       (signal_id,))
            db.execute(
                """INSERT INTO signal_parse_results
                   (signal_id,parse_state,parsed_json)
                   VALUES(?,?,?)""",
                (signal_id, "parsed", json.dumps(
                    parsed.to_dict(), ensure_ascii=False, separators=(",", ":"), sort_keys=True
                )),
            )
            return {"signal_id": signal_id, "state": "parsed",
                    "symbol": parsed.symbol, "side": parsed.side}


def main() -> int:
    parser = argparse.ArgumentParser(description="Parse Nixo inbox events; never sends trades.")
    parser.add_argument("--engine-db", required=True)
    parser.add_argument("--poll-interval", type=float, default=0.5)
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args()
    if args.poll_interval <= 0:
        parser.error("--poll-interval must be positive")
    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s [%(levelname)s] %(message)s")
    worker = SignalProcessor(NixoStore(args.engine_db))
    logging.info("Nixo signal parser started (no execution)")
    try:
        while True:
            result = worker.process_one()
            if result is None:
                if args.once:
                    return 0
                time.sleep(args.poll_interval)
            else:
                logging.info("Signal parse result: %s", result)
                if args.once:
                    return 0
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
