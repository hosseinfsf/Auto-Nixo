"""Authenticated asyncio TCP server for the existing NixoLink MQL5 EA."""
from __future__ import annotations

import asyncio
import hmac
import itertools
import logging
import math
import time
from dataclasses import dataclass, field
from typing import Awaitable, Callable

from .mt5_protocol import Mt5Message

log = logging.getLogger(__name__)
EventHandler = Callable[[str, dict[str, str]], Awaitable[None] | None]
SUPPORTED_COMMANDS = {
    "OPEN", "MODIFY", "CLOSE", "CLOSE_ALL", "CANCEL",
    "GET_SYMBOLS", "GET_SYMBOL_INFO", "GET_ACCOUNT", "GET_POSITIONS",
    "GET_RATES", "GET_BARS", "GET_CALENDAR", "GET_RISK_PER_LOT",
}


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
        if not 0 <= int(port) < 65536:
            raise ValueError("port must be between 0 and 65535")
        if auth_timeout <= 0:
            raise ValueError("auth_timeout must be positive")
        self.host, self.port, self.token = host, int(port), token
        self.dry_run, self.on_event, self.auth_timeout = dry_run, on_event, auth_timeout
        self.server: asyncio.AbstractServer | None = None
        self.connections: dict[int, Connection] = {}
        # Bind pending replies to the exact socket, not merely its login. A
        # reconnect can replace a login while the old socket is still closing.
        self.pending: dict[str, tuple[Connection, asyncio.Future]] = {}
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
        if c.writer.is_closing():
            raise ConnectionError("MT5 socket is closing")
        async with c.lock:
            c.writer.write(msg.encode())
            await c.writer.drain()

    async def _client(self, reader, writer):
        c = Connection(reader, writer)
        login = None
        peer = writer.get_extra_info("peername")
        try:
            raw = await asyncio.wait_for(reader.readline(), self.auth_timeout)
            if len(raw) > 65536:
                raise ValueError("oversized authentication frame")
            first = Mt5Message.decode(raw)
            if first is None or first.command != "AUTH" or not hmac.compare_digest(
                first.fields.get("TOKEN", ""), self.token
            ):
                await self._send(c, Mt5Message({"CMD": "AUTH_FAIL"}))
                return
            await self._send(c, Mt5Message({"CMD": "AUTH_OK"}))
            log.info("NixoLink authenticated: %s", peer)

            while raw := await reader.readline():
                if len(raw) > 65536:
                    raise ValueError("oversized MT5 frame")
                msg = Mt5Message.decode(raw)
                if msg is None:
                    continue
                c.last_seen = time.monotonic()
                cmd, fields = msg.command, dict(msg.fields)
                if c.login is not None:
                    fields.setdefault("LOGIN", str(c.login))
                if cmd == "HB":
                    await self._send(c, Mt5Message({"CMD": "HB"}))
                    continue
                if cmd == "ACCOUNT":
                    new_login = int(fields.get("LOGIN", "0") or 0)
                    if new_login > 0:
                        login = new_login
                        previous = self.connections.get(login)
                        c.login, c.account = login, fields
                        self.connections[login] = c
                        if previous and previous is not c:
                            previous.writer.close()
                req = fields.get("REQ_ID")
                pending = self.pending.get(req) if req else None
                if pending and pending[0] is c:
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
                if owner is c:
                    self.pending.pop(req, None)
                    if not future.done():
                        future.set_exception(ConnectionError("MT5 connection lost"))
            writer.close()
            try:
                await writer.wait_closed()
            except Exception:
                pass

    async def request(self, login: int, command: str, fields=None, *, timeout=5.0):
        command = str(command).upper()
        if command not in SUPPORTED_COMMANDS:
            raise ValueError(f"unsupported NixoLink command: {command}")
        if command == "OPEN" and self.dry_run:
            raise PermissionError("OPEN blocked: dry_run=true")
        if timeout <= 0:
            raise ValueError("timeout must be positive")
        supplied = dict(fields or {})
        reserved = {"CMD", "REQ_ID"} & {str(k).upper() for k in supplied}
        if reserved:
            raise ValueError("fields cannot override CMD or REQ_ID")
        c = self.connections.get(int(login))
        if c is None or c.writer.is_closing():
            raise ConnectionError(f"MT5 login {login} disconnected")
        req = str(next(self.ids))
        future = asyncio.get_running_loop().create_future()
        self.pending[req] = (c, future)
        payload = {"CMD": command, "REQ_ID": req}
        payload.update({str(k): str(v) for k, v in supplied.items()})
        try:
            await self._send(c, Mt5Message(payload))
            return await asyncio.wait_for(future, timeout)
        finally:
            self.pending.pop(req, None)

    async def send_open(self, login: int, fields: dict):
        if self.dry_run:
            raise PermissionError("Live trading disabled; dry_run=true")
        required = {"SYMBOL", "SIDE", "TYPE", "LOTS", "SL", "TP", "CLIENT_ORDER_ID"}
        missing = required - fields.keys()
        if missing:
            raise ValueError("missing OPEN fields: " + ", ".join(sorted(missing)))
        side = str(fields["SIDE"]).lower()
        order_type = str(fields["TYPE"]).lower()
        if side not in {"buy", "sell"}:
            raise ValueError("SIDE must be buy or sell")
        if order_type not in {"market", "limit", "stop"}:
            raise ValueError("TYPE must be market, limit or stop")
        try:
            lots = float(fields["LOTS"])
            sl = float(fields["SL"])
            entry = float(fields.get("ENTRY", 0) or 0)
            tp = float(fields["TP"])
        except (TypeError, ValueError) as exc:
            raise ValueError("LOTS, ENTRY and SL must be numeric") from exc
        if not all(math.isfinite(x) for x in (lots, sl, entry, tp)) or lots <= 0 or sl <= 0 or tp <= 0:
            raise ValueError("LOTS, SL and TP must be finite positive numbers")
        if entry > 0:
            if ((side == "buy" and (sl >= entry or tp <= entry)) or
                    (side == "sell" and (sl <= entry or tp >= entry))):
                raise ValueError("SL/TP geometry is invalid")
            if not math.isclose(abs(tp-entry), 3.0*abs(entry-sl), rel_tol=1e-6, abs_tol=1e-8):
                raise ValueError("TP must be exactly 3R from ENTRY")
        if order_type != "market" and entry <= 0:
            raise ValueError("pending orders require a positive ENTRY")
        if not str(fields["SYMBOL"]).strip() or not str(fields["CLIENT_ORDER_ID"]).strip():
            raise ValueError("SYMBOL and CLIENT_ORDER_ID are required")
        if entry > 0 and not math.isclose(abs(tp-entry), 3.0*abs(entry-sl), rel_tol=1e-6, abs_tol=1e-8):
            raise ValueError("TP must be exactly 3R from ENTRY")
        outgoing = dict(fields)
        outgoing.pop("TP", None)
        outgoing["TPS"] = str(tp)
        return await self.request(login, "OPEN", outgoing)
