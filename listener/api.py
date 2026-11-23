"""
NIXO Listener API — localhost HTTP server for the Management Panel.

Endpoints:
  GET  /api/listener/status   -> {running, pid, log, status}
  POST /api/listener/start    -> {message}
  POST /api/listener/stop     -> {message}
  GET  /api/proxy/list        -> {proxies: [...]}  (secrets masked)
  POST /api/proxy/add         -> {message}
  POST /api/proxy/test        -> {ok, latency, error}
  POST /api/proxy/remove      -> {message}
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
    conn = sqlite3.connect(str(DB_PATH))
    conn.row_factory = sqlite3.Row
    return conn


def _mask_secret(s):
    if not s:
        return None
    if len(s) <= 8:
        return "****"
    return s[:4] + "****" + s[-4:]


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

        elif path == "/api/proxy/list":
            conn = get_db()
            rows = conn.execute(
                "SELECT type, host, port, status, latency_ms, fail_count, priority FROM proxy_list ORDER BY priority ASC"
            ).fetchall()
            proxies = []
            for r in rows:
                d = dict(r)
                secret_row = conn.execute(
                    "SELECT secret FROM proxy_list WHERE type=? AND host=? AND port=?",
                    (d["type"], d["host"], d["port"]),
                ).fetchone()
                d["secret"] = _mask_secret(secret_row[0] if secret_row else None)
                proxies.append(d)
            conn.close()
            self._json({"proxies": proxies})

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

        elif path == "/api/proxy/add":
            conn = get_db()
            try:
                conn.execute(
                    "INSERT OR IGNORE INTO proxy_list (type, host, port, secret, priority, status) VALUES (?,?,?,?,?,?)",
                    (body["type"], body["host"], body["port"], body.get("secret"), 0, "active"),
                )
                conn.commit()
                self._json({"message": "Proxy added"})
            except Exception as e:
                self._json({"error": str(e)}, 400)
            finally:
                conn.close()

        elif path == "/api/proxy/test":
            import asyncio
            sys.path.insert(0, str(BASE_DIR))
            from listener import check_proxy_health
            ptype = body["type"]
            host = body["host"]
            port = body["port"]
            secret = body.get("secret")

            async def run_test():
                return await check_proxy_health(ptype, host, port, secret)

            try:
                ok, lat, err = asyncio.run(run_test())
                conn = get_db()
                if ok:
                    status = "active"
                    fc = 0
                else:
                    cur = conn.execute(
                        "SELECT fail_count FROM proxy_list WHERE type=? AND host=? AND port=?",
                        (ptype, host, port),
                    ).fetchone()
                    fc = (cur[0] if cur else 0) + 1
                    status = "quarantined" if fc >= 3 else "active"
                conn.execute(
                    "UPDATE proxy_list SET status=?, latency_ms=?, last_check=?, fail_count=? WHERE type=? AND host=? AND port=?",
                    (status, lat, __import__("datetime").datetime.now(__import__("datetime").timezone.utc).isoformat(), fc, ptype, host, port),
                )
                conn.commit()
                conn.close()
                self._json({"ok": ok, "latency": lat, "error": err, "fail_count": fc, "status": status})
            except Exception as e:
                self._json({"ok": False, "latency": 0, "error": str(e)})

        elif path == "/api/proxy/remove":
            conn = get_db()
            conn.execute(
                "DELETE FROM proxy_list WHERE type=? AND host=? AND port=?",
                (body["type"], body["host"], body["port"]),
            )
            conn.commit()
            conn.close()
            self._json({"message": "Proxy removed"})

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
