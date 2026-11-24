# Operating instructions (NIXO LITE)

Local-only engine: Telegram Listener → SQLite queue → parser → validator →
roulette → MT5. The dashboard is a read/control surface; it never keeps the
engine alive.

## 0. Prerequisites

- Python 3.12 on PATH (`py -3`).
- MetaTrader 5 + MetaEditor.
- Python packages pinned in `listener/requirements.txt` (for the Listener).
- Windows. The BAT files use `cmd` and PowerShell.

## 1. Configure once

```sh
cd engine_py
copy engine_config.example.json engine_config.json
```

Then edit `engine_config.json`:

| Key | Meaning |
|---|---|
| `api_token` | Bearer token for the HTTP API + dashboard. Must not be empty. |
| `host` / `port` | MT5 link bind address/port (default `127.0.0.1:9123`) |
| `profile_login_map` | Optional MT5 login → profile mapping |

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
`listener/data/listener_queue.db`.

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

The risk planner is dry-run only: it sends read-only MT5 requests
(`GET_ACCOUNT`, `GET_SYMBOL_INFO`, `GET_RISK_PER_LOT`) and persists a `dry_run`
plan; it never sends `OPEN`. Telegram queue messages have an additional
fail-closed gate: `listener_queue_allow_execution` defaults to `false`.

## 5. Pipeline stages

Run each stage as a separate process from `engine_py`:

```sh
py -3 -m nixo_engine.listener_consumer --queue-db ..\listener\data\listener_queue.db --engine-db .\data\nixo_engine.db
py -3 -m nixo_engine.signal_processor --engine-db .\data\nixo_engine.db
py -3 -m nixo_engine.execution --config .\engine_config.json --engine-db .\data\nixo_engine.db
```

The consumer claims queue rows with a lease and acknowledges them only after
the Engine insert is durable. The parser accepts only explicit direction, one
symbol, one SL, at least one labelled TP, and an entry or NOW/MARKET. Edits and
deletes are recorded for audit but never produce a new trade signal.

## 6. Stop / restart

```sh
Stop_Nixo.bat     # stops the engine; state stays in data/nixo.db
Start_Nixo.bat    # starts again
```

On restart the engine restores roulette state, reconciles open MT5 positions,
and never re-executes a signal that already has a decision.

## 7. Health

```sh
Health_Check.bat
```

Expect `health: 200` and a JSON `status` body. Closing the browser does not
stop the engine.

## 8. Tests

```sh
cd engine_py && py -3 -m unittest discover -s tests -v
```

## 9. Security

- The API binds `127.0.0.1` only; the MT5 link refuses non-local addresses.
- `/health` and static dashboard files are public; every data endpoint needs
  `Authorization: Bearer <api_token>`.
- Never commit tokens, `engine_config.json`, `*.session`, or `*.db`.
