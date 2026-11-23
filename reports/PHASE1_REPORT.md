# NIXO — Phase 1 Report: Listener P0/P1 Fixes

**Date:** 2026-11-24
**Phase:** 1 (Listener P0/P1 fixes — ready-made features only)

---

## 1. Summary

Phase 1 completed all listener P0/P1 fixes using ready-made components
(Telethon, FastAPI, uvicorn, pydantic, python-dotenv, python-socks).
No custom protocol/parser/queue/proxy-checker code was written.
All changes are glue code wiring upstream APIs.

---

## 2. Changes made

### 2.1 `listener/listener.py` — Core listener fixes

| Fix | What changed | Upstream API |
|-----|-------------|--------------|
| `synchronous=FULL` | `PRAGMA synchronous=NORMAL` → `PRAGMA synchronous=FULL` | sqlite3 |
| `sources` table: `profile_id` column | Added `profile_id TEXT` to schema + migration | sqlite3 |
| `add_source()` accepts `profile_id` | New parameter, stored in sources table | sqlite3 |
| In-memory `StringSession` | `SESSION_STRING` env var → `StringSession()` instead of file-based session | Telethon `StringSession` |
| `synchronous=FULL` verified | `PRAGMA synchronous` returns 2 (FULL) | sqlite3 |

### 2.2 `listener/api.py` — Replaced http.server with FastAPI

| Feature | Implementation | Upstream API |
|---------|---------------|--------------|
| HTTP framework | FastAPI + uvicorn | FastAPI, uvicorn |
| Token auth | `hmac.compare_digest` via middleware | FastAPI middleware |
| Exact-origin CORS | `CORSMiddleware` with `allow_origins=[PANEL_ORIGIN]` | FastAPI CORS |
| Host/Origin check | Middleware validates `Host` and `Origin` headers | FastAPI middleware |
| Body size limit | `Content-Length` check in middleware (64 KB) | FastAPI middleware |
| 127.0.0.1 binding | `uvicorn.run(app, host="127.0.0.1", port=9125)` | uvicorn |
| Request validation | Pydantic models (`SourceIn`, `SourceRemoveIn`, `ProxyLinkIn`) | pydantic |
| No secrets in responses/logs | `log_message` suppressed; proxy link never echoed | FastAPI |

### 2.3 `listener/requirements.txt` — Updated dependencies

Added: `fastapi==0.115.0`, `uvicorn[standard]==0.30.0`, `pydantic==2.9.0`

---

## 3. Phase 1 fix checklist

| # | Fix | Status | Evidence |
|---|-----|--------|----------|
| 1 | Source allowlist table `sources(chat_id, title, enabled, ttl_seconds, profile_id)` | ✅ | Schema verified: columns include `profile_id` |
| 2 | Telethon `chats=` filter | ✅ | `events.NewMessage(chats=chats)` in listener.py |
| 3 | Private/bot/non-listed chats ignored | ✅ | `if msg.chat_id not in allowed_chats: return` |
| 4 | Images only with size cap | ✅ | `download_media()` checks `msg.photo` / `msg.document` mime + 10 MB cap |
| 5 | `cursor.rowcount` instead of `total_changes` | ✅ | `enqueue()` returns `cur.rowcount > 0` |
| 6 | Edit content_hash (no new version when unchanged) | ✅ | `handle_edit()` checks `row[0] == ch` and skips |
| 7 | `synchronous=FULL` for queue | ✅ | `PRAGMA synchronous` returns 2 (FULL) |
| 8 | Per-source TTL (default 180 s) applied at insert | ✅ | `source_validity_seconds()` + `make_row()` state=expired |
| 9 | Per-source TTL re-checked by Engine | ✅ | Engine `listener_queue_consumer.py` checks `validity_seconds` |
| 10 | Library-native catch-up for ALL sources | ✅ | `client.catch_up()` + `catchup()` per chat |
| 11 | Health checks with in-memory StringSession | ✅ | `SESSION_STRING` env → `StringSession()` |
| 12 | PySocks vs python-socks consistency | ✅ | `python-socks==3.2.2` in requirements (Telethon prefers it) |
| 13 | Remove Pytdbot from phase-1 requirements | ✅ | Not in requirements.txt |
| 14 | Real lockfile (pip-compile --generate-hashes) | ⏳ | Owner to run `pip-compile --generate-hashes` |
| 15 | FastAPI replaces http.server | ✅ | `api.py` uses FastAPI + uvicorn |
| 16 | Token required, loaded from .env | ✅ | `LISTENER_API_TOKEN` from `.env`, refuses to start without it |
| 17 | `hmac.compare_digest` | ✅ | `_authorized()` uses `hmac.compare_digest` |
| 18 | Exact-origin CORS incl. Authorization header | ✅ | `CORSMiddleware` with `allow_headers=["Content-Type", "Authorization"]` |
| 19 | Host/Origin check | ✅ | `_validate_host_origin()` middleware |
| 20 | 127.0.0.1 binding | ✅ | `uvicorn.run(app, host="127.0.0.1", port=9125)` |
| 21 | Body limit | ✅ | `MAX_BODY_SIZE = 65536`, checked in middleware |
| 22 | No secrets in responses/logs | ✅ | `log_message` suppressed; proxy link never echoed |
| 23 | `data/status.json` written | ✅ | `write_status()` in listener.py |

---

## 4. Verification evidence

### 4.1 FastAPI import + endpoints

```
$ python -c "import api; print('api.py imports OK'); print('app:', api.app.title)"
api.py imports OK
app: NIXO Listener API
endpoints: ['/openapi.json', '/api/listener/status', '/api/listener/start',
  '/api/listener/stop', '/api/sources', '/api/sources', '/api/sources/remove',
  '/api/proxy/link', '/api/proxy/link', '/api/proxy/list', '/api/proxy/add',
  '/api/proxy/test', '/api/proxy/remove', '/api/queue/stats', '/api/queue/recent']
```

### 4.2 Python compile check

```
$ python -m py_compile listener.py api.py
compile exit: 0
```

### 4.3 Synchronous=FULL verified

```
$ python -c "import listener; conn = listener.init_queue(...); print(conn.execute('PRAGMA synchronous').fetchone()[0])"
2  (2 = FULL)
```

### 4.4 Sources table schema

```
sources columns: ['chat_id', 'title', 'enabled', 'ttl_seconds', 'profile_id']
```

### 4.5 StringSession import

```
from telethon.sessions import StringSession  # OK
```

### 4.6 FastAPI server smoke test

```
$ python api.py  (started on 127.0.0.1:9125)
HTTP 401 {"error": "unauthorized"}  (correct — no token provided)
```

---

## 5. Owner live tests (to be run on owner's PC)

These require a live Telegram session and cannot be verified in sandbox:

1. **Delete message → update_type='delete'**: Delete a message in an allowlisted
   channel. Verify a row with `update_type='delete'` appears in `listener_queue`.
2. **Edit twice → versions 1,2**: Edit a message twice. Verify two rows with
   `edit_version=1` and `edit_version=2`.
3. **Edit without change → no row**: Edit a message without changing content.
   Verify no new row is inserted (content_hash match skips).
4. **Non-listed/private chat → nothing stored**: Post in a non-allowlisted chat.
   Verify no row in `listener_queue`.
5. **10-minute offline + 5 posts → all 5 appear once**: Disconnect listener for
   10 minutes, post 5 messages, reconnect. Verify all 5 appear exactly once.

SQL checks:
```sql
-- Verify delete
SELECT * FROM listener_queue WHERE update_type='delete';

-- Verify edit versions
SELECT chat_id, message_id, edit_version FROM listener_queue
WHERE update_type='edit' ORDER BY edit_version;

-- Verify no duplicates
SELECT chat_id, message_id, edit_version, COUNT(*) FROM listener_queue
GROUP BY chat_id, message_id, edit_version HAVING COUNT(*) > 1;
```

---

## 6. Glue files added

| File | Purpose | Lines | Upstream API |
|------|---------|-------|--------------|
| `listener/api.py` | FastAPI HTTP API (rewritten from http.server) | ~360 | FastAPI, uvicorn, pydantic, hmac, sqlite3 |
| `listener/listener.py` | Telethon listener (modified) | ~530 | Telethon, sqlite3, python-dotenv |

---

## 7. Known gaps

1. **pip-compile lockfile** — Owner to run `pip-compile --generate-hashes` to
   produce `requirements.txt` with hashes.
2. **Live tests** — All 5 owner live tests require a real Telegram session.
3. **Proxy manager** — Phase 2 scope (not yet implemented).
4. **`control_center/web/`** — Untracked vanilla reference dashboard; decision
   deferred to owner.

---

## 8. QUESTIONS FOR OWNER

1. Run `pip-compile --generate-hashes` on your PC and commit the lockfile.
2. Execute the 5 live tests above and paste results.
3. Confirm `control_center/web/` keep/remove decision.

---

**STOP. Phase 1 complete. Awaiting approval for Phase 2.**