# M0 Report — Spikes

**Phase:** M0
**Date:** (build date)
**Commit:** (fill after commit)

## Checklist items completed
This project was authored in a sandbox without Windows, MetaTrader 5, or live
Telegram. Therefore the spikes S1–S6 **cannot be executed here**.
The code scaffolding for each spike is present and ready to run on the owner's
PC. See "Items NOT verified".

## Evidence
No measured results yet. The code paths for each spike exist:

- **S1 (Telegram):** `listener/` — Telethon Listener with a personal User
  Account session; needs live credentials.
- **S2 (MT5 link):** `engine_py/nixo_engine/server.py` + `mt5_protocol.py`
  + `mt5/NixoLink.mq5`.
- **S3 (Images):** not built (needs live samples).
- **S4 (Proxy):** `listener/proxy_manager.py`.
- **S5 (Sizing):** `engine_py/nixo_engine/execution.py` + EA `OrderCalcProfit`.
- **S6 (Webhook):** not built.

## Decisions made
- Telegram via Telethon (personal User Account), not a Bot API token.
- MT5 link: native MQL5 sockets, no DLL; engine is socket server on
  127.0.0.1:9123.
- Protocol: `KEY=VALUE` line-based (not JSON).

## Problems found
- No Windows/MT5/Telegram in sandbox; external downloads blocked.
  → Tests must run on the owner's PC.

## Items NOT verified
- Live Telegram login/session/updates (S1).
- MT5 socket round-trip and MetaEditor compile (S2).
- Image OCR/vision accuracy (S3).
- Proxy failover with real proxies (S4).
- OrderCalcProfit lot math vs hand calc (S5).
- Webhook reachable via tunnel (S6).

## QUESTIONS FOR OWNER
1. Provide a Windows machine with Python 3.12 + MetaEditor.
2. Provide api_id/api_hash (Telegram) at test time — never committed.
3. Provide sample TradingView screenshots for S3.

## Next phase plan
Run S1–S6 on PC; then M1 engine core tests.
