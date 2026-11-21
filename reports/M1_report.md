# M1 Report — Engine Core + Telegram + Proxy + Input Registry

**Phase:** M1
**Date:** (build date)
**Commit:** (fill after commit)

## Checklist items completed (code written)
- Layout: packages/core, apps/engine, apps/ui, mt5/NixoLink.mq5, tests/, docs/, reports/.
- SQLite (WAL) store with all tables (`db.dart`).
- Telegram service with state machine, watchdog, never-exits (`telegram_source.dart`).
- Proxy manager: MTProto/SOCKS5/HTTP/local/direct, latency, failover (`proxy_manager.dart`).
- Input registry with auto-start (`input_registry.dart`).
- Idempotency: dedupe key `(input_id, message_id, edit_version)` persisted.
- Replay tool with fake executor (`replay.dart`).
- Tests: fake executor pipeline test, protocol test.

## Evidence (pending — run on PC)
```
cd packages/core && dart pub get && dart test
cd apps/engine && dart pub get && dart test
```

## Decisions made
- sqlite3 package (WAL) for storage.
- shelf + shelf_router for HTTP API/webhook.
- TDLib via FFI.

## Items NOT verified
- Live Telegram updates/reconnect (needs S1 on PC).
- Real MT5 socket (needs S2).

## QUESTIONS FOR OWNER
- Confirm Dart SDK version (>=3.0).

## Next phase plan
M2: EA execution + demo smoke test.
