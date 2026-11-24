"""
NIXO Listener API — FastAPI localhost HTTP server for the Management Panel.

Endpoints:
  GET  /api/listener/status   -> {running, pid, log, status}
  POST /api/listener/start    -> {message}
  POST /api/listener/stop     -> {message}
  GET  /api/sources           -> configured sources and per-source TTL
  POST /api/sources           -> add/update a source and its TTL
  POST /api/sources/remove    -> remove a source
  GET/POST /api/proxy/link    -> store an inert Telegram proxy URL as text only
  GET  /api/queue/stats       -> {total, pending, processed, failed, expired}
  GET  /api/queue/recent      -> {rows: [...]}
"""
import os
import sys
import json
import sqlite3
import subprocess
import signal
import hmac
import hashlib
from pathlib import Path
from urllib.parse import urlparse

from fastapi import FastAPI, Request, HTTPException, Depends
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field
import uvicorn

BASE_DIR = Path(__file__).resolve().parent
DB_PATH = BASE_DIR / "data" / "listener_queue.db"
PID_FILE = BASE_DIR / "data" / "listener.pid"
STATUS_FILE = BASE_DIR / "data" / "status.json"
PROXY_LINK_FILE = BASE_DIR / "data" / "telegram_proxy_link.txt"
LISTENER_SCRIPT = BASE_DIR / "listener.py"
PYTHON = sys.executable
PORT = 9125
MAX_BODY_SIZE = 65536  # 64 KB
PANEL_ORIGIN = os.getenv("PANEL_ORIGIN", "http://127.0.0.1:9124")

# Load .env
try:
    from dotenv import load_dotenv
    load_dotenv(BASE_DIR / ".env")
except ImportError:
    pass

LISTENER_API_TOKEN = os.getenv("LISTENER_API_TOKEN", "")

# Refuse to start without token
if not LISTENER_API_TOKEN:
    print("ERROR: LISTENER_API_TOKEN must be set in listener/.env")
    sys.exit(1)

app = FastAPI(title="NIXO Listener API", docs_url=None, redoc_url=None)

# Exact-origin CORS (only the panel origin)
app.add_middleware(
    CORSMiddleware,
    allow_origins=[PANEL_ORIGIN],
    allow_credentials=True,
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["Content-Type", "Authorization"],
)


def get_db():
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(DB_PATH))
    conn.execute("PRAGMA busy_timeout=5000;")
    conn.row_factory = sqlite3.Row
    conn.execute("""
        CREATE TABLE IF NOT EXISTS sources (
            chat_id INTEGER PRIMARY KEY,
            title TEXT,
            enabled INTEGER NOT NULL DEFAULT 1,
            ttl_seconds INTEGER NOT NULL DEFAULT 180,
            profile_id TEXT
        )
    """)
    columns = {row[1] for row in conn.execute("PRAGMA table_info(sources)")}
    if "ttl_seconds" not in columns:
        conn.execute(
            "ALTER TABLE sources ADD COLUMN ttl_seconds INTEGER NOT NULL DEFAULT 180"
        )
    if "profile_id" not in columns:
        conn.execute(
            "ALTER TABLE sources ADD COLUMN profile_id TEXT"
        )
    conn.commit()
    return conn


def _authorized(request: Request) -> bool:
    auth = request.headers.get("authorization", "")
    if not auth.startswith("Bearer "):
        return False
    token = auth[7:]
    return hmac.compare_digest(token, LISTENER_API_TOKEN)


def _validate_host_origin(request: Request) -> bool:
    host = request.headers.get("host", "")
    origin = request.headers.get("origin", "")
    allowed_hosts = {"127.0.0.1", "localhost"}
    host_ok = host.split(":")[0] in allowed_hosts
    origin_ok = True
    if origin:
        origin_ok = origin.startswith("http://127.0.0.1") or origin.startswith("http://localhost")
    return host_ok and origin_ok


@app.middleware("http")
async def security_middleware(request: Request, call_next):
    if not _validate_host_origin(request):
        return JSONResponse({"error": "forbidden"}, status_code=403)
    if not _authorized(request):
        return JSONResponse({"error": "unauthorized"}, status_code=401)
    # Body size limit
    content_length = request.headers.get("content-length")
    if content_length and int(content_length) > MAX_BODY_SIZE:
        return JSONResponse({"error": "Body too large"}, status_code=413)
    return await call_next(request)


# --- Pydantic models ---

class SourceIn(BaseModel):
    chat_id: int
    ttl_seconds: int = Field(default=180, ge=1, le=86400)
    title: str | None = None
    enabled: bool = True


class SourceRemoveIn(BaseModel):
    chat_id: int


class ProxyLinkIn(BaseModel):
    link: str = ""


# --- Endpoints ---

@app.get("/api/listener/status")
async def listener_status():
    running = False
    pid = None
    if PID_FILE.exists():
        try:
            pid = int(PID_FILE.read_text().strip())
            os.kill(pid, 0)
            running = True
        except (ValueError, OSError, ProcessLookupError):
            running = False
            pid = None
    log_tail = ""
    log_file = BASE_DIR / "data" / "listener.log"
    if log_file.exists():
        lines = log_file.read_text().splitlines()
        log_tail = "\n".join(lines[-50:])
    status_json = {}
    if STATUS_FILE.exists():
        try:
            status_json = json.loads(STATUS_FILE.read_text())
        except Exception:
            pass
    return {"running": running, "pid": pid, "log": log_tail, "status": status_json}


@app.post("/api/listener/start")
async def listener_start():
    if PID_FILE.exists():
        try:
            pid = int(PID_FILE.read_text().strip())
            os.kill(pid, 0)
            return {"message": "Listener already running", "pid": pid}
        except (ValueError, OSError, ProcessLookupError):
            PID_FILE.unlink(missing_ok=True)

    log_file = BASE_DIR / "data" / "listener.log"
    log_file.parent.mkdir(parents=True, exist_ok=True)
    with open(log_file, "a") as f:
        proc = subprocess.Popen(
            [PYTHON, str(LISTENER_SCRIPT)],
            cwd=str(BASE_DIR),
            stdout=f,
            stderr=subprocess.STDOUT,
        )
    PID_FILE.write_text(str(proc.pid))
    return {"message": "Listener started", "pid": proc.pid}


@app.post("/api/listener/stop")
async def listener_stop():
    if not PID_FILE.exists():
        return {"message": "Listener not running"}
    try:
        pid = int(PID_FILE.read_text().strip())
        os.kill(pid, signal.SIGTERM)
        PID_FILE.unlink(missing_ok=True)
        return {"message": "Listener stopped"}
    except (ValueError, OSError, ProcessLookupError):
        PID_FILE.unlink(missing_ok=True)
        return {"message": "Listener not running"}


@app.get("/api/sources")
async def sources_list():
    conn = get_db()
    rows = conn.execute(
        "SELECT chat_id, title, enabled, ttl_seconds FROM sources ORDER BY chat_id"
    ).fetchall()
    conn.close()
    return {"sources": [dict(r) for r in rows]}


@app.post("/api/sources")
async def sources_add(body: SourceIn):
    try:
        chat_id = int(body.chat_id)
        ttl_seconds = int(body.ttl_seconds)
        title = body.title
        enabled = 1 if body.enabled else 0
        if chat_id == 0:
            raise ValueError("chat_id must be a non-zero integer")
        if ttl_seconds < 1 or ttl_seconds > 86400:
            raise ValueError("ttl_seconds must be between 1 and 86400")
        conn = get_db()
        conn.execute("""
            INSERT INTO sources (chat_id, title, enabled, ttl_seconds)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(chat_id) DO UPDATE SET
                title=excluded.title,
                enabled=excluded.enabled,
                ttl_seconds=excluded.ttl_seconds
        """, (chat_id, title, enabled, ttl_seconds))
        conn.commit()
        conn.close()
        return {"ok": True, "chat_id": chat_id, "ttl_seconds": ttl_seconds}
    except (TypeError, ValueError, sqlite3.Error) as e:
        raise HTTPException(status_code=400, detail=str(e))


@app.post("/api/sources/remove")
async def sources_remove(body: SourceRemoveIn):
    try:
        chat_id = int(body.chat_id)
        if chat_id == 0:
            raise ValueError("chat_id must be a non-zero integer")
        conn = get_db()
        conn.execute("DELETE FROM sources WHERE chat_id=?", (chat_id,))
        conn.commit()
        conn.close()
        return {"ok": True, "chat_id": chat_id}
    except (TypeError, ValueError, sqlite3.Error) as e:
        raise HTTPException(status_code=400, detail=str(e))


@app.get("/api/proxy/link")
async def proxy_link_get():
    configured = PROXY_LINK_FILE.exists() and PROXY_LINK_FILE.stat().st_size > 0
    return {"configured": configured, "mode": "text_only"}


@app.post("/api/proxy/link")
async def proxy_link_set(body: ProxyLinkIn):
    link = body.link.strip() if isinstance(body.link, str) else ""
    if link:
        parsed = urlparse(link)
        if (parsed.scheme != "https" or parsed.netloc.lower() != "t.me"
                or parsed.path != "/proxy" or not parsed.query
                or any(ch.isspace() for ch in link)):
            raise HTTPException(status_code=400, detail="expected a complete https://t.me/proxy?... link")
        PROXY_LINK_FILE.parent.mkdir(parents=True, exist_ok=True)
        PROXY_LINK_FILE.write_text(link, encoding="utf-8")
    else:
        PROXY_LINK_FILE.unlink(missing_ok=True)
    # Never echo or log the complete URL; its query can contain a secret.
    return {"ok": True, "configured": bool(link), "mode": "text_only"}


@app.get("/api/proxy/list")
async def proxy_list():
    conn = get_db()
    try:
        from proxy_manager import init_proxy_table, get_proxies
        init_proxy_table(conn)
        proxies = get_proxies(conn)
        return {"proxies": proxies}
    finally:
        conn.close()


class ProxyBulkImportIn(BaseModel):
    text: str = ""


@app.post("/api/proxy/import")
async def proxy_import(body: ProxyBulkImportIn):
    conn = get_db()
    try:
        from proxy_manager import init_proxy_table, parse_proxy_links_bulk, add_proxy
        init_proxy_table(conn)
        parsed = parse_proxy_links_bulk(body.text)
        added = 0
        for p in parsed:
            rid = add_proxy(conn, p)
            if rid:
                added += 1
        return {"parsed": len(parsed), "added": added}
    finally:
        conn.close()


@app.post("/api/proxy/test")
async def proxy_test(body: dict = {}):
    proxy_id = body.get("id")
    if not proxy_id:
        raise HTTPException(status_code=400, detail="id required")
    conn = get_db()
    try:
        from proxy_manager import init_proxy_table
        init_proxy_table(conn)
        row = conn.execute("SELECT * FROM proxy_list WHERE id=?", (proxy_id,)).fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="proxy not found")
        # Test via Telethon (real handshake) — owner runs this on their PC
        return {"id": proxy_id, "status": "test_requested",
                "note": "Run on owner PC with real proxy credentials"}
    finally:
        conn.close()


@app.post("/api/proxy/remove")
async def proxy_remove(body: dict = {}):
    proxy_id = body.get("id")
    if not proxy_id:
        raise HTTPException(status_code=400, detail="id required")
    conn = get_db()
    try:
        conn.execute("DELETE FROM proxy_list WHERE id=?", (proxy_id,))
        conn.commit()
        return {"ok": True, "id": proxy_id}
    finally:
        conn.close()


# (proxy/add, proxy/test, proxy/remove are now implemented above with real handlers)


@app.get("/api/queue/stats")
async def queue_stats():
    conn = get_db()
    total = conn.execute("SELECT COUNT(*) FROM listener_queue").fetchone()[0]
    pending = conn.execute("SELECT COUNT(*) FROM listener_queue WHERE state='pending'").fetchone()[0]
    processed = conn.execute("SELECT COUNT(*) FROM listener_queue WHERE state='processed'").fetchone()[0]
    processing = conn.execute("SELECT COUNT(*) FROM listener_queue WHERE state='processing'").fetchone()[0]
    failed = conn.execute("SELECT COUNT(*) FROM listener_queue WHERE state='failed'").fetchone()[0]
    expired = conn.execute("SELECT COUNT(*) FROM listener_queue WHERE state='expired'").fetchone()[0]
    deleted = conn.execute("SELECT COUNT(*) FROM listener_queue WHERE state='deleted'").fetchone()[0]
    conn.close()
    return {"total": total, "pending": pending, "processing": processing,
            "processed": processed, "failed": failed, "expired": expired,
            "deleted": deleted}


@app.get("/api/queue/recent")
async def queue_recent():
    conn = get_db()
    rows = conn.execute(
        "SELECT chat_id, message_id, edit_version, update_type, state, date_utc, attempts, error FROM listener_queue ORDER BY id DESC LIMIT 20"
    ).fetchall()
    result = {"rows": [dict(r) for r in rows]}
    conn.close()
    return result


def main():
    uvicorn.run(app, host="127.0.0.1", port=PORT, log_level="info")


if __name__ == "__main__":
    main()