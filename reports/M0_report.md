# M0 Report — Spikes

**Phase:** M0
**Date:** (build date)
**Commit:** (fill after commit)

## Checklist items completed
This project was authored in a sandbox without Windows, MetaTrader 5, live
Telegram, or a Dart SDK. Therefore the spikes S1–S6 **cannot be executed here**.
The code scaffolding for each spike is present and ready to run on the owner's
PC. See "Items NOT verified".

## Evidence
No measured results yet. The code paths for each spike exist:

- **S1 (TDLib):** `apps/engine/lib/src/telegram/tdlib_client.dart` — FFI
  wrapper (loads `tdjson.dll`), auth states, receive loop, proxy calls.
- **S2 (MT5 link):** `apps/engine/lib/src/mt5/link_server.dart` + `protocol.dart`
  + `mt5/NixoLink.mq5`.
- **S3 (Images):** image path scaffolding in `telegram_source.dart`
  (`_extractPhoto`), OCR/vision pipeline not yet built (needs live samples).
- **S4 (Proxy):** `apps/engine/lib/src/proxy/proxy_manager.dart`.
- **S5 (Sizing):** `packages/core/lib/src/risk/sizing.dart` + EA `OrderCalcProfit`.
- **S6 (Webhook):** `apps/engine/lib/src/http_api.dart` (`POST /tv/<token>`).

## Decisions made
- TDLib via FFI (ivk1800/tdlib-dart approach), Windows binaries from Releases.
- MT5 link: native MQL5 sockets, no DLL; engine is socket server on
  127.0.0.1:9123.
- Protocol: `KEY=VALUE` line-based (not JSON).

## Problems found
- No Dart SDK in sandbox; no Windows/MT5/Telegram; external downloads blocked.
  → Tests must run on the owner's PC.

## Items NOT verified
- Live Telegram login/session/updates (S1).
- MT5 socket round-trip and MetaEditor compile (S2).
- Image OCR/vision accuracy (S3).
- Proxy failover with real proxies (S4).
- OrderCalcProfit lot math vs hand calc (S5).
- Webhook reachable via tunnel (S6).

## QUESTIONS FOR OWNER
1. Provide a Windows machine with Flutter SDK + MetaEditor.
2. Provide api_id/api_hash (Telegram) at test time — never committed.
3. Provide sample TradingView screenshots for S3.

## Next phase plan
Run S1–S6 on PC; then M1 engine core tests.
