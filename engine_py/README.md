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
- The risk planner is wired in dry-run mode only. It sends read-only MT5
  requests (`GET_ACCOUNT`, `GET_SYMBOL_INFO`, `GET_RISK_PER_LOT`) and persists
  a `dry_run` plan; it never sends `OPEN`.
- Real accounts are rejected by the planner, and the EA keeps
  `InpAllowReal=false`.
- Real-account permission remains blocked by the EA input `InpAllowReal=false`.

## MT5 wire contract

The existing `mt5/NixoLink.mq5` is a TCP client. Python must be the TCP server
on 127.0.0.1:9123. Messages are UTF-8, one line per message, fields are
`KEY=VALUE` separated by `|`, and values percent-escape %, |, =, CR and LF.
The first message is `CMD=AUTH|TOKEN=...`; commands include OPEN, MODIFY,
CLOSE, CANCEL, CLOSE_ALL, GET_ACCOUNT, GET_POSITIONS, GET_SYMBOL_INFO and
GET_RISK_PER_LOT. The Python `NixoLinkServer` binds only to loopback and handles authentication,
heartbeats, and correlated read-only requests. The risk planner uses this
protocol to size dry-run plans; the `OPEN` command remains blocked.

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
- The server authenticates NixoLink, tracks ACCOUNT snapshots, correlates REQ_ID replies, and blocks OPEN while dry_run=true. The Listener queue consumer persists raw channel events, the strict parser validates them, and the risk planner creates non-executing dry-run intents. Actual order submission and closed-trade roulette reconciliation are not enabled.

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


## Risk planning and MT5 dry-run stage

After the Listener queue consumer and strict parser are running, start the
risk planner. It also hosts the authenticated NixoLink TCP server:

```powershell
py -3 -m nixo_engine.execution --config .\engine_config.json --engine-db .\data\nixo_engine.db
```

The config file must contain the existing `api_token`, and may contain
`host` (default `127.0.0.1`), `port` (default `9123`), and an optional
`profile_login_map` for installations with multiple MT5 terminals:

```json
{
  "api_token": "YOUR_EXISTING_LONG_RANDOM_TOKEN",
  "host": "127.0.0.1",
  "port": 9123,
  "profile_login_map": {
    "mt5-demo": 12345678
  }
}
```

The numeric login above is an example placeholder; use the login actually
reported by the connected terminal. If exactly one MT5 terminal is connected,
it can be selected automatically. With multiple terminals, an explicit
profile-to-login mapping is required; otherwise the signal is deferred.

For each parsed signal, the planner rechecks channel/profile enablement,
message version, and the channel's 3-minute default TTL. It reads the account
equity, symbol bid/ask and broker volume limits, then asks MT5
`OrderCalcProfit` for the monetary risk of one lot between entry and SL.
Risk is calculated from that channel's independent roulette state. Lots are
rounded DOWN to the broker's volume step; the planner never rounds up to meet
the minimum lot. If the safe volume is below the broker minimum, the signal
is placed in `manual_review`.

Market `NOW` signals use ask for BUY and bid for SELL. Pending orders require
one exact entry price and a valid limit/stop relationship to the live quote.
Entry zones are not converted to an arbitrary midpoint; they require manual
price selection. Real accounts, stale quotes, closed markets, unsupported
symbols, invalid SL/TP geometry, and ambiguous terminal routing are blocked
or deferred.

The planner stores a deterministic client-order ID and a dry-run intent with
the full risk calculation. Order roulette divides the channel's total risk
budget among its requested order count. It does not send `OPEN`, `MODIFY`,
`CLOSE`, or any other trading command. Roulette progression still waits for
reconciled, actual closed-trade outcomes; this stage does not fabricate wins
or losses from acknowledgements.
## MT5 trade-history recovery after reconnect

`mt5/NixoLink.mq5` replays authoritative MT5 deal history after each successful
socket authentication. The defaults are a 3-day overlap window and a 30-minute
periodic catch-up; `InpHistorySyncDays` is configurable from 1 to 30 days and
`InpHistorySyncIntervalMin=0` disables periodic catch-up (reconnect replay
remains enabled).

The EA selects recent deal activity, then loads the complete history for each
affected position. It re-emits the same `FILL` records and emits
`POSITION_CLOSED` only when MT5 history confirms that the position's full
opening volume has been closed. The close event contains the aggregate
profit + swap + commission for that position, not just the last deal's P/L.
This reuses the existing line protocol; no new Python dependency or wire
command is required.

Python's durable event key (`login:command:deal_ticket`) makes overlapping
replays idempotent, including after an Engine restart. A failed replay is
retried with a 5-second backoff; the next reconnect replays the same window.
Positions with reversal (`DEAL_ENTRY_INOUT`) or multiple distinct Nixo entry
comments are deliberately not assigned to an intent automatically and remain
for manual reconciliation. History older than the configured window with no
deal activity inside that window is outside this recovery pass.

This is a history-recovery path only. It does not enable live order submission;
`dry_run=true` and `InpAllowReal=false` remain unchanged. MetaEditor compilation
and terminal/demo verification are still required before relying on the EA
change in a live environment.