# DECISIONS

Every technology choice: what, why, alternatives. Updated as the project
progresses.

## Architecture

| Decision | Why | Alternatives |
|---|---|---|
| Python engine + separate Listener | UI crash never stops trading; shared SQLite queue | Single monolithic app (rejected: UI crash stops trading) |
| Engine = headless Python process | Runs on a server unchanged; standard library only | (Dart/Flutter removed) |
| Listener = separate Telethon process | One session implementation; manual control | Pyrogram (rejected: archived) |
| MT5 link = native MQL5 sockets, no DLL | No DLLs → prop-firm/security safe | MtApi, ZeroMQ, socket_mql5.dll (all rejected: DLLs) |
| Engine is socket SERVER on 127.0.0.1 | MQL5 can only be a socket client | — |

## Components

### Telegram (user client)
- **What the Listener uses:** Telethon 1.46.0, a pure-Python MTProto client.
  It logs in with the personal Telegram User Account, reads allowlisted
  channels/groups, and writes raw events (new/edit/delete) into a shared
  SQLite queue. See `listener/`.
- **Session storage:** `listener/session/` (gitignored). Never commit the
  session file or `TELEGRAM_API_ID`/`TELEGRAM_API_HASH`.
- Do NOT use Pyrogram (archived). Do NOT write own MTProto.

### MT5 EA
- Use MetaQuotes standard library: `#include <Trade/Trade.mqh>` (CTrade),
  `<Trade/SymbolInfo.mqh>`, `<Trade/PositionInfo.mqh>`, `<Trade/OrderInfo.mqh>`.
- Protocol: one message per line, `KEY=VALUE` separated by `|` (not JSON — no
  JSON library in MQL5). First message AUTH with random token. Heartbeat every
  2s both ways.

### Python packages
| Package | Purpose |
|---|---|
| telethon | Telegram User Account client |
| sqlite3 (stdlib) | SQLite (WAL) databases |
| asyncio (stdlib) | MT5 link server, queue polling |
| shelf / aiohttp | Local HTTP API + webhook endpoint (if added) |

### OCR
- Tesseract CLI (UB-Mannheim Windows build) with digits-only whitelist on a
  cropped right-axis strip. Alternatives if worse: PaddleOCR, Windows built-in
  OCR. Chosen by measured accuracy/latency (spike S3).

### Public HTTPS (TradingView webhooks)
- Cloudflare Tunnel on port 443. TradingView accepts only 80/443, IPv4 only.
- Security: secret path token + passphrase field; body size/rate limits;
  allowlist TradingView IPs.

## Reference repo (READ-ONLY): nixo-autoTrades
- Port: parser templates, sizing, TP-split, break-even, roulette
  (docs/ROULETTE_SPEC.md) EXACTLY.
- Known bugs NOT to copy: sizing without tick_size; dedupe by timestamp;
  substring "true" gate checks; never-written ea_status.json; bridge exiting on
  Telegram timeout; unordered dedupe trimming.

## Rejected
- MtApi (.NET + DLLs), ZeroMQ connectors (libzmq.dll), socket_mql5.dll — all
  rejected for DLL/prop-firm/security reasons.
