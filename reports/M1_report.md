# M1 Report — Engine Core + Telegram + Proxy + Input Registry

**Phase:** M1
**Date:** (build date)
**Commit:** (fill after commit)

## Checklist items completed (code written)
- Layout: listener/, engine_py/, control_center/web/, mt5/NixoLink.mq5, docs/, reports/.
- SQLite (WAL) store with all tables (`engine_py/nixo_engine/db.py`).
- Telegram Listener: Telethon User Account, manually controlled (`listener/`).
- Proxy manager: MTProto/SOCKS5/HTTP/local/direct, latency, failover (`listener/proxy_manager.py`).
- Input registry with auto-start (`engine_py/nixo_engine/db.py`).
- Idempotency: dedupe key `(input_id, message_id, edit_version)` persisted.
- Replay tool with fake executor (`engine_py/nixo_engine/execution.py`).
- Tests: parser, protocol, server, queue consumer, risk planner (65 tests).

## Evidence (pending — run on PC)
```sh
cd engine_py && py -3 -m unittest discover -s tests -v
```

## Decisions made
- sqlite3 (stdlib) for storage.
- asyncio (stdlib) for the MT5 link server.
- Telethon for Telegram.

## Items NOT verified
- Live Telegram updates/reconnect (needs S1 on PC).
- Real MT5 socket (needs S2).

## QUESTIONS FOR OWNER
- Confirm Python 3.12 on the owner's PC.

## Next phase plan
M2: EA execution + demo smoke test.
