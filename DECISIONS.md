# DECISIONS

Every technology choice: what, why, alternatives. Updated as the project
progresses.

## Architecture

| Decision | Why | Alternatives |
|---|---|---|
| Two Dart parts (engine + UI) | UI crash never stops trading; shared core logic | Single monolithic app (rejected: UI crash stops trading) |
| Engine = headless pure-Dart exe | Runs on a server unchanged; no Flutter runtime needed | Python sidecar (rejected: checklist requires Dart) |
| Shared `packages/core` | One source of truth for models/parser/risk | Duplicated logic (rejected) |
| MT5 link = native MQL5 sockets, no DLL | No DLLs → prop-firm/security safe | MtApi, ZeroMQ, socket_mql5.dll (all rejected: DLLs) |
| Engine is socket SERVER on 127.0.0.1 | MQL5 can only be a socket client | — |

## Components

### Telegram (user client)
- **What `tdlib_client.dart` actually uses:** a **thin own FFI wrapper** around
  the TDLib JSON interface (`td_json_client_create/send/receive/execute/destroy`)
  loaded via `DynamicLibrary` from a local `tdjson.dll` (Windows) or
  `libtdjson.so` (Linux). It does **not** depend on the `telegram_client`
  package or on `ivk1800/tdlib-dart`; it mirrors that project's FFI approach.
  See `apps/engine/lib/src/telegram/tdlib_client.dart`.
- **Where `tdjson.dll` comes from:** it is **NOT committed** to this repo
  (it is in `.gitignore`). It must be fetched at build time on the owner's PC
  by `scripts/fetch_tdjson.ps1` from one of these allowed sources:
  1. `https://github.com/ivk1800/td-json-client-prebuilt` Releases (prebuilt
     `tdjson.dll`), or
  2. npm package `prebuilt-tdlib` (contains `tdjson.dll`), or
  3. a build of TDLib from source (`https://github.com/tdlib/td`).
  - Record the chosen version and SHA256 in `scripts/fetch_tdjson.ps1` when a
    version is pinned. (Not yet pinned — the owner must pick a source and
    version, then record the hash here.)
- Do NOT write own MTProto; do NOT use pure-Dart MTProto packages.

### MT5 EA
- Use MetaQuotes standard library: `#include <Trade/Trade.mqh>` (CTrade),
  `<Trade/SymbolInfo.mqh>`, `<Trade/PositionInfo.mqh>`, `<Trade/OrderInfo.mqh>`.
- Protocol: one message per line, `KEY=VALUE` separated by `|` (not JSON — no
  JSON library in MQL5). First message AUTH with random token. Heartbeat every
  2s both ways.

### Dart packages
| Package | Purpose |
|---|---|
| sqlite3 | SQLite (WAL) database |
| shelf + shelf_router | Local HTTP API + webhook endpoint |
| web_socket_channel | UI ↔ engine |
| crypto | HMAC/hash |
| ffi | TDLib FFI |
| image | crop/resize screenshots |
| Flutter: window_manager, tray_manager, launch_at_startup, local_notifier, flutter_secure_storage, flutter_localizations + intl, fl_chart | UI features |

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
