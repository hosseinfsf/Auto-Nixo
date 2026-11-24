# NIXO LITE

A lightweight, bilingual (Persian/English, RTL) Windows app that reads trading
signals from Telegram sources (channels/groups; text and TradingView chart
screenshots), validates them, sizes them with money management, and executes
them on MetaTrader 5 — automatically and permanently, with zero user action
after start. Speed and accuracy are the top priorities.

The runtime is Python: a Telegram Listener (Telethon), a Python execution
engine, a local web control center, and the `mt5/NixoLink.mq5` MQL5 EA.

## Architecture (Python engine + Listener + one MQL5 EA)

- **`listener/`** — Python/Telethon Listener using a personal Telegram User
  Account. It is manually started/stopped from the Management Panel and writes
  raw events to a shared SQLite queue.
- **`engine_py/nixo_engine/`** — headless Python engine: queue consumer, strict
  signal parser, validator, roulette, risk planner, MT5 socket server, local
  HTTP API and web dashboard.
- **`control_center/web/`** — vanilla HTML/CSS/JS dashboard served by the
  engine on `127.0.0.1:9124` (token-protected).
- **`mt5/NixoLink.mq5`** — MQL5 EA (socket client, no DLL). The engine is the
  socket server on `127.0.0.1:9123`.

## Quick start (on Windows)

Prerequisites: Python 3.12, MetaTrader 5, MetaEditor.

```sh
# 1. Listener
cd listener && py -3 -m pip install -r requirements.txt

# 2. Engine tests
cd ../engine_py && py -3 -m unittest discover -s tests -v

# 3. EA
# Open mt5/NixoLink.mq5 in MetaEditor and compile (F7).
```

## Safety

- EA enforces demo/real visibility; Real requires a one-time explicit
  confirmation.
- Fail closed: missing/malformed control.json or stale status → no NEW.
- SL attached to every order.
- Never commit `.env.local`, `*.session`, API hash/tokens.

## Layout

```
nixo_lite/
  listener/         # Telegram Listener + Management Panel
  engine_py/        # Python engine, parser, risk, tests
  control_center/   # web dashboard
  mt5/              # NixoLink.mq5 EA
  docs/  reports/
```

See `CHECKLIST.md` for the master checklist and `DECISIONS.md` for technology
decisions.
