"""Authenticated asyncio TCP server for the existing NixoLink MQL5 EA."""
from __future__ import annotations
import asyncio, hmac, itertools, logging, time
from dataclasses import dataclass, field
from typing import Awaitable, Callable
from .mt5_protocol import Mt5Message

log = logging.getLogger(__name__)
EventHandler = Callable[[str, dict[str, str]], Awaitable[None] | None]

@dataclass(eq=False)
class Connection:
    reader: asyncio.StreamReader
    writer: asyncio.StreamWriter
    login: int | None = None
    account: dict[str, str] = field(default_factory=dict)
    last_seen: float = field(default_factory=time.monotonic)
    lock: asyncio.Lock = field(default_factory=asyncio.Lock)

class NixoLinkServer:
    """Loopback-only TCP server; authentication and protocol match NixoLink.mq5."""
    def __init__(self, host: str, port: int, token: str, *, dry_run: bool = True,
                 on_event: EventHandler | None = None, auth_timeout: float = 3.0):
        if host not in {"127.0.0.1", "::1", "localhost"}:
            raise ValueError("NixoLink server must bind to loopback")
        if not token or len(token) < 16:
            raise ValueError("api_token must contain at least 16 characters")
        self.host, self.port, self.token = host, port, token
        self.dry_run, self.on_event, self.auth_timeout = dry_run, on_event, auth_timeout
        self.server: asyncio.AbstractServer | None = None
        self.connections: dict[int, Connection] = {}
        self.pending: dict[str, tuple[int, asyncio.Future]] = {}
        self.ids = itertools.count(1)

    async def start(self):
        self.server = await asyncio.start_server(self._client, self.host, self.port)
        if self.server.sockets:
            self.port = self.server.sockets[0].getsockname()[1]

    async def stop(self):
        if self.server:
            self.server.close()
            await self.server.wait_closed()
            self.server = None
        for c in tuple(self.connections.values()):
            c.writer.close()
        self.connections.clear()
        for _, future in self.pending.values():
            if not future.done():
                future.set_exception(ConnectionError("server stopped"))
        self.pending.clear()

    async def _send(self, c: Connection, msg: Mt5Message):
        async with c.lock:
            c.writer.write(msg.encode())
            await c.writer.drain()

    async def _client(self, reader, writer):
        c = Connection(reader, writer)
        login = None
        peer = writer.get_extra_info("peername")
        try:
            raw = await asyncio.wait_for(reader.readline(), self.auth_timeout)
            first = Mt5Message.decode(raw)
            if first is None or first.command != "AUTH" or not hmac.compare_digest(
                first.fields.get("TOKEN", ""), self.token
            ):
                await self._send(c, Mt5Message({"CMD": "AUTH_FAIL"}))
                return
            await self._send(c, Mt5Message({"CMD": "AUTH_OK"}))
            log.info("NixoLink authenticated: %s", peer)
            while raw := await reader.readline():
                if len(raw) > 1_048_576:
                    raise ValueError("oversized MT5 frame")
                msg = Mt5Message.decode(raw)
                if msg is None:
                    continue
                c.last_seen = time.monotonic()
                cmd, fields = msg.command, dict(msg.fields)
                if cmd == "HB":
                    await self._send(c, Mt5Message({"CMD": "HB"}))
                    continue
                if cmd == "ACCOUNT":
                    login = int(fields.get("LOGIN", "0") or 0)
                    if login > 0:
                        previous = self.connections.get(login)
                        if previous and previous is not c:
                            previous.writer.close()
                        c.login, c.account = login, fields
                        self.connections[login] = c
                req = fields.get("REQ_ID")
                pending = self.pending.get(req) if req else None
                if pending and pending[0] == login:
                    self.pending.pop(req, None)
                    if not pending[1].done():
                        pending[1].set_result(msg)
                if self.on_event:
                    result = self.on_event(cmd, fields)
                    if asyncio.iscoroutine(result):
                        await result
        except (asyncio.TimeoutError, ConnectionError, asyncio.IncompleteReadError):
            log.warning("NixoLink connection ended: %s", peer)
        except Exception:
            log.exception("NixoLink handler error: %s", peer)
        finally:
            if login is not None and self.connections.get(login) is c:
                self.connections.pop(login, None)
            for req, (owner, future) in tuple(self.pending.items()):
                if owner == login:
                    self.pending.pop(req, None)
                    if not future.done():
                        future.set_exception(ConnectionError("MT5 connection lost"))
            writer.close()
            try:
                await writer.wait_closed()
            except Exception:
                pass

    async def request(self, login: int, command: str, fields=None, *, timeout=5.0):
        if command == "OPEN" and self.dry_run:
            raise PermissionError("OPEN blocked: dry_run=true")
        c = self.connections.get(int(login))
        if c is None or c.writer.is_closing():
            raise ConnectionError(f"MT5 login {login} disconnected")
        req = str(next(self.ids))
        future = asyncio.get_running_loop().create_future()
        self.pending[req] = (int(login), future)
        payload = {"CMD": command, "REQ_ID": req}
        payload.update({k: str(v) for k, v in (fields or {}).items()})
        try:
            await self._send(c, Mt5Message(payload))
            return await asyncio.wait_for(future, timeout)
        finally:
            self.pending.pop(req, None)

    async def send_open(self, login: int, fields: dict):
        if self.dry_run:
            raise PermissionError("Live trading disabled; dry_run=true")
        required = {"SYMBOL", "SIDE", "TYPE", "LOTS", "SL", "CLIENT_ORDER_ID"}
        missing = required - fields.keys()
        if missing:
            raise ValueError("missing OPEN fields: " + ", ".join(sorted(missing)))
        return await self.request(login, "OPEN", fields)
