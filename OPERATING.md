# Operating instructions (NIXO LITE)

Local-only engine: Telegram → parser → validator → roulette → MT5.
The dashboard is a read/control surface; it never keeps the engine alive.

## 0. Prerequisites

- Dart SDK (or Flutter SDK, which bundles Dart) on PATH.
- MetaTrader 5 + MetaEditor.
- Python environment with the pinned packages in `listener/requirements.txt` (for the separate Listener).
- Windows. The BAT files use `cmd` and PowerShell.

## 1. Configure once

```sh
cd apps/engine
copy engine_config.example.json engine_config.json
```

Then edit `engine_config.json`:

| Key | Meaning |
|---|---|
| `api_token` | Bearer token for the HTTP API + dashboard. Must not be empty. |
| `mt5_port` | 9123 unless you change the EA |
| `api_port` | 9124 unless occupied |
| `validity_seconds` | Global fallback signal max age (default 180 seconds) |
| `listener_queue_db_path` | Shared Listener SQLite queue (default `../../listener/data/listener_queue.db` when launched from `apps/engine`) |
| `listener_queue_enabled` | Enable Engine queue consumer (default true) |
| `listener_queue_allow_execution` | Permit queue signals to pass the queue-specific Dry Run gate (default false) |

Set the same token for the BAT helpers:

```sh
set NIXO_TOKEN=<the same api_token>
```

Never commit `engine_config.json`, sessions, or tokens (see `.gitignore`).

## 2. Telegram Listener (separate process)

Telegram is handled by the Python/Telethon Listener using the personal Telegram
User Account, not a Bot API token. Configure `TELEGRAM_API_ID` and
`TELEGRAM_API_HASH` in `listener/.env`; the session is stored under
`listener/session/`. Keep the Listener manually controlled from its
Management Panel Start/Stop controls. The Engine never signs in to Telegram
and never auto-starts the Listener.

Add only channels the account can access to the Listener allowlist, then set
each channel's own validity window (default 180 seconds). The shared queue is
`listener/data/listener_queue.db`; when the Engine is launched by
`Start_Nixo.bat`, its relative path is
`../../listener/data/listener_queue.db`.

## 3. MT5 connection test

1. Open `mt5/NixoLink.mq5` in MetaEditor and compile (F7).
2. Attach the EA to a chart in MT5. It connects to `127.0.0.1:9123` and
   authenticates with the token from `engine_config.json`.
3. `Start_Nixo.bat` → engine listens on 9123, API on 9124.
4. `Health_Check.bat` prints `/health`, `/status`, and the listeners.
5. Dashboard → **MT5** → **Test Connection** calls `GET_ACCOUNT` through the
   link and shows equity.

If the test fails: check that the EA is running, the token matches, and
`netstat` shows 9123 listening.

## 4. Dry-run first (no real orders)

Default mode for a new input is `shadow`: signals are parsed, validated and
sized, and the plan is recorded — but nothing is sent to MT5. Use it to
confirm parsing and sizing before going live.

Dashboard → **Roulette** / profile mode:

| Mode | Behaviour |
|---|---|
| `shadow` | Record the order plan, do not send |
| `confirm` | Record, do not send (await manual approval) |
| `auto` | Send to MT5 |
| `off` | Ignore the signal |

Also keep `mt5_dry_run=1` in settings until the first live demo. Telegram queue messages have an additional fail-closed gate: `listener_queue_allow_execution` defaults to `false`, so they remain in Dry Run even if the global setting is changed. Do not enable it during initial integration testing.

## 5. Demo execution test

Use a **demo account only**:

1. Set the profile mode to `auto` for one input.
2. Post one valid signal to that channel, e.g.
   `BUY XAUUSD entry 4050 sl 4030 tp1 4080`.
3. Confirm in the dashboard **Overview** that the last signal shows `execute`
   and **Activity** shows the HTTP/audit trail.
4. Confirm in MT5 that the position exists with the expected lots.

Then run the automated demo suite (no real orders):

```sh
cd apps/engine && dart test test/demo_integration_test.dart
```

## 5.1 Telegram Listener queue

The Python Listener remains a separate, manually started process. Start it from
the Management Panel only when you are ready to read the allowlisted channels.
The Engine does not start a Telegram session; from its working directory
`apps/engine`, it polls `../../listener/data/listener_queue.db` and routes
queued text/captions into Pipeline.

Each queued message carries its original Telegram timestamp and the channel's
configured validity window. The Engine checks expiry again immediately before
signal validation. Queue claims use a time-limited lease and retry metadata so
a stopped Engine can recover unacknowledged rows after restart. A message is
marked processed only after Pipeline returns a terminal decision.

Queue execution is additionally protected by a durable execution-intent
journal and the EA's persistent client-order-id reservation. If the MT5 response
is uncertain, the same order ID is retried; an unresolved EA reservation is
parked for manual reconciliation rather than opened a second time. This is
duplicate protection, not a mathematical exactly-once guarantee. An unresolved
intent that expires or loses its execution permissions is moved to
`manual_review`. The EA stores client-order reservations in terminal Global
Variables; attach only one NixoLink instance to each MT5 terminal. For a
`client_order_id_pending` or `manual_review` result, inspect open positions
and order history before taking any recovery action. Do not clear a reservation
until the broker-side result (including any partial TP legs) is reconciled.

Queue execution requires `listener_queue_allow_execution=true`, global
`mt5_dry_run=0`, and a source profile in `auto`. Keep the queue option
`false` during integration and validation. No trading permission is enabled
by this change.

## 6. Stop / restart

```sh
Stop_Nixo.bat     # stops the engine; state stays in data/nixo.db
Start_Nixo.bat    # starts again
```

On restart the engine:

- restores per-source roulette state from SQLite,
- reconciles open MT5 positions,
- logs signals that never got a decision,
- never re-executes a signal that already has a decision.

## 7. Health

```sh
Health_Check.bat
```

Expect `health: 200` and a JSON `status` body. Closing the browser does not
stop the engine.

## 8. Tests

```sh
cd packages/core && dart pub get && dart analyze && dart test
cd ../../apps/engine && dart pub get && dart analyze && dart test
```

## 9. Security

- The API binds `127.0.0.1` only; the MT5 link refuses non-local addresses.
- `/health` and static dashboard files are public; every data endpoint needs
  `Authorization: Bearer <api_token>`.
- Never commit tokens, `engine_config.json`, `*.session`, or `*.db`.
