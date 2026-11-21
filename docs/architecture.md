# NIXO LITE — Architecture

## Overview

Two Dart parts plus one MQL5 EA:

```
┌────────────────────┐         ┌──────────────────────────────┐
│  apps/ui (Flutter) │  HTTP   │  apps/engine (headless exe)  │
│  desktop UI        │◄───────►│  - Telegram (TDLib)          │
│  fa/en, RTL        │  local  │  - Proxy manager             │
└────────────────────┘  token  │  - Input registry            │
                              │  - Pipeline (classify→parse→  │
                              │    validate→risk→execute)     │
                              │  - SQLite (WAL) journal       │
                              │  - MT5 link (socket SERVER)   │
                              │  - HTTP API + webhook         │
                              └──────────────┬───────────────┘
                                             │ socket, 127.0.0.1
                                             │ KEY=VALUE protocol
                              ┌──────────────▼───────────────┐
                              │  mt5/NixoLink.mq5 (EA)       │
                              │  socket CLIENT, no DLL       │
                              │  CTrade, OrderCalcProfit     │
                              └──────────────────────────────┘
```

## Key decisions

- **Engine is the socket server**; MQL5 can only be a socket client. The EA
  connects to `127.0.0.1:9123`.
- **Protocol**: one message per line, `KEY=VALUE` separated by `|` (not JSON —
  avoids a JSON library in MQL5). First message `AUTH` with a random token.
  Heartbeat every 2s both ways.
- **Fail closed**: a signal that fails the deterministic validator never
  executes.
- **Idempotency**: intent written before send; EA acks with `client_order_id`;
  dedupe key = `(input_id, message_id, edit_version)`.
- **UI crash never stops trading**: the engine is a separate headless process.

## Packages

| Path | Role |
|---|---|
| `packages/core` | models, normalizer, classifier, text parser, symbol mapping, validator, sizing, SL/TP, roulette, limits |
| `apps/engine` | headless engine (config, db, telegram, proxy, input registry, pipeline, mt5 link, http api, watchdog, replay) |
| `apps/ui` | Flutter desktop UI |
| `mt5/NixoLink.mq5` | EA |

## Reliability

See `CHECKLIST.md` M6 for the full reliability matrix. The watchdog forces
reconnect on staleness; the Telegram service never exits on network errors; the
EA auto-reconnects with backoff.
