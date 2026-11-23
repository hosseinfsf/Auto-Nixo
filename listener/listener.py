"""
NIXO Listener — Telethon-based read-only Telegram user account listener.

Phase 2: proxy support, catch-up on reconnect, MessageDeleted handling,
proxy health check, failover, quarantine.
"""
import os
import sys
import asyncio
import hashlib
import sqlite3
import logging
import time
from datetime import datetime, timezone
from pathlib import Path

from dotenv import load_dotenv
from telethon import TelegramClient, events
from telethon.tl.types import Message
from telethon.network.connection import (
    ConnectionTcpMTProxyAbridged,
    ConnectionTcpMTProxyIntermediate,
    ConnectionTcpMTProxyRandomizedIntermediate,
)

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
BASE_DIR = Path(__file__).resolve().parent
load_dotenv(BASE_DIR / ".env")

API_ID = int(os.getenv("TELEGRAM_API_ID", "0"))
API_HASH = os.getenv("TELEGRAM_API_HASH", "")
SESSION_PATH = BASE_DIR / os.getenv("SESSION_PATH", "session/nixo_listener.session")
QUEUE_DB_PATH = BASE_DIR / os.getenv("QUEUE_DB_PATH", "data/listener_queue.db")
VALIDITY_SECONDS = int(os.getenv("VALIDITY_SECONDS", "300"))
TEST_CHANNEL_ID = os.getenv("TEST_CHANNEL_ID", "")

# Proxy config
PROXY_TYPE = os.getenv("PROXY_TYPE", "").strip().lower()  # mtproto | socks5 | http | (empty=direct)
PROXY_HOST = os.getenv("PROXY_HOST", "").strip()
PROXY_PORT = int(os.getenv("PROXY_PORT", "0")) if os.getenv("PROXY_PORT", "").strip() else 0
PROXY_SECRET = os.getenv("PROXY_SECRET", "").strip()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
log = logging.getLogger("nixo.listener")


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
            update_type   TEXT NOT NULL,
            ingested_at   TEXT NOT NULL,
            state         TEXT NOT NULL DEFAULT 'pending',
            error         TEXT,
            UNIQUE(chat_id, message_id, edit_version)
        );
    """)
    conn.execute("CREATE INDEX IF NOT EXISTS idx_queue_state ON listener_queue(state);")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_queue_chat ON listener_queue(chat_id, message_id);")
    conn.commit()
    return conn


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return h.hexdigest()


def enqueue(conn: sqlite3.Connection, row: dict) -> bool:
    try:
        conn.execute("""
            INSERT OR IGNORE INTO listener_queue
            (chat_id, message_id, edit_version, date_utc, sender_id, text,
             caption, media_path, media_hash, update_type, ingested_at, state)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, (
            row["chat_id"], row["message_id"], row["edit_version"],
            row["date_utc"], row.get("sender_id"), row.get("text"),
            row.get("caption"), row.get("media_path"), row.get("media_hash"),
            row["update_type"], row["ingested_at"], row.get("state", "pending"),
        ))
        conn.commit()
        return conn.total_changes > 0
    except sqlite3.Error as e:
        log.error("enqueue error: %s", e)
        return False


# ---------------------------------------------------------------------------
# Proxy table
# ---------------------------------------------------------------------------
def init_proxy_table(conn: sqlite3.Connection):
    conn.execute("""
        CREATE TABLE IF NOT EXISTS proxy_list (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            type          TEXT NOT NULL,
            host          TEXT NOT NULL,
            port          INTEGER NOT NULL,
            secret        TEXT,
            priority      INTEGER NOT NULL DEFAULT 0,
            status        TEXT NOT NULL DEFAULT 'active',
            latency_ms    REAL,
            last_check    TEXT,
            fail_count    INTEGER NOT NULL DEFAULT 0,
            UNIQUE(type, host, port)
        );
    """)
    conn.commit()


def add_proxy(conn, ptype, host, port, secret=None, priority=0):
    try:
        conn.execute("""
            INSERT OR IGNORE INTO proxy_list (type, host, port, secret, priority, status)
            VALUES (?, ?, ?, ?, ?, 'active')
        """, (ptype, host, port, secret, priority))
        conn.commit()
        log.info("Proxy added: %s %s:%d", ptype, host, port)
    except sqlite3.Error as e:
        log.error("add_proxy error: %s", e)


def update_proxy_status(conn, ptype, host, port, status, latency_ms=None, fail_count=None):
    sets = ["status = ?", "last_check = ?"]
    params = [status, datetime.now(timezone.utc).isoformat()]
    if latency_ms is not None:
        sets.append("latency_ms = ?")
        params.append(latency_ms)
    if fail_count is not None:
        sets.append("fail_count = ?")
        params.append(fail_count)
    params.extend([ptype, host, port])
    conn.execute(f"UPDATE proxy_list SET {', '.join(sets)} WHERE type=? AND host=? AND port=?", params)
    conn.commit()


def get_active_proxies(conn):
    cur = conn.execute(
        "SELECT type, host, port, secret, priority FROM proxy_list WHERE status='active' ORDER BY priority ASC, latency_ms ASC"
    )
    return cur.fetchall()


def get_next_proxy(conn, current_host=None):
    """Get the next active proxy by priority, excluding the current one."""
    proxies = get_active_proxies(conn)
    for ptype, host, port, secret, priority in proxies:
        if host != current_host:
            return ptype, host, port, secret
    return None


# ---------------------------------------------------------------------------
# Proxy health check (real MTProto handshake)
# ---------------------------------------------------------------------------
async def check_proxy_health(client_factory, ptype, host, port, secret=None):
    """Try a real connection through the proxy. Return (ok, latency_ms, error)."""
    start = time.monotonic()
    try:
        if ptype == "mtproto":
            proxy = (host, port, secret) if secret else (host, port)
            conn_type = ConnectionTcpMTProxyRandomizedIntermediate
            test_client = client_factory(proxy=proxy, connection=conn_type)
        elif ptype == "socks5":
            import socks
            proxy = (socks.SOCKS5, host, port)
            test_client = client_factory(proxy=proxy)
        elif ptype == "http":
            import socks
            proxy = (socks.HTTP, host, port)
            test_client = client_factory(proxy=proxy)
        else:
            return False, 0, "unknown proxy type"

        await test_client.connect()
        latency = (time.monotonic() - start) * 1000
        await test_client.disconnect()
        return True, round(latency, 1), None
    except Exception as e:
        latency = (time.monotonic() - start) * 1000
        return False, round(latency, 1), str(e)


# ---------------------------------------------------------------------------
# Media download
# ---------------------------------------------------------------------------
async def download_media(client, msg, media_dir: Path):
    if not msg.media:
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
def make_row(msg, update_type, media_path=None, media_hash=None, edit_version=0):
    return {
        "chat_id": msg.chat_id,
        "message_id": msg.id,
        "edit_version": edit_version,
        "date_utc": msg.date.astimezone(timezone.utc).isoformat() if msg.date else datetime.now(timezone.utc).isoformat(),
        "sender_id": msg.sender_id,
        "text": msg.text if hasattr(msg, "text") else None,
        "caption": None,
        "media_path": media_path,
        "media_hash": media_hash,
        "update_type": update_type,
        "ingested_at": datetime.now(timezone.utc).isoformat(),
        "state": "pending",
    }


async def handle_new_message(client, conn, msg, media_dir):
    media_path, media_hash = await download_media(client, msg, media_dir)
    row = make_row(msg, "new", media_path, media_hash)
    inserted = enqueue(conn, row)
    if inserted:
        log.info("NEW msg %s/%s ingested", msg.chat_id, msg.id)
    else:
        log.debug("NEW msg %s/%s duplicate, skipped", msg.chat_id, msg.id)


async def handle_edit(client, conn, event, media_dir):
    msg = event.message
    media_path, media_hash = await download_media(client, msg, media_dir)
    cur = conn.execute(
        "SELECT COALESCE(MAX(edit_version), 0) FROM listener_queue WHERE chat_id=? AND message_id=?",
        (msg.chat_id, msg.id),
    )
    max_ver = cur.fetchone()[0]
    row = make_row(msg, "edit", media_path, media_hash, edit_version=max_ver + 1)
    inserted = enqueue(conn, row)
    if inserted:
        log.info("EDIT msg %s/%s v%d ingested", msg.chat_id, msg.id, row["edit_version"])
    else:
        log.debug("EDIT msg %s/%s duplicate, skipped", msg.chat_id, msg.id)


async def handle_delete(conn, chat_id, message_ids):
    now = datetime.now(timezone.utc).isoformat()
    for mid in message_ids:
        try:
            conn.execute("""
                INSERT OR IGNORE INTO listener_queue
                (chat_id, message_id, edit_version, date_utc, update_type, ingested_at, state)
                VALUES (?, ?, 0, ?, 'delete', ?, 'pending')
            """, (chat_id, mid, now, now))
            conn.commit()
            log.info("DELETE msg %s/%s ingested", chat_id, mid)
        except sqlite3.Error as e:
            log.error("delete enqueue error: %s", e)


# ---------------------------------------------------------------------------
# Catch-up on reconnect
# ---------------------------------------------------------------------------
async def catchup(client, conn, chat_id, media_dir):
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
        row = make_row(msg, "new", media_path, media_hash)
        if enqueue(conn, row):
            count += 1
    log.info("Catch-up complete: %d new messages", count)


# ---------------------------------------------------------------------------
# Proxy factory
# ---------------------------------------------------------------------------
def build_proxy_config():
    """Return (proxy_tuple, connection_class) or (None, None) for direct."""
    if not PROXY_TYPE or not PROXY_HOST or not PROXY_PORT:
        return None, None

    if PROXY_TYPE == "mtproto":
        if not PROXY_SECRET:
            log.warning("MTProto proxy requires a secret; falling back to direct")
            return None, None
        proxy = (PROXY_HOST, PROXY_PORT, PROXY_SECRET)
        return proxy, ConnectionTcpMTProxyRandomizedIntermediate
    elif PROXY_TYPE == "socks5":
        try:
            import socks
            proxy = (socks.SOCKS5, PROXY_HOST, PROXY_PORT)
            return proxy, None
        except ImportError:
            log.error("PySocks not installed; cannot use SOCKS5 proxy")
            return None, None
    elif PROXY_TYPE == "http":
        try:
            import socks
            proxy = (socks.HTTP, PROXY_HOST, PROXY_PORT)
            return proxy, None
        except ImportError:
            log.error("PySocks not installed; cannot use HTTP proxy")
            return None, None
    else:
        log.warning("Unknown proxy type: %s; using direct", PROXY_TYPE)
        return None, None


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
async def main():
    if not API_ID or not API_HASH:
        log.error("TELEGRAM_API_ID and TELEGRAM_API_HASH must be set in .env")
        sys.exit(1)

    SESSION_PATH.parent.mkdir(parents=True, exist_ok=True)
    conn = init_queue(QUEUE_DB_PATH)
    init_proxy_table(conn)
    media_dir = BASE_DIR / "data" / "media"

    # Register proxy from .env if configured
    if PROXY_TYPE and PROXY_HOST and PROXY_PORT:
        add_proxy(conn, PROXY_TYPE, PROXY_HOST, PROXY_PORT, PROXY_SECRET, priority=0)

    proxy, conn_class = build_proxy_config()

    client_kwargs = {
        "session": str(SESSION_PATH),
        "api_id": API_ID,
        "api_hash": API_HASH,
        "auto_reconnect": True,
        "connection_retries": 10,
        "retry_delay": 5,
    }
    if proxy:
        client_kwargs["proxy"] = proxy
        if conn_class:
            client_kwargs["connection"] = conn_class
        log.info("Using %s proxy: %s:%d", PROXY_TYPE, PROXY_HOST, PROXY_PORT)
    else:
        log.info("Using direct connection (no proxy)")

    client = TelegramClient(**client_kwargs)

    # Event handlers
    @client.on(events.NewMessage())
    async def on_new(event):
        await handle_new_message(client, conn, event.message, media_dir)

    @client.on(events.MessageEdited())
    async def on_edit(event):
        await handle_edit(client, conn, event, media_dir)

    @client.on(events.MessageDeleted())
    async def on_delete(event):
        chat_id = event.chat_id
        if chat_id is None and event.deleted_ids:
            # For private chats, chat_id may be None; try to resolve from DB
            pass
        await handle_delete(conn, chat_id, event.deleted_ids)

    log.info("Starting listener (read-only, no trading)...")
    await client.start()
    log.info("Logged in. Listening for messages...")

    # Reconnect handler: catch-up after reconnect
    @client.on(events.Raw)
    async def on_raw(update):
        pass  # Telethon handles reconnect internally; catch-up triggered below

    # Periodic catch-up check (every 5 minutes)
    async def periodic_catchup():
        while True:
            await asyncio.sleep(300)
            if TEST_CHANNEL_ID:
                try:
                    await catchup(client, conn, int(TEST_CHANNEL_ID), media_dir)
                except Exception as e:
                    log.warning("Periodic catch-up failed: %s", e)

    asyncio.create_task(periodic_catchup())

    # Initial catch-up for TEST_CHANNEL_ID
    if TEST_CHANNEL_ID:
        try:
            await catchup(client, conn, int(TEST_CHANNEL_ID), media_dir)
        except Exception as e:
            log.warning("Initial catch-up failed: %s", e)

    # Proxy health check loop (every 60s)
    async def proxy_health_loop():
        while True:
            await asyncio.sleep(60)
            proxies = get_active_proxies(conn)
            for ptype, host, port, secret, priority in proxies:
                ok, latency, err = await check_proxy_health(
                    lambda **kw: TelegramClient("health_check", API_ID, API_HASH, **kw),
                    ptype, host, port, secret,
                )
                if ok:
                    update_proxy_status(conn, ptype, host, port, "active", latency, 0)
                    log.info("Proxy %s %s:%d OK (%.1f ms)", ptype, host, port, latency)
                else:
                    cur = conn.execute(
                        "SELECT fail_count FROM proxy_list WHERE type=? AND host=? AND port=?",
                        (ptype, host, port),
                    ).fetchone()
                    fc = (cur[0] if cur else 0) + 1
                    if fc >= 3:
                        update_proxy_status(conn, ptype, host, port, "quarantined", latency, fc)
                        log.warning("Proxy %s %s:%d QUARANTINED after %d failures: %s", ptype, host, port, fc, err)
                    else:
                        update_proxy_status(conn, ptype, host, port, "active", latency, fc)
                        log.warning("Proxy %s %s:%d check failed (%d/3): %s", ptype, host, port, fc, err)

    asyncio.create_task(proxy_health_loop())

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
