# Operating instructions (NIXO LITE)

Local-only engine: Telegram → parser → validator → roulette → MT5.
The dashboard is a read/control surface; it never keeps the engine alive.

## 0. Prerequisites

- Dart SDK (or Flutter SDK, which bundles Dart) on PATH.
- MetaTrader 5 + MetaEditor.
- `tdjson.dll` (TDLib) next to the engine exe.
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
| `telegram_api_id` / `telegram_api_hash` | From https://my.telegram.org → API development tools |
| `mt5_port` | 9123 unless you change the EA |
| `api_port` | 9124 unless occupied |
| `validity_seconds` | Global fallback signal max age (default 180 seconds) |
| `listener_queue_db_path` | Shared Listener SQLite queue (default `listener/data/listener_queue.db`) |
| `listener_queue_enabled` | Enable Engine queue consumer (default true) |
| `listener_queue_allow_execution` | Permit queue signals to pass the queue-specific Dry Run gate (default false) |

Set the same token for the BAT helpers:

```sh
set NIXO_TOKEN=<the same api_token>
```

Never commit `engine_config.json`, sessions, or tokens (see `.gitignore`).

## 2. Telegram authentication

The first start with `telegram_api_id` set will prompt for the phone number
and the login code in the engine window. The session is stored under
`data/telegram/` and reused on later starts.

Add channels from the dashboard (**Telegram** tab) with the channel
`@username`, numeric id, or invite link, then enable them.

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
The Engine does not start a Telegram session; it polls the shared
`listener/data/listener_queue.db` and routes queued text/captions into Pipeline.

Each queued message carries its original Telegram timestamp and the channel's
configured validity window. The Engine checks expiry again immediately before
signal validation. Queue claims use a time-limited lease and retry metadata so
a stopped Engine can recover unacknowledged rows after restart. A message is
marked processed only after Pipeline returns a terminal decision.

Queue execution is doubly gated: `listener_queue_allow_execution` must be
explicitly set to `true`, and the existing MT5 Dry Run and per-input mode
controls still apply. Keep it `false` during validation. This integration
does not start Listener automatically and does not perform Telegram login.

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
