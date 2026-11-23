"""Fail-closed parser for common Telegram FX/metals trade messages.

The implementation is intentionally deterministic: ambiguous direction, symbol,
entry, stop-loss or target fields are rejected rather than guessed. It is
inspired by common patterns documented by MIT-licensed community projects,
but is an independent implementation for Nixo's safety requirements.
"""
from __future__ import annotations

import re
from dataclasses import asdict, dataclass
from typing import Literal

_SIDE_MAP = {"BUY": "buy", "LONG": "buy", "SELL": "sell", "SHORT": "sell"}
_DIGITS = str.maketrans("۰۱۲۳۴۵۶۷۸۹٠١٢٣٤٥٦٧٨٩", "01234567890123456789")
_SYMBOL_ALIASES = {
    "GOLD": "XAUUSD", "XAU/USD": "XAUUSD", "XAUUSD": "XAUUSD",
    "SILVER": "XAGUSD", "XAG/USD": "XAGUSD", "XAGUSD": "XAGUSD",
    "BTC/USD": "BTCUSD", "BTCUSD": "BTCUSD",
    "ETH/USD": "ETHUSD", "ETHUSD": "ETHUSD",
    "US30": "US30", "NAS100": "NAS100", "US100": "NAS100",
    "SPX500": "SPX500", "GER40": "GER40",
}
_SYMBOL_PATTERN = re.compile(
    r"(?<![A-Z0-9])(?:XAU\s*/\s*USD|XAG\s*/\s*USD|BTC\s*/\s*USD|ETH\s*/\s*USD|"
    r"XAUUSD|XAGUSD|BTCUSD|ETHUSD|GOLD|SILVER|US30|NAS100|US100|SPX500|GER40|"
    r"(?:EUR|USD|GBP|JPY|CHF|CAD|AUD|NZD|SGD|HKD|NOK|SEK|MXN|TRY|ZAR|PLN|CZK|HUF){2})(?![A-Z0-9])", re.I
)
_SIDE_PATTERN = re.compile(r"(?<![A-Z])(BUY|SELL|LONG|SHORT)(?![A-Z])", re.I)
_NUMBER = r"\d+(?:[.,]\d+)?"
_SL_PATTERN = re.compile(
    r"(?<![A-Z0-9])(?:SL|S/L|STOP\s*LOSS|STOPLOSS)\s*[:=@-]?\s*(" + _NUMBER + r")",
    re.I,
)
_TP_PATTERN = re.compile(
    r"(?<![A-Z0-9])(?:TP\s*\d*|T/P\s*\d*|TAKE\s*PROFIT\s*\d*|TARGET\s*\d*)"
    r"\s*[:=@-]?\s*(" + _NUMBER + r")", re.I
)
_ENTRY_PATTERN = re.compile(
    r"(?<![A-Z0-9])(?:ENTRY|ENTRIES|@|PRICE)\s*[:=@-]?\s*("
    + _NUMBER + r")(?:\s*(?:-|–|TO|~)\s*(" + _NUMBER + r"))?", re.I
)
_SIDE_ENTRY_PATTERN = re.compile(
    r"(?<![A-Z])(?:BUY|SELL|LONG|SHORT)\s+(?:(?:LIMIT|STOP|NOW)\s+)?@?\s*("
    + _NUMBER + r")(?:\s*(?:-|–|TO|~)\s*(" + _NUMBER + r"))?", re.I
)


class SignalParseError(ValueError):
    """Raised when a message is not a complete, unambiguous trade signal."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


@dataclass(frozen=True)
class TradeSignal:
    side: Literal["buy", "sell"]
    symbol: str
    entry_low: float | None
    entry_high: float | None
    stop_loss: float
    take_profits: tuple[float, ...]
    order_type: Literal["market", "limit", "stop"]
    raw_text: str

    def to_dict(self) -> dict:
        result = asdict(self)
        result["take_profits"] = list(self.take_profits)
        return result


def _normalise_text(text: str) -> str:
    text = text.translate(_DIGITS).replace("\u066b", ".").replace("\u066c", ",")
    # Normalize common Persian/Arabic punctuation without altering raw_text.
    return text.replace("：", ":").replace("，", ",").replace("٫", ".")


def _number(value: str) -> float:
    # A single comma is accepted as decimal separator; thousands grouping is
    # deliberately unsupported because it is ambiguous in chat messages.
    if "," in value and "." in value:
        raise SignalParseError("ambiguous_number", f"ambiguous numeric value: {value}")
    try:
        number = float(value.replace(",", "."))
    except ValueError as exc:
        raise SignalParseError("invalid_number", f"invalid numeric value: {value}") from exc
    if not number > 0 or number == float("inf") or number != number:
        raise SignalParseError("invalid_number", "prices must be finite and positive")
    return number


def parse_signal(text: str) -> TradeSignal:
    """Parse a standalone trade signal; raises SignalParseError on uncertainty."""
    if not isinstance(text, str) or not text.strip():
        raise SignalParseError("empty_message", "message is empty")
    clean = _normalise_text(text).upper()

    sides = { _SIDE_MAP[m.group(1)] for m in _SIDE_PATTERN.finditer(clean) }
    if len(sides) != 1:
        raise SignalParseError("ambiguous_or_missing_side", "exactly one trade direction is required")
    side = next(iter(sides))

    symbols_found = []
    for match in _SYMBOL_PATTERN.finditer(clean):
        token = re.sub(r"\s+", "", match.group(0))
        token = token.replace("/", "")
        normalized = _SYMBOL_ALIASES.get(token, _SYMBOL_ALIASES.get(match.group(0), token))
        if normalized not in symbols_found:
            symbols_found.append(normalized)
    if len(symbols_found) != 1:
        raise SignalParseError("ambiguous_or_missing_symbol", "exactly one supported symbol is required")
    symbol = symbols_found[0]

    sl_matches = list(_SL_PATTERN.finditer(clean))
    if len(sl_matches) != 1:
        raise SignalParseError("missing_or_ambiguous_sl", "exactly one stop-loss value is required")
    stop_loss = _number(sl_matches[0].group(1))

    tp_matches = list(_TP_PATTERN.finditer(clean))
    # Source TP is optional; Nixo derives exactly one 3R target from entry and SL.
    take_profits = tuple(_number(m.group(1)) for m in tp_matches)
    if len(set(take_profits)) != len(take_profits):
        raise SignalParseError("duplicate_tp", "duplicate take-profit values are not accepted")

    entry_matches = list(_ENTRY_PATTERN.finditer(clean))
    if not entry_matches:
        entry_matches = list(_SIDE_ENTRY_PATTERN.finditer(clean))
    if len(entry_matches) > 1:
        raise SignalParseError("ambiguous_entry", "multiple entry zones were found")
    entry_low = entry_high = None
    if entry_matches:
        entry_low = _number(entry_matches[0].group(1))
        entry_high = _number(entry_matches[0].group(2)) if entry_matches[0].group(2) else entry_low
        entry_low, entry_high = min(entry_low, entry_high), max(entry_low, entry_high)

    # A market instruction is accepted only when it explicitly says NOW/MARKET
    # and does not provide an entry price.
    order_type = "market"
    if entry_matches:
        order_type = "limit" if re.search(r"\bLIMIT\b", clean) else (
            "stop" if re.search(r"\bSTOP\b", clean) and not re.search(r"\bSTOP\s*LOSS\b", clean)
            else "limit"
        )
    elif not re.search(r"\b(?:NOW|MARKET)\b", clean):
        raise SignalParseError("missing_entry", "entry price or explicit NOW/MARKET instruction is required")

    reference = entry_low
    if reference is not None:
        if side == "buy" and stop_loss >= reference:
            raise SignalParseError("sl_wrong_side", "BUY stop-loss must be below entry")
        if side == "sell" and stop_loss <= reference:
            raise SignalParseError("sl_wrong_side", "SELL stop-loss must be above entry")
    # Parsed source targets are retained for audit but are not execution targets.
    ordered = tuple(sorted(take_profits, reverse=(side == "sell")))
    return TradeSignal(
        side=side, symbol=symbol, entry_low=entry_low, entry_high=entry_high,
        stop_loss=stop_loss, take_profits=ordered, order_type=order_type,
        raw_text=text,
    )
