"""
NIXO Listener API — localhost HTTP server for the Management Panel.

Endpoints:
  GET  /api/listener/status   -> {running, pid, log}
  POST /api/listener/start    -> {message}
  POST /api/listener/stop     -> {message}
  GET  /api/proxy/list        -> {proxies: [...]}
  POST /api/proxy/add         -> {message}
  POST /api/proxy/test        -> {ok, latency, error}
  POST /api/proxy/remove      -> {message}
  GET  /api/queue/stats       -> {total, pending, processed, failed}
  GET  /api/queue/recent      -> {rows: [...]}
"""
import os
import sys
import json
import sqlite3
import subprocess
import signal
from pathlib import Path
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse

BASE_DIR = Path(__file__).resolve().parent
DB_PATH = BASE_DIR / "data" / "listener_queue.db"
LISTENER_API_TOKEN = os.getenv("LISTENER_API_TOKEN", "")
LISTENER_SCRIPT = BASE_DIR / "listener.py"
PYTHON = sys.executable
PORT = 9125

# Track listener process
_listener_proc = None


def get_db():
    conn = sqlite3.connect(str(DB_PATH))
    conn.row_factory = sqlite3.Row
    return conn


class Handler(BaseHTTPRequestHandler):
    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")

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
        if length:
            return json.loads(self.rfile.read(length))
        return {}

    def _authorized(self):
        if not LISTENER_API_TOKEN:
            return True  # no token configured = open (dev mode)
        auth = self.headers.get("Authorization", "")
        return auth == "Bearer " + LISTENER_API_TOKEN

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.end_headers()

    def do_GET(self):
        if not self._authorized():
            self._json({"error": "unauthorized"}, 401)
            return
        path = urlparse(self.path).path
        if path == "/api/listener/status":
            global _listener_proc
            running = _listener_proc is not None and _listener_proc.poll() is None
            pid = _listener_proc.pid if running else None
            log_tail = ""
            log_file = BASE_DIR / "data" / "listener.log"
            if log_file.exists():
                lines = log_file.read_text().splitlines()
                log_tail = "\n".join(lines[-50:])
            self._json({"running": running, "pid": pid, "log": log_tail})

        elif path == "/api/proxy/list":
            conn = get_db()
            rows = conn.execute(
                "SELECT type, host, port, status, latency_ms, fail_count FROM proxy_list ORDER BY priority ASC"
            ).fetchall()
            proxies = [dict(r) for r in rows]
            conn.close()
            self._json({"proxies": proxies})

        elif path == "/api/queue/stats":
            conn = get_db()
            total = conn.execute("SELECT COUNT(*) FROM listener_queue").fetchone()[0]
            pending = conn.execute("SELECT COUNT(*) FROM listener_queue WHERE state='pending'").fetchone()[0]
            processed = conn.execute("SELECT COUNT(*) FROM listener_queue WHERE state='processed'").fetchone()[0]
            failed = conn.execute("SELECT COUNT(*) FROM listener_queue WHERE state='failed'").fetchone()[0]
            conn.close()
            self._json({"total": total, "pending": pending, "processed": processed, "failed": failed})

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
        global _listener_proc
        if not self._authorized():
            self._json({"error": "unauthorized"}, 401)
            return
        path = urlparse(self.path).path
        body = self._read_body()

        if path == "/api/listener/start":
            if _listener_proc is not None and _listener_proc.poll() is None:
                self._json({"message": "Listener already running"})
                return
            log_file = BASE_DIR / "data" / "listener.log"
            log_file.parent.mkdir(parents=True, exist_ok=True)
            with open(log_file, "a") as f:
                _listener_proc = subprocess.Popen(
                    [PYTHON, str(LISTENER_SCRIPT)],
                    cwd=str(BASE_DIR),
                    stdout=f,
                    stderr=subprocess.STDOUT,
                )
            self._json({"message": "Listener started", "pid": _listener_proc.pid})

        elif path == "/api/listener/stop":
            if _listener_proc is None or _listener_proc.poll() is not None:
                self._json({"message": "Listener not running"})
                return
            _listener_proc.terminate()
            try:
                _listener_proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                _listener_proc.kill()
            self._json({"message": "Listener stopped"})

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
            from listener.listener import check_proxy_health
            ptype = body["type"]
            host = body["host"]
            port = body["port"]
            secret = body.get("secret")

            def factory(**kw):
                from telethon import TelegramClient
                return TelegramClient("hc", int(os.getenv("TELEGRAM_API_ID", "0")), os.getenv("TELEGRAM_API_HASH", ""), **kw)

            async def run_test():
                return await check_proxy_health(factory, ptype, host, port, secret)

            try:
                ok, lat, err = asyncio.run(run_test())
                # Update DB
                conn = get_db()
                if ok:
                    status = "active"
                    fc = 0
                else:
                    # Increment fail count
                    cur = conn.execute(
                        "SELECT fail_count FROM proxy_list WHERE type=? AND host=? AND port=?",
                        (ptype, host, port),
                    ).fetchone()
                    fc = (cur[0] if cur else 0) + 1
                    if fc >= 3:
                        status = "quarantined"
                        log_msg = "Proxy quarantined after %d failures" % fc
                    else:
                        status = "active"
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
        pass  # suppress default logging


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
