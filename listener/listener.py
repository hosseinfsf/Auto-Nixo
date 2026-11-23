"""
NIXO Listener — Telethon-based read-only Telegram user account listener.

Phase 5: source allowlist, security, correctness, operations fixes.
"""
import os
import sys
import asyncio
import hashlib
import sqlite3
import logging
import json
from datetime import datetime, timezone
from pathlib import Path
from logging.handlers import RotatingFileHandler

from dotenv import load_dotenv
from telethon import TelegramClient, events
from telethon.tl.types import Message

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
BASE_DIR = Path(__file__).resolve().parent
load_dotenv(BASE_DIR / ".env")

API_ID = int(os.getenv("TELEGRAM_API_ID", "0"))
API_HASH = os.getenv("TELEGRAM_API_HASH", "")
SESSION_PATH = BASE_DIR / os.getenv("SESSION_PATH", "session/nixo_listener.session")
QUEUE_DB_PATH = BASE_DIR / os.getenv("QUEUE_DB_PATH", "data/listener_queue.db")
DEFAULT_VALIDITY_SECONDS = 180
MAX_MEDIA_SIZE = 10 * 1024 * 1024  # 10 MB

# Logging with rotation
log_file = BASE_DIR / "data" / "listener.log"
log_file.parent.mkdir(parents=True, exist_ok=True)
handler = RotatingFileHandler(log_file, maxBytes=5*1024*1024, backupCount=3)
handler.setFormatter(logging.Formatter("%(asctime)s [%(levelname)s] %(name)s: %(message)s"))
log = logging.getLogger("nixo.listener")
log.addHandler(handler)
log.setLevel(logging.INFO)

# ---------------------------------------------------------------------------
# Queue (SQLite WAL)
# ---------------------------------------------------------------------------
def init_queue(db_path: Path) -> sqlite3.Connection:
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(db_path))
    conn.execute("PRAGMA journal_mode=WAL;")
    conn.execute("PRAGMA synchronous=NORMAL;")
    conn.execute("""
        CREATE TABLE IF NOT EXISTS listener_queue (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            chat_id       INTEGER NOT NULL,
            message_id    INTEGER NOT NULL,
            edit_version  INTEGER NOT NULL DEFAULT 0,
            date_utc      TEXT NOT NULL,
            sender_id     INTEGER,
            text          TEXT,
            caption       TEXT,
            media_path    TEXT,
            media_hash    TEXT,
            content_hash  TEXT,
            update_type   TEXT NOT NULL,
            ingested_at   TEXT NOT NULL,
            state         TEXT NOT NULL DEFAULT 'pending',
            error         TEXT,
            UNIQUE(chat_id, message_id, edit_version)
        );
    """)
    # Additive migrations keep existing queue rows intact.
    columns = {row[1] for row in conn.execute("PRAGMA table_info(listener_queue)")}
    migrations = {
        "validity_seconds": "INTEGER NOT NULL DEFAULT 180",
        "lease_owner": "TEXT",
        "lease_until_utc": "TEXT",
        "attempts": "INTEGER NOT NULL DEFAULT 0",
        "next_attempt_utc": "TEXT",
        "processed_at": "TEXT",
    }
    for name, declaration in migrations.items():
        if name not in columns:
            conn.execute(f"ALTER TABLE listener_queue ADD COLUMN {name} {declaration}")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_queue_state ON listener_queue(state, id);")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_queue_chat ON listener_queue(chat_id, message_id);")
    conn.commit()
    return conn


def init_sources_table(conn: sqlite3.Connection):
    conn.execute("""
        CREATE TABLE IF NOT EXISTS sources (
            chat_id      INTEGER PRIMARY KEY,
            title        TEXT,
            enabled      INTEGER NOT NULL DEFAULT 1,
            ttl_seconds  INTEGER NOT NULL DEFAULT 180
        );
    """)
    # Migrate older Listener DBs without resetting configured sources.
    columns = {row[1] for row in conn.execute("PRAGMA table_info(sources)")}
    if "ttl_seconds" not in columns:
        conn.execute(
            "ALTER TABLE sources ADD COLUMN ttl_seconds INTEGER NOT NULL DEFAULT 180"
        )
    conn.commit()


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return h.hexdigest()


def content_hash(text, caption, media_hash):
    h = hashlib.sha256()
    h.update((text or "").encode("utf-8"))
    h.update((caption or "").encode("utf-8"))
    h.update((media_hash or "").encode("utf-8"))
    return h.hexdigest()


def enqueue(conn: sqlite3.Connection, row: dict) -> bool:
    try:
        cur = conn.execute("""
            INSERT OR IGNORE INTO listener_queue
            (chat_id, message_id, edit_version, date_utc, sender_id, text,
             caption, media_path, media_hash, content_hash, update_type, ingested_at,
             state, validity_seconds)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, (
            row["chat_id"], row["message_id"], row["edit_version"],
            row["date_utc"], row.get("sender_id"), row.get("text"),
            row.get("caption"), row.get("media_path"), row.get("media_hash"),
            row.get("content_hash"), row["update_type"], row["ingested_at"],
            row.get("state", "pending"), row.get("validity_seconds", DEFAULT_VALIDITY_SECONDS),
        ))
        conn.commit()
        return cur.rowcount > 0
    except sqlite3.Error as e:
        log.error("enqueue error: %s", e)
        return False


# ---------------------------------------------------------------------------
# Sources management
# ---------------------------------------------------------------------------
def get_allowlisted_chats(conn: sqlite3.Connection):
    cur = conn.execute("SELECT chat_id FROM sources WHERE enabled=1")
    return [r[0] for r in cur.fetchall()]


def add_source(conn, chat_id, title=None, ttl_seconds=DEFAULT_VALIDITY_SECONDS):
    ttl = int(ttl_seconds)
    if ttl < 1 or ttl > 86400:
        raise ValueError("ttl_seconds must be between 1 and 86400")
    conn.execute("""
        INSERT INTO sources (chat_id, title, enabled, ttl_seconds)
        VALUES (?, ?, 1, ?)
        ON CONFLICT(chat_id) DO UPDATE SET
            title=COALESCE(excluded.title, sources.title),
            enabled=1,
            ttl_seconds=excluded.ttl_seconds
    """, (int(chat_id), title, ttl))
    conn.commit()


def source_validity_seconds(conn, chat_id):
    row = conn.execute(
        "SELECT ttl_seconds FROM sources WHERE chat_id=? AND enabled=1",
        (chat_id,),
    ).fetchone()
    ttl = int(row[0]) if row and row[0] is not None else DEFAULT_VALIDITY_SECONDS
    return ttl if 1 <= ttl <= 86400 else DEFAULT_VALIDITY_SECONDS


def remove_source(conn, chat_id):
    conn.execute("DELETE FROM sources WHERE chat_id=?", (chat_id,))
    conn.commit()


def toggle_source(conn, chat_id, enabled):
    conn.execute("UPDATE sources SET enabled=? WHERE chat_id=?", (1 if enabled else 0, chat_id))
    conn.commit()


# ---------------------------------------------------------------------------
# Media download (images only, max 10 MB)
# ---------------------------------------------------------------------------
async def download_media(client, msg, media_dir: Path):
    if not msg.media:
        return None, None
    # Images only
    if msg.photo:
        pass
    elif msg.document:
        mime = getattr(msg.document, "mime_type", "") or ""
        if not mime.startswith("image/"):
            return None, None
        size = getattr(msg.document, "size", 0) or 0
        if size > MAX_MEDIA_SIZE:
            log.warning("Media too large (%d bytes), skipping", size)
            return None, None
    else:
        return None, None

    media_dir.mkdir(parents=True, exist_ok=True)
    try:
        path = await client.download_media(msg, file=str(media_dir))
        if path:
            p = Path(path)
            h = hashlib.sha256()
            with open(p, "rb") as f:
                for chunk in iter(lambda: f.read(8192), b""):
                    h.update(chunk)
            return str(p), h.hexdigest()
    except Exception as e:
        log.warning("media download failed: %s", e)
    return None, None


# ---------------------------------------------------------------------------
# Message handlers
# ---------------------------------------------------------------------------
def make_row(msg, update_type, media_path=None, media_hash=None, edit_version=0,
             content_hash_val=None, validity_seconds=DEFAULT_VALIDITY_SECONDS):
    date_utc = msg.date.astimezone(timezone.utc).isoformat() if msg.date else datetime.now(timezone.utc).isoformat()
    state = "pending"
    validity = int(validity_seconds)
    if validity > 0 and msg.date:
        msg_date = msg.date.astimezone(timezone.utc)
        age = (datetime.now(timezone.utc) - msg_date).total_seconds()
        if age > validity:
            state = "expired"
    return {
        "chat_id": msg.chat_id,
        "message_id": msg.id,
        "edit_version": edit_version,
        "date_utc": date_utc,
        "sender_id": msg.sender_id,
        "text": msg.text if hasattr(msg, "text") else None,
        "caption": getattr(msg, "message", None) if hasattr(msg, "message") else None,
        "media_path": media_path,
        "media_hash": media_hash,
        "content_hash": content_hash_val,
        "update_type": update_type,
        "ingested_at": datetime.now(timezone.utc).isoformat(),
        "state": state,
        "validity_seconds": validity,
    }


async def handle_new_message(client, conn, msg, media_dir, allowed_chats):
    if msg.chat_id not in allowed_chats:
        return
    media_path, media_hash = await download_media(client, msg, media_dir)
    ch = content_hash(msg.text if hasattr(msg, "text") else None, None, media_hash)
    row = make_row(
        msg, "new", media_path, media_hash, content_hash_val=ch,
        validity_seconds=source_validity_seconds(conn, msg.chat_id),
    )
    inserted = enqueue(conn, row)
    if inserted:
        log.info("NEW msg %s/%s ingested", msg.chat_id, msg.id)
    else:
        log.debug("NEW msg %s/%s duplicate, skipped", msg.chat_id, msg.id)


async def handle_edit(client, conn, event, media_dir, allowed_chats):
    msg = event.message
    if msg.chat_id not in allowed_chats:
        return
    media_path, media_hash = await download_media(client, msg, media_dir)
    ch = content_hash(msg.text if hasattr(msg, "text") else None, None, media_hash)

    # Check if content unchanged from latest version
    cur = conn.execute(
        "SELECT content_hash FROM listener_queue WHERE chat_id=? AND message_id=? ORDER BY edit_version DESC LIMIT 1",
        (msg.chat_id, msg.id),
    )
    row = cur.fetchone()
    if row and row[0] == ch:
        log.debug("EDIT msg %s/%s content unchanged, skipped", msg.chat_id, msg.id)
        return

    cur = conn.execute(
        "SELECT COALESCE(MAX(edit_version), 0) FROM listener_queue WHERE chat_id=? AND message_id=?",
        (msg.chat_id, msg.id),
    )
    max_ver = cur.fetchone()[0]
    row = make_row(
        msg, "edit", media_path, media_hash, edit_version=max_ver + 1,
        content_hash_val=ch,
        validity_seconds=source_validity_seconds(conn, msg.chat_id),
    )
    inserted = enqueue(conn, row)
    if inserted:
        log.info("EDIT msg %s/%s v%d ingested", msg.chat_id, msg.id, row["edit_version"])
    else:
        log.debug("EDIT msg %s/%s duplicate, skipped", msg.chat_id, msg.id)


async def handle_delete(conn, chat_id, message_ids, allowed_chats):
    if chat_id not in allowed_chats:
        return
    now = datetime.now(timezone.utc).isoformat()
    for mid in message_ids:
        try:
            conn.execute("""
                UPDATE listener_queue
                SET state='deleted', error='telegram_message_deleted',
                    lease_owner=NULL, lease_until_utc=NULL
                WHERE chat_id=? AND message_id=? AND state='pending'
            """, (chat_id, mid))
            cur = conn.execute(
                "SELECT COALESCE(MAX(edit_version), -1) + 1 FROM listener_queue "
                "WHERE chat_id=? AND message_id=?",
                (chat_id, mid),
            )
            delete_version = cur.fetchone()[0]
            conn.execute("""
                INSERT OR IGNORE INTO listener_queue
                (chat_id, message_id, edit_version, date_utc, update_type, ingested_at, state)
                VALUES (?, ?, ?, ?, 'delete', ?, 'pending')
            """, (chat_id, mid, delete_version, now, now))
            conn.commit()
            log.info("DELETE msg %s/%s ingested", chat_id, mid)
        except sqlite3.Error as e:
            log.error("delete enqueue error: %s", e)


# ---------------------------------------------------------------------------
# Catch-up on reconnect (all allowlisted sources)
# ---------------------------------------------------------------------------
async def catchup(client, conn, chat_id, media_dir, allowed_chats):
    if chat_id not in allowed_chats:
        return
    cur = conn.execute(
        "SELECT MAX(date_utc) FROM listener_queue WHERE chat_id=?", (chat_id,)
    )
    last_date = cur.fetchone()[0]
    offset_date = None
    if last_date:
        offset_date = datetime.fromisoformat(last_date)

    log.info("Catch-up for chat %s from %s", chat_id, last_date)
    count = 0
    async for msg in client.iter_messages(chat_id, offset_date=offset_date, reverse=True, limit=200):
        media_path, media_hash = await download_media(client, msg, media_dir)
        ch = content_hash(msg.text if hasattr(msg, "text") else None, None, media_hash)
        row = make_row(
            msg, "new", media_path, media_hash, content_hash_val=ch,
            validity_seconds=source_validity_seconds(conn, chat_id),
        )
        if enqueue(conn, row):
            count += 1
    log.info("Catch-up complete for %s: %d new messages", chat_id, count)


# ---------------------------------------------------------------------------
# Status file
# ---------------------------------------------------------------------------
def write_status(conn, authorized, connected, last_event_at, last_error):
    try:
        status = {
            "authorized": authorized,
            "connected": connected,
            "proxy_mode": "disabled",
            "last_event_at": last_event_at,
            "queue_depth": conn.execute("SELECT COUNT(*) FROM listener_queue WHERE state='pending'").fetchone()[0],
            "queue_processing": conn.execute("SELECT COUNT(*) FROM listener_queue WHERE state='processing'").fetchone()[0],
            "last_error": last_error,
            "updated_at": datetime.now(timezone.utc).isoformat(),
        }
        status_path = BASE_DIR / "data" / "status.json"
        status_path.parent.mkdir(parents=True, exist_ok=True)
        status_path.write_text(json.dumps(status, indent=2))
    except Exception as e:
        log.warning("Failed to write status.json: %s", e)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
async def main():
    if not API_ID or not API_HASH:
        log.error("TELEGRAM_API_ID and TELEGRAM_API_HASH must be set in .env")
        sys.exit(1)

    SESSION_PATH.parent.mkdir(parents=True, exist_ok=True)
    conn = init_queue(QUEUE_DB_PATH)
    init_sources_table(conn)
    media_dir = BASE_DIR / "data" / "media"

    # Proxy links remain inert text; the Listener always connects directly.
    log.info("Proxy routing is disabled; any saved proxy link is reference-only.")
    client = TelegramClient(
        str(SESSION_PATH),
        API_ID,
        API_HASH,
        auto_reconnect=True,
        connection_retries=10,
        retry_delay=5,
    )

    allowed_chats = get_allowlisted_chats(conn)
    log.info("Allowlisted chats: %s", allowed_chats)

    # Handler registration (re-evaluated when sources change)
    handlers = []

    def register_handlers():
        nonlocal handlers
        for h in handlers:
            try:
                client.remove_event_handler(h)
            except Exception:
                pass
        handlers = []

        chats = allowed_chats if allowed_chats else None
        if chats is None:
            log.warning("No allowlisted sources; handlers not registered")
            return

        @client.on(events.NewMessage(chats=chats))
        async def on_new(event):
            await handle_new_message(client, conn, event.message, media_dir, allowed_chats)

        @client.on(events.MessageEdited(chats=chats))
        async def on_edit(event):
            await handle_edit(client, conn, event, media_dir, allowed_chats)

        @client.on(events.MessageDeleted(chats=chats))
        async def on_delete(event):
            await handle_delete(conn, event.chat_id, event.deleted_ids, allowed_chats)

        handlers.extend([on_new, on_edit, on_delete])

    register_handlers()

    log.info("Starting listener (read-only, no trading)...")
    await client.start()
    log.info("Logged in. Listening for messages...")

    authorized = await client.is_user_authorized()
    connected = client.is_connected()
    last_event_at = None
    last_error = None

    # Telethon built-in catch-up for missed updates
    try:
        await client.catch_up()
        log.info("Telethon catch_up() completed")
    except Exception as e:
        log.warning("catch_up() failed: %s", e)

    # Initial catch-up for all allowlisted sources
    for chat_id in allowed_chats:
        try:
            await catchup(client, conn, chat_id, media_dir, allowed_chats)
        except Exception as e:
            log.warning("Initial catch-up failed for %s: %s", chat_id, e)

    write_status(conn, authorized, connected, last_event_at, last_error)

    # Periodic catch-up (every 5 minutes) for all allowlisted sources
    async def periodic_catchup():
        nonlocal last_event_at
        while True:
            await asyncio.sleep(300)
            for chat_id in get_allowlisted_chats(conn):
                try:
                    await catchup(client, conn, chat_id, media_dir, get_allowlisted_chats(conn))
                except Exception as e:
                    log.warning("Periodic catch-up failed for %s: %s", chat_id, e)
            last_event_at = datetime.now(timezone.utc).isoformat()
            write_status(conn, authorized, connected, last_event_at, last_error)

    asyncio.create_task(periodic_catchup())

    # Re-read sources every 60s and re-register handlers if changed
    async def sources_refresh_loop():
        nonlocal allowed_chats
        while True:
            await asyncio.sleep(60)
            new_chats = get_allowlisted_chats(conn)
            if new_chats != allowed_chats:
                allowed_chats = new_chats
                register_handlers()
                log.info("Sources updated: %s", allowed_chats)

    asyncio.create_task(sources_refresh_loop())

    # Keep running
    await client.run_until_disconnected()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        log.info("Listener stopped by user.")
    except Exception as e:
        log.error("Fatal error: %s", e)
        sys.exit(1)
