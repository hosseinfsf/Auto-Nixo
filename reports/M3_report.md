# M3 Report — Parsing, Validation, Profiles, Risk, UI

**Phase:** M3 — **Date:** (build date) — **Commit:** (fill)

## Checklist items completed (code written)
- Classifier (signal/management/recap/noise; Persian+English; digit
  normalization; avoids false positives on "be").
- Text parser with per-input profile; any symbol; entry ranges; multiple TPs;
  market vs limit/stop.
- Deterministic validator (geometry, R:R, entry vs quote, spread, market open).
- Per-input profile model (`SourceProfile`), sizing, SL/TP policies, roulette,
  global + per-input limits.
- UI (Flutter): dashboard, sources, proxy, live feed, settings, kill switch.

## Evidence (pending — run on PC)
```
cd packages/core && dart test
cd apps/engine && dart test
```

## Items NOT verified
- Live quote validation (needs MT5 link).
- UI build (`flutter run -d windows`).

## Next phase plan
M4: images + TradingView webhook + sample library + AI structure.
