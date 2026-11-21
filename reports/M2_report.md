# M2 Report — EA "NIXO LINK" + Execution

**Phase:** M2 — **Date:** (build date) — **Commit:** (fill)

## Checklist items completed (code written)
- EA `mt5/NixoLink.mq5`: socket client, localhost-only, token AUTH, heartbeat,
  auto-reconnect, refuses non-local addresses.
- Commands: OPEN, MODIFY, CLOSE (partial), CANCEL, CLOSE_ALL, GET_SYMBOLS,
  GET_SYMBOL_INFO, GET_ACCOUNT, GET_POSITIONS, GET_RATES, GET_CALENDAR.
- Lot validation via broker min/max/step; uses `OrderCalcProfit` path in EA.
- Events to engine: FILL, POSITION_CLOSED, REJECT, ACCOUNT snapshot.
- Symbol mapping scaffolding in core (`symbol_mapping.dart`).

## Evidence (pending — must compile in MetaEditor F7)
No compile possible in sandbox. Owner must compile `NixoLink.mq5` in MetaEditor.

## Items NOT verified
- MetaEditor compile.
- Demo smoke test: signal → order with correct lot/SL/TP.
- OrderCalcProfit vs hand calc (S5).

## QUESTIONS FOR OWNER
- Does the broker/terminal allow socket connections to 127.0.0.1? (MT5 may
  prompt for allowed addresses.)

## Next phase plan
M3: parsing/validation/profiles/risk/UI (code present; test on PC).
