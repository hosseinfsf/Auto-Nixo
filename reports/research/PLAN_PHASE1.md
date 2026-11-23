# NIXO — Phase 1 Plan: Read-Only Telegram Listener Spike

> No code. No installs. No clones. This plan describes what the owner will do manually.
> Awaiting explicit approval of exact versions before any implementation.

---

## 1. Goal

Build a minimal, read-only Telegram listener that:
- Logs in as a personal Telegram user account (MTProto, not Bot API).
- Receives text, captions, media, edits, deletions from a single private TEST channel.
- Persists every message to a local SQLite WAL queue (idempotent on chat_id+message_id+edit_version).
- Survives reconnects and 10-minute offline gaps (catch-up inside validity window).
- Is startable/stoppable from the Management Panel (localhost web).
- Does NOT trade, does NOT send messages, does NOT connect to MT5.

---

## 2. Folder layout (proposed, not created)

```
listener/
├── listener.py          # entrypoint (Telethon primary)
├── listener_pytdbot.py  # secondary (Pytdbot) — only if Telethon fails
├── queue.py             # SQLite WAL queue helpers
├── config.py            # loads config from env + JSON
├── requirements.txt     # pinned versions + hashes
├── .env.example         # template (never commit .env)
├── session/             # Telethon session files (gitignored, encrypted)
└── data/
    └── listener_queue.db  # SQLite WAL (gitignored)
```

Conflicts with existing Nixo: none (new top-level folder). Does not touch `archive/`, `mt5/`, `control_center/`.

---

## 3. Exact packages and pinned versions

| Package | Version | Source | Hash (SHA-256) | Notes |
|---|---|---|---|---|
| Telethon | 1.46.0 | https://pypi.org/project/Telethon/ | 8357f5719376a9c1ddf0999136a44594a5b21b453647f1e146c169483b6a67df (sdist) | Primary. Pure Python, py3-none-any wheel. |
| Pytdbot | 0.8.8 | https://pypi.org/project/Pytdbot/ | 6ee8fb06d2e28818f5869936794666e94c2e8d07a5edf52d20bc3e51f15a5c44 (sdist) | Secondary. Bundles tdjson via `pytdbot[tdjson]`. |
| Python | 3.11+ | https://www.python.org/downloads/windows/ | UNVERIFIED (installer hash) | Owner installs manually. |

**UNVERIFIED:** exact wheel hashes for Telethon (only sdist hash verified). Owner must verify on install.

---

## 4. Owner login procedure

1. Owner creates a Telegram app at https://my.telegram.org → API Development Tools → gets `api_id` and `api_hash`.
2. Owner stores `api_id` and `api_hash` in Windows Credential Manager (or a local `.env` that is gitignored). Never in the repo.
3. First run: listener prompts for phone number → sends code to Telegram app → owner enters code → if 2FA enabled, owner enters password.
4. Session file stored at `listener/session/nixo_listener.session` (Telethon default SQLite session). This file is gitignored and must never be committed.
5. Subsequent runs reuse the session (no re-login).

**Security:** session file = full account access. Store on encrypted volume if possible. Never share, never commit.

---

## 5. Queue schema (FIELDS only, no code)

Table: `listener_queue` (SQLite WAL)

| Field | Type | Description |
|---|---|---|
| `id` | INTEGER PK | Auto-increment row id |
| `chat_id` | INTEGER | Telegram chat/channel ID |
| `message_id` | INTEGER | Telegram message ID |
| `edit_version` | INTEGER | 0 = original, 1+ = edit number |
| `date_utc` | TEXT (ISO-8601) | Message date (UTC) |
| `sender_id` | INTEGER | Sender user ID (nullable) |
| `text` | TEXT | Message text (nullable) |
| `caption` | TEXT | Media caption (nullable) |
| `media_path` | TEXT | Local path to downloaded media (nullable) |
| `media_hash` | TEXT | SHA-256 of media file (nullable) |
| `update_type` | TEXT | `new` / `edit` / `delete` |
| `ingested_at` | TEXT (ISO-8601) | When listener stored it (UTC) |
| `state` | TEXT | `pending` / `processed` / `failed` |
| `error` | TEXT | Error message if failed (nullable) |

**Idempotency rule:** UNIQUE constraint on `(chat_id, message_id, edit_version)`. Duplicate inserts are silently ignored (INSERT OR IGNORE).

**Catch-up rule:** On reconnect, listener calls `get_messages` with `offset_date` = last ingested message date, limit = 100, paginating until no new messages. Only messages within `validity_seconds` (default 300s) are marked `pending`; older ones marked `expired`.

---

## 6. Proxy list handling

- Proxy entries stored in a separate SQLite table `proxy_list` (or JSON file, gitignored).
- Fields: `id`, `type` (mtproto/socks5/http/local/direct), `host`, `port`, `secret` (masked in UI), `priority`, `status` (active/dead/quarantined), `latency_ms`, `last_check_utc`, `fail_count`.
- **Policy (owner-approved):**
  1. Own MTProto server (mtg) first.
  2. Local Xray/Clash SOCKS5 second.
  3. Public lists only by explicit user action (never default, never auto-imported).
- Health check: real MTProto handshake through Telethon's proxy API (not just TCP connect). Quarantine after 3 consecutive failures.
- Secrets masked in UI and never logged or committed.

---

## 7. Start/Stop exposed to panel

- Listener runs as a separate process (Python).
- Panel (localhost web) calls a local HTTP endpoint or spawns/kills the process via a supervisor (Task Scheduler / NSSM / WinSW — see report section H).
- Panel shows: connection status, authorization status (login-required / code-needed / 2FA-needed), last message time, queue depth, proxy status.
- Start/Stop buttons in panel; listener keeps collecting while engine is stopped.

---

## 8. Test cases (acceptance criteria)

| # | Test | Pass criteria |
|---|---|---|
| 1 | Reconnect after network drop | Listener reconnects within 30s; no duplicate messages in queue |
| 2 | Proxy failover | Dead proxy quarantined; next proxy used; handshake verified |
| 3 | Edit handling | Edited message creates new row with edit_version=1; original preserved |
| 4 | Duplicate prevention | Same message sent twice → only one row in queue |
| 5 | Restart survival | Kill listener; restart; no data loss; catch-up fetches missed messages |
| 6 | 10-minute offline | Messages during offline are fetched on reconnect (within validity window) |
| 7 | Media download | Photo in TEST channel → media_path and media_hash populated |
| 8 | Deletion handling | Deleted message → update_type='delete' row (or marked deleted) |
| 9 | No trading | Zero MT5 connections, zero order sends, zero Telegram sends |
| 10 | Session security | Session file not in git; .env not in git; secrets not in logs |

---

## 9. Rollback

- Delete `listener/` folder. No other files touched.
- Drop `listener_queue.db` and session file.
- No changes to `mt5/`, `control_center/`, `archive/`, `apps/`.

---

## 10. Risks

- Userbot ToS: read-only is lowest risk (https://core.telegram.org/api/terms). Owner accepts risk.
- Session file theft = full account access. Mitigate: gitignore, encrypted volume, no sharing.
- Telethon v1 is in maintenance mode (new layers still updated). Acceptable for read-only use.
- Pytdbot Windows wheel UNVERIFIED — secondary only, fallback if Telethon fails.

---

## 11. What the owner must do manually

1. Install Python 3.11+ from https://www.python.org/downloads/windows/ (check "Add to PATH").
2. Create Telegram app at https://my.telegram.org → save api_id + api_hash.
3. Create a private TEST channel (only source for first live test).
4. Post 5-10 test messages (text + photo + edit + delete) to the TEST channel.
5. Review and approve exact versions in this plan.
6. Switch to agent mode for implementation.

---

## 12. STOP

After delivering this plan, STOP. Do not implement, install, clone, create files or change anything. Wait for explicit approval of exact versions.
