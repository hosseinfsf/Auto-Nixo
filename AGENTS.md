# Agent notes — NIXO LITE (Dart rewrite)

## How to run/test (on Windows)
- This is a Dart/Flutter project, NOT the legacy Python Nixo_v5.04.
- Core: `cd packages/core && dart pub get && dart test`.
- Engine: `cd apps/engine && dart pub get && dart test`; run `dart run bin/engine.dart --self-test`.
- UI: `cd apps/ui && flutter pub get && flutter run -d windows`.
- EA: compile `mt5/NixoLink.mq5` in MetaEditor (F7). Never touch .ex5.

## Environment constraints
- Sandbox has no Dart/Flutter SDK, no Windows, no MT5, no live Telegram, and
  external downloads are blocked. All code is written but **must be compiled and
  tested on the owner's PC**.
- TDLib needs `tdjson.dll` (+ deps) next to the engine exe.
- Engine socket server binds 127.0.0.1:9123; HTTP API on 127.0.0.1:9124.

## Pitfalls
- `tdlib_client.dart` receive loop must stay on the main isolate (no
  `Isolate.run` — can't capture the client).
- MT5 protocol is `KEY=VALUE` per line, not JSON.
- Never commit api_id/hash, sessions, proxies, or secrets.
