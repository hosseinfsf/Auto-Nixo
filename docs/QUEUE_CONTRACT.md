# NIXO — Queue Contract (Listener → Engine Bridge)

**Status:** DRAFT — awaiting owner approval before implementation.

---

## 1. Overview

SQLite is the **only** contract between the Listener and the Engine.
No sockets, no HTTP, no message queues. The Listener only INSERTs rows;
the Engine claims and updates them. Both processes may run on the same
machine or different machines sharing a network drive (future).

---

## 2. Database

- **File:** `listener/data/listener_queue.db` (shared path, configurable)
- **Mode:** WAL (Write-Ahead Logging) for concurrent read/write
- **Busy timeout:** 10 000 ms
- **Journal mode:** WAL
- **Synchronous:** FULL (durability over speed)

---

## 3. Schema: `listener_queue`

| Column | Type | Description |
|--------|------|-------------|
| `id` | INTEGER PK | Auto-increment row ID |
| `chat_id` | INTEGER NOT NULL | Telegram chat/channel ID |
| `message_id` | INTEGER NOT NULL | Telegram message ID |
| `edit_version` | INTEGER NOT NULL DEFAULT 0 | 0 = original, 1+ = edit |
| `date_utc` | TEXT NOT NULL | ISO-8601 UTC of the original Telegram message |
| `sender_id` | INTEGER | Sender user ID |
| `text` | TEXT | Message text |
| `caption` | TEXT | Media caption |
| `media_path` | TEXT | Local media file path |
| `media_hash` | TEXT | SHA-256 of media file |
| `content_hash` | TEXT | SHA-256 of (text + caption + media_hash) |
| `update_type` | TEXT NOT NULL | `new` / `edit` / `delete` |
| `ingested_at` | TEXT NOT NULL | ISO-8601 UTC when Listener inserted the row |
| `state` | TEXT NOT NULL DEFAULT 'pending' | See §4 State machine |
| `error` | TEXT | Error message on failure |
| `validity_seconds` | INTEGER NOT NULL DEFAULT 180 | Per-channel TTL (seconds) |
| `lease_owner` | TEXT | Worker ID that claimed this row |
| `lease_until_utc` | TEXT | Lease expiry timestamp (ISO-8601 UTC) |
| `attempts` | INTEGER NOT NULL DEFAULT 0 | Number of claim attempts |
| `next_attempt_utc` | TEXT | Earliest retry time (ISO-8601 UTC) |
| `processed_at` | TEXT | ISO-8601 UTC when processing completed |

**Constraints:**
- `UNIQUE(chat_id, message_id, edit_version)` — idempotency key
- `INDEX idx_queue_state ON listener_queue(state, id)` — fast claim queries
- `INDEX idx_queue_chat ON listener_queue(chat_id, message_id)` — fast lookups

---

## 4. State machine

```
pending ──claim──► processing ──success──► processed
   │                    │
   │                    ├──failure (retryable)──► pending (with backoff)
   │                    │
   │                    ├──failure (max attempts)──► failed
   │                    │
   │                    ├──expired TTL──► expired
   │                    │
   │                    ├──ignored (disabled channel)──► ignored
   │                    │
   │                    └──duplicate──► processed (duplicate_already_persisted)
   │
   └──lease expired──► pending (re-claimable)
```

### Terminal states (no further transitions):
- `processed` — successfully routed to Engine inbox
- `failed` — max retry attempts exhausted
- `expired` — TTL exceeded before processing
- `ignored` — channel not configured or disabled
- `deleted` — Telegram message was deleted

### Non-terminal states:
- `pending` — waiting to be claimed
- `processing` — claimed by a worker (lease active)

---

## 5. Claim / lease protocol

### 5.1 Claiming a row

The Engine polls every **100–200 ms**. A claim is an atomic
`BEGIN IMMEDIATE` transaction:

```sql
SELECT * FROM listener_queue
WHERE (state='pending'
       OR (state='processing' AND (lease_until_utc IS NULL OR lease_until_utc <= ?)))
  AND (next_attempt_utc IS NULL OR next_attempt_utc <= ?)
ORDER BY id LIMIT 1
```

Then:

```sql
UPDATE listener_queue
SET state='processing', lease_owner=?, lease_until_utc=?,
    attempts=COALESCE(attempts,0)+1
WHERE id=? AND (state='pending' OR (state='processing' AND (lease_until_utc IS NULL OR lease_until_utc <= ?)))
```

If `rowcount != 1`, the claim failed (another worker got it) → rollback.

### 5.2 Lease expiry

- Default lease: **30 seconds**
- If a worker crashes, the lease expires and the row returns to `pending`
- Expired leases are re-claimable by any worker
- `attempts` counter is preserved across re-claims

### 5.3 Retry with backoff

On failure, the row returns to `pending` with:
- `next_attempt_utc` = now + `min(300, 2^min(attempts, 8))` seconds
- `error` = truncated error message (max 1000 chars)
- `lease_owner` = NULL, `lease_until_utc` = NULL

After `max_attempts` (default 8), the row moves to `failed`.

### 5.4 Acknowledgement

A row is marked `processed` only after the Engine has durably persisted
the event in its own database (`NixoStore.record_channel_signal()`).
The acknowledgement is a separate transaction:

```sql
UPDATE listener_queue
SET state='processed', processed_at=?, lease_owner=NULL, lease_until_utc=NULL, next_attempt_utc=NULL
WHERE id=? AND state='processing' AND lease_owner=?
```

---

## 6. Crash recovery

### 6.1 Crash points and recovery

| Crash point | State | Recovery |
|-------------|-------|----------|
| Listener before INSERT | No row exists | Listener retries on next event |
| Listener after INSERT, before commit | Transaction rolled back | No row exists; Listener retries |
| Engine before claim | Row = `pending` | Engine re-claims on next poll |
| Engine after claim, before Engine DB write | Row = `processing`, lease active | Lease expires → re-claim → duplicate check prevents double insert |
| Engine after Engine DB write, before queue ACK | Row = `processing`, Engine DB has the event | Re-claim → `has_channel_event()` returns true → mark `processed` (duplicate) |
| Engine after queue ACK | Row = `processed` | No action needed |

### 6.2 Idempotency

The composite key `(chat_id, message_id, edit_version)` is used as:
- `UNIQUE` constraint in `listener_queue`
- `UNIQUE` constraint in Engine `signals` table (via `record_channel_signal`)
- `has_channel_event()` check in Engine before insert

A crash between Engine DB write and queue ACK is recovered as a
**duplicate** (not a second insert). The row is marked `processed` with
`error='duplicate_already_persisted'`.

---

## 7. Engine polling

- **Interval:** 100–200 ms (configurable via `--poll-interval`, default 0.5 s)
- **Busy timeout:** 10 000 ms on both databases
- **WAL mode:** enabled on both databases
- **Index:** `idx_queue_state ON listener_queue(state, id)` for fast claim queries

---

## 8. Deterministic signal ID

The Engine generates a deterministic signal ID from the composite key:

```
signal_id = (chat_id, message_id, edit_version) → UNIQUE in signals table
```

This ID is used as `CLIENT_ORDER_ID` in the form `tg:<chat_id>:<message_id>:<edit_version>`.

---

## 9. Edit / delete rules

| Event | Listener action | Engine action |
|-------|----------------|---------------|
| `new` | INSERT row with `update_type='new'` | Parse, validate, size, execute (if auto) |
| `edit` | INSERT row with `update_type='edit'`, `edit_version+1` | If original already processed → alert (never execute edit). If pending → supersede old version |
| `delete` | INSERT row with `update_type='delete'` | Cancel pending signal. If already ordered → alert (never cancel order) |

### Edit content-hash optimization

If an edit produces the same `content_hash` as the latest version,
the Listener skips the insert (no new row). This prevents duplicate
processing of no-op edits.

---

## 10. TTL / expiry

- **Default TTL:** 180 seconds (configurable per channel via `sources.ttl_seconds`)
- **Measured from:** original Telegram message date (`date_utc`)
- **Checked at:** insert time (Listener sets `state='expired'` if already expired)
- **Re-checked at:** claim time (Engine checks `current > telegram_date + validity_seconds`)
- **Expired rows:** moved to `expired` state, never processed

---

## 11. Reconciliation (crash recovery at each point)

### 11.1 Listener crash
- No row inserted → no recovery needed
- Partial transaction rolled back by SQLite

### 11.2 Engine crash before claim
- Row remains `pending` → re-claimed on restart

### 11.3 Engine crash after claim, before Engine DB write
- Row = `processing`, lease expires → re-claimed → duplicate check prevents double insert

### 11.4 Engine crash after Engine DB write, before queue ACK
- Row = `processing`, Engine DB has event → re-claim → `has_channel_event()` = true → mark `processed` (duplicate)

### 11.5 EA timeout
- Engine retries with same `client_order_id` → EA returns original ticket (idempotent)

### 11.6 EA crash
- EA stores `client_order_id` in Global Variables → on restart, duplicate `OPEN` returns original ticket

---

## 12. Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| `--queue-db` | (required) | Path to Listener's `listener_queue.db` |
| `--engine-db` | (required) | Path to Engine's SQLite database |
| `--poll-interval` | 0.5 s | Polling interval (100–200 ms recommended for production) |
| `lease_seconds` | 30 s | Lease duration for claimed rows |
| `max_attempts` | 8 | Max retry attempts before `failed` |

---

## 13. Security

- Both databases are local files (no network exposure)
- Engine only reads from queue DB, never writes to it (except state updates)
- Listener only writes to queue DB, never reads Engine DB
- No secrets in queue rows (text/caption only, no tokens)
- `busy_timeout` prevents lock contention

---

**STOP. Awaiting owner approval before implementation.**