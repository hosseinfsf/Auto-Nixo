# NIXO LITE

A lightweight, bilingual (Persian/English, RTL) Windows app that reads trading
signals from Telegram sources (channels/groups; text and TradingView chart
screenshots), validates them, sizes them with money management, and executes
them on MetaTrader 5 — automatically and permanently, with zero user action
after start. Speed and accuracy are the top priorities.

This is a full rewrite of the legacy Python `Nixo_v5.04` project in Dart, per
`CHECKLIST.md` v2.

## Architecture (two Dart parts + one MQL5 EA)

- **`packages/core`** — pure-Dart shared package: models, parser, validator,
  risk, roulette.
- **`apps/engine`** — headless pure-Dart exe: Telegram (TDLib), proxy manager,
  input registry, pipeline, journal, MT5 link (socket server), local HTTP API.
- **`apps/ui`** — Flutter desktop app talking to the engine over localhost
  (token-protected). Closing/crashing the UI never stops trading.
- **`mt5/NixoLink.mq5`** — MQL5 EA (socket client, no DLL). The engine is the
  socket server on `127.0.0.1`.

## Quick start (on Windows)

Prerequisites: Dart SDK (or Flutter SDK, which bundles Dart), MetaTrader 5,
MetaEditor.

```sh
# 1. Core package
cd packages/core && dart pub get && dart analyze

# 2. Engine
cd ../../apps/engine && dart pub get && dart analyze
dart run bin/engine.dart --help

# 3. UI (Flutter)
cd ../../apps/ui && flutter pub get && flutter run -d windows

# 4. EA
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
  packages/core/    # shared models, parser, validator, risk
  apps/engine/      # headless engine
  apps/ui/          # Flutter desktop UI
  mt5/              # NixoLink.mq5 EA
  tests/  docs/  reports/
```

See `CHECKLIST.md` for the master checklist and `DECISIONS.md` for technology
decisions.
