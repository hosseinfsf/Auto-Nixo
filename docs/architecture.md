# NIXO LITE — Architecture

## Overview

Python engine + Listener + one MQL5 EA:

```
┌──────────────────────────┐   SQLite queue   ┌──────────────────────────────┐
│ listener/ (Telethon)     │─────────────────►│ engine_py/nixo_engine/       │
│ Telegram User Account    │                  │ - queue consumer             │
│ manually started/stopped │                  │ - strict parser + validator  │
└──────────────────────────┘                  │ - roulette + risk planner    │
                                             │ - SQLite (WAL) journal       │
┌──────────────────────────┐   HTTP 127.0.0.1 │ - MT5 link (socket SERVER)   │
│ control_center/web/      │◄────────────────►│ - local HTTP API             │
│ vanilla dashboard        │     token        └──────────────┬───────────────┘
└──────────────────────────┘                                 │ socket, 127.0.0.1
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
- **UI crash never stops trading**: the dashboard is a separate static web app
  served by the engine; the engine runs headless.

## Components

| Path | Role |
|---|---|
| `listener/` | Python/Telethon Listener + Management Panel; writes raw events to a shared SQLite queue |
| `engine_py/nixo_engine/` | Python engine: queue consumer, parser, validator, roulette, risk planner, MT5 link, HTTP API |
| `control_center/web/` | Vanilla HTML/CSS/JS dashboard |
| `mt5/NixoLink.mq5` | EA |

## Reliability

See `CHECKLIST.md` M6 for the full reliability matrix. The Listener queue uses
time-limited leases and retries; the EA auto-reconnects with backoff.
