# Nixo Python Engine (initial foundation)

This package is the Python execution engine foundation. It is intentionally
separate from the archived Dart/Flutter application and does not modify the
Telegram Listener or the MQL5 EA.

## Safety defaults

- Telegram channel roulette configuration defaults to enabled; each channel owns an independent state.
- Roulette follows the documented legacy volume model: 0.50% base risk,
  3.0% equity-growth activation trigger, 5.0% risk cap, 50 steps, and a
  2.0x volume factor. Order roulette remains opt-in; its count starts at 1\n  and is capped by `max_order_count` (default 8). The step changes only after\n  a completed trade batch:
  win +1, loss -1, flat unchanged.
- Enabled means configured/on; the growth trigger still controls when the
  progressive volume multiplier activates.
- MT5 execution is not enabled by this foundation. The example config is
  `dry_run=true`; no live order path is wired into a queue consumer.
- Real-account permission remains blocked by the EA input `InpAllowReal=false`.

## MT5 wire contract

The existing `mt5/NixoLink.mq5` is a TCP client. Python must be the TCP server
on 127.0.0.1:9123. Messages are UTF-8, one line per message, fields are
`KEY=VALUE` separated by `|`, and values percent-escape %, |, =, CR and LF.
The first message is `CMD=AUTH|TOKEN=...`; commands include OPEN, MODIFY,
CLOSE, CANCEL, CLOSE_ALL, GET_ACCOUNT, GET_POSITIONS, GET_SYMBOL_INFO and
GET_RISK_PER_LOT. This module currently provides framing/encoding primitives
only; it does not bind a socket or submit orders.

## Database

SQLite schema migrations are additive and tracked in `schema_migrations`.
Telegram account profiles, roulette state, raw signal records, and execution
intents are account-scoped. A unique idempotency key prevents duplicate intent
creation. Listener queue rows retain their existing schema and are not altered.

## Tests

From `engine_py` run:

```powershell
py -3 -m unittest discover -s tests -v
```

The test suite uses only the Python standard library.


## Reuse audit (2026-11-23)

- The existing Listener pins Telethon 1.46.0 for Telegram User Account / MTProto; keep one session implementation rather than adding a second client stack. Pyrogram is archived and is not selected.
- The asyncio TCP server and mock-EA test approach were reviewed against the MIT-licensed https://github.com/RAo797bit/mt5-multi-terminal-manager. Its JSON wire protocol and EA are incompatible with NixoLink, so Nixo uses its own KEY=VALUE protocol implementation.
- Telegram-to-MT5 projects were audited for parser/test ideas. No source is copied from projects without a declared license or where parser behavior silently defaults missing trade direction/levels.
- The server authenticates NixoLink, tracks ACCOUNT snapshots, correlates REQ_ID replies, and blocks OPEN while dry_run=true. The separate Listener queue consumer now persists raw channel events into the Engine inbox; parsing and trade execution remain unwired.

## Telegram Listener queue handoff (raw inbox only)

The Listener and Engine use separate SQLite files. Run the consumer as a
separate Python process after configuring each Telegram `chat_id` in the
Engine database and mapping it to an existing MT5 profile:

```powershell
py -3 -m nixo_engine.listener_consumer --queue-db ..\listener\data\listener_queue.db --engine-db .\data\nixo_engine.db
```

The worker claims queue rows with a lease, checks each row's per-channel
`validity_seconds` (default 180), and persists the event using the composite
`(chat_id, message_id, edit_version)` key. It acknowledges the Listener row
only after the Engine insert is durable. A crash between the Engine commit
and queue acknowledgement is recovered as an idempotent duplicate. Temporary
database failures are retried with bounded exponential backoff.

`new`, `edit`, and `delete` are stored as distinct raw inbox event types.
This worker does not parse trade instructions, create execution intents, alter
roulette steps, contact NixoLink, or place orders. Unknown/disabled channel
mappings are marked ignored; expired messages are marked expired.


## Strict signal parsing stage (non-executing)

After the raw inbox consumer has moved events into the Engine database, run the
deterministic parser as a separate process:

```powershell
py -3 -m nixo_engine.signal_processor --engine-db .\data\nixo_engine.db
```

The parser accepts explicit direction, one recognized symbol, one stop-loss,
at least one labelled take-profit, and either an entry price/range or an
explicit NOW/MARKET instruction. Persian and Arabic digits are normalized.
Conflicting directions, multiple symbols/entry zones, missing levels, and
wrong-side SL/TP values are rejected rather than guessed.

Only the original `new` event can be parsed. Telegram edits and deletes are
recorded for audit but blocked from producing a new trade signal. If a newer
edit is already present when the original event is parsed, the original is
marked superseded. The eventual execution stage must repeat this latest-version
and source-enabled check immediately before creating/sending an intent.

Normalized parse results and rejection reasons are stored in
`signal_parse_results` (schema migration 4). This stage creates no execution
intents and sends no MT5 commands. Live execution remains disabled.
