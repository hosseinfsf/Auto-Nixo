"""
NIXO Listener — Proxy manager (ready-made: Telethon set_proxy + python-socks).

Supports bulk paste import of tg://proxy, https://t.me/proxy, tg://socks,
https://t.me/socks links. Parses with stdlib urllib.parse (no custom parser).
Secrets are stored in the proxy_list table and masked in all API responses.
"""
import sqlite3
import time
import urllib.parse
from pathlib import Path

# ---------------------------------------------------------------------------
# Proxy link parsing (stdlib urllib.parse only)
# ---------------------------------------------------------------------------

def parse_proxy_link(link: str) -> dict | None:
    """Parse a single proxy link into {type, host, port, secret, username, password}.

    Supports:
      tg://proxy?server=...&port=...&secret=...
      https://t.me/proxy?server=...&port=...&secret=...
      tg://socks?server=...&port=...&user=...&pass=...
      https://t.me/socks?server=...&port=...&user=...&pass=...
    """
    link = link.strip()
    if not link:
        return None
    parsed = urllib.parse.urlparse(link)
    # Normalise scheme
    if parsed.scheme in ("tg", "https", "http"):
        pass
    else:
        return None

    # Determine proxy type from path or scheme
    path = parsed.path.lower().rstrip("/")
    query = urllib.parse.parse_qs(parsed.query)

    if "proxy" in path or "proxy" in (parsed.netloc or "").lower():
        ptype = "mtproto"
    elif "socks" in path or "socks" in (parsed.netloc or "").lower():
        ptype = "socks5"
    else:
        # Try to infer from query params
        if "secret" in query:
            ptype = "mtproto"
        elif "user" in query or "pass" in query:
            ptype = "socks5"
        else:
            return None

    # Extract server/port from query (t.me/proxy?server=...&port=...)
    # or from netloc (tg://proxy/server:port?secret=...)
    server = None
    port = None

    if "server" in query:
        server = query["server"][0]
    elif parsed.hostname:
        server = parsed.hostname

    if "port" in query:
        try:
            port = int(query["port"][0])
        except (ValueError, IndexError):
            return None
    elif parsed.port:
        port = parsed.port

    if not server or not port:
        return None

    result = {"type": ptype, "host": server, "port": port}

    if ptype == "mtproto":
        secret = query.get("secret", [None])[0]
        if not secret:
            return None
        result["secret"] = secret
    else:
        result["username"] = query.get("user", [None])[0]
        result["password"] = query.get("pass", [None])[0]

    return result


def parse_proxy_links_bulk(text: str) -> list[dict]:
    """Parse multiple proxy links from a text block (one per line or space-separated)."""
    results = []
    # Split on whitespace and newlines
    for token in text.split():
        token = token.strip()
        if not token:
            continue
        # Handle tg:// and https:// links
        if token.startswith("tg://") or token.startswith("https://t.me/") or token.startswith("http://t.me/"):
            parsed = parse_proxy_link(token)
            if parsed:
                results.append(parsed)
        elif token.startswith("tg://socks") or token.startswith("tg://proxy"):
            parsed = parse_proxy_link(token)
            if parsed:
                results.append(parsed)
    return results


# ---------------------------------------------------------------------------
# Proxy database operations
# ---------------------------------------------------------------------------

def init_proxy_table(conn: sqlite3.Connection):
    conn.execute("""
        CREATE TABLE IF NOT EXISTS proxy_list (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            type TEXT NOT NULL,
            host TEXT NOT NULL,
            port INTEGER NOT NULL,
            secret TEXT,
            username TEXT,
            password TEXT,
            priority INTEGER NOT NULL DEFAULT 100,
            status TEXT NOT NULL DEFAULT 'untested',
            latency_ms REAL,
            last_check TEXT,
            fail_count INTEGER NOT NULL DEFAULT 0,
            quarantined_until TEXT,
            enabled INTEGER NOT NULL DEFAULT 1,
            UNIQUE(type, host, port, secret)
        )
    """)
    conn.commit()


def mask_secret(secret: str | None) -> str:
    if not secret:
        return ""
    if len(secret) <= 8:
        return "****"
    return secret[:4] + "****" + secret[-4:]


def add_proxy(conn, proxy: dict, priority: int = 100) -> int | None:
    try:
        cur = conn.execute("""
            INSERT OR IGNORE INTO proxy_list
            (type, host, port, secret, username, password, priority, status, enabled)
            VALUES (?, ?, ?, ?, ?, ?, ?, 'untested', 1)
        """, (
            proxy["type"], proxy["host"], proxy["port"],
            proxy.get("secret"), proxy.get("username"), proxy.get("password"),
            priority,
        ))
        conn.commit()
        return cur.lastrowid if cur.rowcount > 0 else None
    except sqlite3.Error:
        return None


def get_proxies(conn, enabled_only: bool = True) -> list[dict]:
    query = "SELECT * FROM proxy_list"
    if enabled_only:
        query += " WHERE enabled=1"
    query += " ORDER BY priority ASC, id ASC"
    rows = conn.execute(query).fetchall()
    result = []
    for r in rows:
        d = dict(r)
        d["secret_masked"] = mask_secret(d.get("secret"))
        # Never expose full secret in list
        if d.get("secret"):
            d["secret"] = mask_secret(d["secret"])
        if d.get("password"):
            d["password"] = "****"
        result.append(d)
    return result


def get_active_proxy(conn) -> dict | None:
    """Get the highest-priority non-quarantined enabled proxy."""
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    row = conn.execute("""
        SELECT * FROM proxy_list
        WHERE enabled=1 AND status != 'dead'
          AND (quarantined_until IS NULL OR quarantined_until <= ?)
        ORDER BY priority ASC, fail_count ASC, id ASC
        LIMIT 1
    """, (now,)).fetchone()
    if row:
        d = dict(row)
        d["secret_masked"] = mask_secret(d.get("secret"))
        return d
    return None


def update_proxy_status(conn, proxy_id: int, status: str, latency_ms: float | None = None):
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    conn.execute("""
        UPDATE proxy_list SET status=?, latency_ms=?, last_check=?,
        fail_count = CASE WHEN ? IN ('ok','active') THEN 0 ELSE fail_count + 1 END
        WHERE id=?
    """, (status, latency_ms, now, status, proxy_id))
    conn.commit()


def quarantine_proxy(conn, proxy_id: int, duration_seconds: int = 300):
    now = time.time()
    until = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now + duration_seconds))
    conn.execute("""
        UPDATE proxy_list SET status='quarantined', quarantined_until=? WHERE id=?
    """, (until, proxy_id))
    conn.commit()


def to_telethon_proxy(proxy: dict) -> tuple | None:
    """Convert a proxy dict to Telethon's proxy tuple format."""
    if proxy["type"] == "mtproto":
        # Telethon MTProto proxy: (host, port, secret_bytes)
        secret = proxy.get("secret", "")
        # Strip 'ee' prefix for FakeTLS, decode hex
        if secret.startswith("ee"):
            secret = secret[2:]
        try:
            secret_bytes = bytes.fromhex(secret)
        except ValueError:
            secret_bytes = secret.encode()
        return (proxy["host"], proxy["port"], secret_bytes)
    elif proxy["type"] in ("socks5", "socks4", "http"):
        # Telethon SOCKS/HTTP proxy: (host, port, username, password)
        return (proxy["host"], proxy["port"],
                proxy.get("username"), proxy.get("password"))
    return None


def build_proxy_config(proxy: dict | None) -> dict | None:
    """Build a Telethon-compatible proxy config dict."""
    if proxy is None:
        return None
    if proxy["type"] == "mtproto":
        return {
            "proxy_type": "mtproto",
            "addr": proxy["host"],
            "port": proxy["port"],
            "secret": proxy.get("secret", ""),
        }
    return {
        "proxy_type": proxy["type"],
        "addr": proxy["host"],
        "port": proxy["port"],
        "username": proxy.get("username"),
        "password": proxy.get("password"),
    }
