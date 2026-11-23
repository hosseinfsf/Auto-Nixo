"""Codec and command builders for the existing NixoLink MQL5 TCP protocol."""
from __future__ import annotations

from dataclasses import dataclass
from typing import Mapping


def escape(value: object) -> str:
    text = str(value)
    return (text.replace("%", "%25").replace("|", "%7C")
                .replace("=", "%3D").replace("\r", "%0D").replace("\n", "%0A")
                .replace("\x00", ""))


def unescape(value: str) -> str:
    out: list[str] = []
    i = 0
    while i < len(value):
        if value[i] == "%" and i + 2 < len(value):
            try:
                out.append(chr(int(value[i + 1:i + 3], 16)))
                i += 3
                continue
            except ValueError:
                pass
        out.append(value[i])
        i += 1
    return "".join(out)


@dataclass(frozen=True)
class Mt5Message:
    fields: Mapping[str, str]

    def encode(self) -> bytes:
        line = "|".join(f"{key}={escape(value)}" for key, value in self.fields.items())
        return (line + "\n").encode("utf-8")

    @classmethod
    def decode(cls, line: str | bytes) -> "Mt5Message | None":
        if isinstance(line, bytes):
            line = line.decode("utf-8", errors="replace")
        line = line.replace("\x00", "").replace("\r", "").strip()
        if not line:
            return None
        fields: dict[str, str] = {}
        for part in line.split("|"):
            key, sep, value = part.partition("=")
            if sep and key:
                fields[key] = unescape(value)
        return cls(fields)

    @property
    def command(self) -> str:
        return self.fields.get("CMD", "")


def open_order(*, req_id: str, symbol: str, side: str, order_type: str,
               lots: float, entry: float, sl: float, tps: list[float],
               client_order_id: str, magic: int = 0, comment: str = "NX",
               deviation: int = 20, filling: str = "symbol") -> Mt5Message:
    if side.lower() not in {"buy", "sell"}:
        raise ValueError("side must be buy or sell")
    if not symbol or lots <= 0 or sl <= 0 or not client_order_id:
        raise ValueError("symbol, positive lots, SL and client_order_id are required")
    if order_type.lower() not in {"market", "limit", "stop"}:
        raise ValueError("unsupported order type")
    fields = {
        "CMD": "OPEN", "REQ_ID": req_id, "SYMBOL": symbol,
        "SIDE": side.lower(), "TYPE": order_type.lower(), "LOTS": lots,
        "ENTRY": entry, "SL": sl, "TPS": ",".join(map(str, tps)),
        "CLIENT_ORDER_ID": client_order_id, "MAGIC": magic,
        "COMMENT": comment, "DEVIATION": deviation, "FILLING": filling,
    }
    return Mt5Message({k: str(v) for k, v in fields.items()})


def authenticated(token: str) -> Mt5Message:
    if len(token) < 16:
        raise ValueError("MT5 auth token must contain at least 16 characters")
    return Mt5Message({"CMD": "AUTH", "TOKEN": token})
