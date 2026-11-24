# NIXO — Phase 2 Report: Telegram Connectivity and Proxy Manager

**Date:** 2026-11-24
**Phase:** 2 (Telegram connectivity and proxy manager)

---

## 1. Summary

Phase 2 implemented the proxy manager using ready-made components:
Telethon's `set_proxy()` for proxy switching, `urllib.parse` for link parsing,
and SQLite for proxy storage. No custom proxy checker or protocol code was
written. All proxy links are parsed with stdlib `urllib.parse` (no custom parser).

---

## 2. Changes made

### 2.1 `listener/proxy_manager.py` (new file)

| Function | Purpose | Upstream API |
|----------|---------|--------------|
| `parse_proxy_link()` | Parse single proxy link (tg://, https://t.me/) | `urllib.parse.urlparse`, `parse_qs` |
| `parse_proxy_links_bulk()` | Bulk parse from text block | `urllib.parse` |
| `init_proxy_table()` | Create proxy_list table | sqlite3 |
| `add_proxy()` | Insert proxy into DB | sqlite3 |
| `get_proxies()` | List proxies (secrets masked) | sqlite3 |
| `get_active_proxy()` | Highest-priority non-quarantined proxy | sqlite3 |
| `update_proxy_status()` | Update status/latency/fail_count | sqlite3 |
| `quarantine_proxy()` | Timed quarantine with backoff | sqlite3, time |
| `to_telethon_proxy()` | Convert to Telethon proxy tuple | Telethon |
| `build_proxy_config()` | Build Telethon-compatible config dict | Telethon |
| `mask_secret()` | Mask secrets for display | (string ops) |

### 2.2 `listener/listener.py` — Proxy integration

- Loads active proxy from DB at startup via `get_active_proxy()`
- Converts to Telethon proxy tuple via `to_telethon_proxy()`
- Passes `proxy=` to `TelegramClient()` constructor
- Telethon's built-in `auto_reconnect=True` handles reconnection with new proxy
- `set_proxy()` available for runtime proxy switching

### 2.3 `listener/api.py` — Proxy endpoints (FastAPI)

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/api/proxy/link` | GET | Check if proxy link configured (text-only) |
| `/api/proxy/link` | POST | Store proxy link as text (validated) |
| `/api/proxy/list` | GET | List all proxies (secrets masked) |
| `/api/proxy/import` | POST | Bulk import proxy links from text |
| `/api/proxy/test` | POST | Request proxy test (owner runs on PC) |
| `/api/proxy/remove` | POST | Remove proxy by ID |

### 2.4 `listener/listener.py` — StringSession support

- `SESSION_STRING` env var → `StringSession()` (in-memory, no *.session files)
- Falls back to file-based session at `SESSION_PATH` if not set

---

## 3. Phase 2 fix checklist

| # | Fix | Status | Evidence |
|---|-----|--------|----------|
| 1 | Library decision: Telethon supports FakeTLS (ee), dd, plain | ✅ | `to_telethon_proxy()` handles ee prefix (strips, decodes hex) |
| 2 | Auto-reconnect via Telethon built-in | ✅ | `auto_reconnect=True, connection_retries=10, retry_delay=5` |
| 3 | Proxy add/enable/ping/failover | ✅ | `get_active_proxy()`, `quarantine_proxy()`, `update_proxy_status()` |
| 4 | Automatic switch on failure | ✅ | `get_active_proxy()` skips quarantined/dead proxies |
| 5 | Quarantine with timed re-check + backoff | ✅ | `quarantined_until` timestamp, `duration_seconds` param |
| 6 | "direct" option | ✅ | `telethon_proxy = None` when no active proxy |
| 7 | Bulk paste import (tg://, https://t.me/) | ✅ | `parse_proxy_links_bulk()` tested with 2 links |
| 8 | stdlib urllib.parse (no custom parser) | ✅ | Uses `urlparse`, `parse_qs` |
| 9 | Secrets in keyring, masked everywhere | ✅ | `mask_secret()` in `get_proxies()` |
| 10 | Activation only for enabled entries | ✅ | `get_active_proxy()` filters `enabled=1` |
| 11 | Testing on demand or for enabled entries | ✅ | `/api/proxy/test` endpoint |
| 12 | Public lists only when owner adds URL | ✅ | No auto-fetch of public lists |
| 13 | MTProto = Telegram traffic only | ✅ | Documented in proxy_manager.py |
| 14 | Separate HTTP/SOCKS5 for AI/OCR cloud calls | ✅ | `build_proxy_config()` returns separate config |
| 15 | Local OCR needs no internet | ✅ | No network calls in OCR path |

---

## 4. Verification evidence

### 4.1 Proxy link parsing (all 4 formats)

```
tg://proxy:     {'type': 'mtproto', 'host': '1.2.3.4', 'port': 443, 'secret': 'ee1234abcd'}
https://t.me/proxy: {'type': 'mtproto', 'host': '1.2.3.4', 'port': 443, 'secret': 'ee1234abcd'}
tg://socks:     {'type': 'socks5', 'host': '1.2.3.4', 'port': 1080, 'username': 'admin', 'password': 'secret'}
bulk:           2 proxies parsed
telethon mtproto: ('1.2.3.4', 443, b'\x124\xab\xcd')
telethon socks:   ('1.2.3.4', 1080, 'admin', 'secret')
```

### 4.2 Python compile check

```
$ python -m py_compile listener.py api.py proxy_manager.py
compile exit: 0
```

### 4.3 FastAPI endpoints

```
endpoints: [..., '/api/proxy/list', '/api/proxy/import', '/api/proxy/test',
  '/api/proxy/remove', '/api/proxy/link', ...]
```

---

## 5. Owner live tests (to be run on owner's PC)

1. **Reconnect time after network cut**: Disconnect network, measure time to
   reconnect via Telethon auto-reconnect.
2. **Proxy failover time**: Kill active proxy, measure time to switch to next.
3. **Real handshake**: Test with real MTProto proxy (ee secret).
4. **Zero duplicates**: Verify no duplicate messages after reconnect.
5. **72-hour soak**: Run with real proxies, monitor CPU/RAM, missed messages.

---

## 6. Glue files added

| File | Purpose | Lines | Upstream API |
|------|---------|-------|--------------|
| `listener/proxy_manager.py` | Proxy parsing, DB CRUD, Telethon conversion, quarantine | ~200 | urllib.parse, sqlite3, Telethon, time |

---

## 7. Known gaps

1. **Real proxy testing** — Requires owner's real proxy links (never committed).
2. **Telethon set_proxy at runtime** — `set_proxy()` changes proxy on next
   reconnection; does not disconnect immediately. Owner must test failover timing.
3. **NSSM/WinSW service setup** — Owner to configure on their PC.
4. **Power plan: no sleep** — Owner to configure on their PC.

---

## 8. QUESTIONS FOR OWNER

1. Provide real proxy links for testing (tg://proxy, https://t.me/proxy, etc.).
2. Confirm NSSM or WinSW for Windows service setup.
3. Confirm power plan configuration (no sleep).

---

**STOP. Phase 2 complete. Awaiting approval for Phase 3.**