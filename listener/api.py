"""
NIXO Listener API — localhost HTTP server for the Management Panel.

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
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse

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


def get_db():
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(DB_PATH))
    conn.row_factory = sqlite3.Row
    conn.execute("""
        CREATE TABLE IF NOT EXISTS sources (
            chat_id INTEGER PRIMARY KEY,
            title TEXT,
            enabled INTEGER NOT NULL DEFAULT 1,
            ttl_seconds INTEGER NOT NULL DEFAULT 180
        )
    """)
    columns = {row[1] for row in conn.execute("PRAGMA table_info(sources)")}
    if "ttl_seconds" not in columns:
        conn.execute(
            "ALTER TABLE sources ADD COLUMN ttl_seconds INTEGER NOT NULL DEFAULT 180"
        )
    conn.commit()
    return conn


class Handler(BaseHTTPRequestHandler):
    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", PANEL_ORIGIN)
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization")
        self.send_header("Vary", "Origin")

    def _json(self, data, status=200):
        body = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self._cors()
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self):
        length = int(self.headers.get("Content-Length", 0))
        if length > MAX_BODY_SIZE:
            raise ValueError("Body too large")
        if length:
            raw = self.rfile.read(length)
            return json.loads(raw)
        return {}

    def _authorized(self):
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Bearer "):
            return False
        token = auth[7:]
        return hmac.compare_digest(token, LISTENER_API_TOKEN)

    def _validate_host_origin(self):
        host = self.headers.get("Host", "")
        origin = self.headers.get("Origin", "")
        allowed_hosts = {"127.0.0.1", "localhost"}
        host_ok = host.split(":")[0] in allowed_hosts
        origin_ok = True
        if origin:
            origin_ok = origin.startswith("http://127.0.0.1") or origin.startswith("http://localhost")
        return host_ok and origin_ok

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.end_headers()

    def do_GET(self):
        if not self._validate_host_origin():
            self._json({"error": "forbidden"}, 403)
            return
        if not self._authorized():
            self._json({"error": "unauthorized"}, 401)
            return
        path = urlparse(self.path).path

        if path == "/api/listener/status":
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
            self._json({"running": running, "pid": pid, "log": log_tail, "status": status_json})

        elif path == "/api/sources":
            conn = get_db()
            rows = conn.execute(
                "SELECT chat_id, title, enabled, ttl_seconds FROM sources ORDER BY chat_id"
            ).fetchall()
            conn.close()
            self._json({"sources": [dict(r) for r in rows]})

        elif path == "/api/proxy/link":
            configured = PROXY_LINK_FILE.exists() and PROXY_LINK_FILE.stat().st_size > 0
            self._json({"configured": configured, "mode": "text_only"})

        elif path == "/api/proxy/list":
            self._json({
                "error": "proxy activation, routing and testing are disabled",
                "mode": "text_only",
            }, 410)

        elif path == "/api/queue/stats":
            conn = get_db()
            total = conn.execute("SELECT COUNT(*) FROM listener_queue").fetchone()[0]
            pending = conn.execute("SELECT COUNT(*) FROM listener_queue WHERE state='pending'").fetchone()[0]
            processed = conn.execute("SELECT COUNT(*) FROM listener_queue WHERE state='processed'").fetchone()[0]
            failed = conn.execute("SELECT COUNT(*) FROM listener_queue WHERE state='failed'").fetchone()[0]
            expired = conn.execute("SELECT COUNT(*) FROM listener_queue WHERE state='expired'").fetchone()[0]
            conn.close()
            self._json({"total": total, "pending": pending, "processed": processed, "failed": failed, "expired": expired})

        elif path == "/api/queue/recent":
            conn = get_db()
            rows = conn.execute(
                "SELECT chat_id, message_id, edit_version, update_type, state, date_utc FROM listener_queue ORDER BY id DESC LIMIT 20"
            ).fetchall()
            self._json({"rows": [dict(r) for r in rows]})
            conn.close()

        else:
            self._json({"error": "not found"}, 404)

    def do_POST(self):
        if not self._validate_host_origin():
            self._json({"error": "forbidden"}, 403)
            return
        if not self._authorized():
            self._json({"error": "unauthorized"}, 401)
            return
        path = urlparse(self.path).path
        try:
            body = self._read_body()
        except Exception as e:
            self._json({"error": str(e)}, 400)
            return

        if path == "/api/listener/start":
            if PID_FILE.exists():
                try:
                    pid = int(PID_FILE.read_text().strip())
                    os.kill(pid, 0)
                    self._json({"message": "Listener already running", "pid": pid})
                    return
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
            self._json({"message": "Listener started", "pid": proc.pid})

        elif path == "/api/listener/stop":
            if not PID_FILE.exists():
                self._json({"message": "Listener not running"})
                return
            try:
                pid = int(PID_FILE.read_text().strip())
                os.kill(pid, signal.SIGTERM)
                PID_FILE.unlink(missing_ok=True)
                self._json({"message": "Listener stopped"})
            except (ValueError, OSError, ProcessLookupError):
                PID_FILE.unlink(missing_ok=True)
                self._json({"message": "Listener not running"})

        elif path == "/api/sources":
            try:
                chat_id = int(body.get("chat_id", 0))
                ttl_seconds = int(body.get("ttl_seconds", 180))
                title = body.get("title")
                enabled = 1 if body.get("enabled", True) is True else 0
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
                self._json({"ok": True, "chat_id": chat_id, "ttl_seconds": ttl_seconds})
            except (TypeError, ValueError, sqlite3.Error) as e:
                self._json({"error": str(e)}, 400)

        elif path == "/api/sources/remove":
            try:
                chat_id = int(body.get("chat_id", 0))
                if chat_id == 0:
                    raise ValueError("chat_id must be a non-zero integer")
                conn = get_db()
                conn.execute("DELETE FROM sources WHERE chat_id=?", (chat_id,))
                conn.commit()
                conn.close()
                self._json({"ok": True, "chat_id": chat_id})
            except (TypeError, ValueError, sqlite3.Error) as e:
                self._json({"error": str(e)}, 400)

        elif path == "/api/proxy/link":
            link = body.get("link", "")
            if not isinstance(link, str):
                self._json({"error": "link must be a string"}, 400)
                return
            link = link.strip()
            if link:
                parsed = urlparse(link)
                if (parsed.scheme != "https" or parsed.netloc.lower() != "t.me"
                        or parsed.path != "/proxy" or not parsed.query
                        or any(ch.isspace() for ch in link)):
                    self._json({"error": "expected a complete https://t.me/proxy?... link"}, 400)
                    return
                PROXY_LINK_FILE.parent.mkdir(parents=True, exist_ok=True)
                PROXY_LINK_FILE.write_text(link, encoding="utf-8")
            else:
                PROXY_LINK_FILE.unlink(missing_ok=True)
            # Never echo or log the complete URL; its query can contain a secret.
            self._json({"ok": True, "configured": bool(link), "mode": "text_only"})

        elif path in ("/api/proxy/add", "/api/proxy/test", "/api/proxy/remove"):
            self._json({
                "error": "proxy activation, routing and testing are disabled; use /api/proxy/link for text-only storage",
                "mode": "text_only",
            }, 410)

        else:
            self._json({"error": "not found"}, 404)

    def log_message(self, format, *args):
        pass


def main():
    server = HTTPServer(("127.0.0.1", PORT), Handler)
    print(f"Listener API running on http://127.0.0.1:{PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("Shutting down...")
        server.shutdown()


if __name__ == "__main__":
    main()
