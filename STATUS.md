# STATUS

**Last updated:** at first commit (M0–M3 code scaffold).

## ⚠️ Honest status — read first

**NOTHING in this repository has been compiled or run yet.**

- The authoring sandbox has **no Dart/Flutter SDK** and **no Windows / MT5 /
  live Telegram**, and external downloads are blocked.
- Therefore: no `dart pub get`, no `dart analyze`, no `dart test`, no
  `flutter build` has ever executed.
- The MQL5 EA (`mt5/NixoLink.mq5`) has **never been compiled in MetaEditor**.
- All Dart tests under `packages/core/test` and `apps/engine/test` are written
  but have **not been run**.

Do not treat any "code exists" row as working. Everything must be built and
tested on the owner's Windows PC.

## Evidence table

| Item | Code exists | Unit-tested | Verified live | Evidence |
|---|---|---|---|---|
| Core models (`models.dart`) | ✅ | ❌ | ❌ | not run |
| Digit normalizer (`normalizer.dart`) | ✅ | ❌ | ❌ | test written, not run |
| Classifier (`classifier.dart`) | ✅ | ❌ | ❌ | test written, not run |
| Text parser (`text_parser.dart`) | ✅ | ❌ | ❌ | test written, not run |
| Symbol mapping (`symbol_mapping.dart`) | ✅ | ❌ | ❌ | not run |
| Validator (`validator.dart`) | ✅ | ❌ | ❌ | test written, not run |
| Sizing (`sizing.dart`) | ✅ | ❌ | ❌ | test written, not run |
| SL/TP resolver (`sl_tp.dart`) | ✅ | ❌ | ❌ | not run |
| Roulette (`roulette.dart`) | ✅ | ❌ | ❌ | test written, not run |
| Limits (`limits.dart`) | ✅ | ❌ | ❌ | not run |
| SQLite store (`db.dart`) | ✅ | ❌ | ❌ | not run |
| TDLib FFI client (`tdlib_client.dart`) | ✅ | ❌ | ❌ | not run; needs tdjson.dll |
| Telegram source (`telegram_source.dart`) | ✅ | ❌ | ❌ | not run |
| Proxy manager (`proxy_manager.dart`) | ✅ | ❌ | ❌ | not run |
| Input registry (`input_registry.dart`) | ✅ | ❌ | ❌ | not run |
| Pipeline (`pipeline.dart`) | ✅ | ❌ | ❌ | test written, not run |
| MT5 link server (`link_server.dart`) | ✅ | ❌ | ❌ | not run |
| MT5 protocol (`protocol.dart`) | ✅ | ❌ | ❌ | test written, not run |
| HTTP API + webhook (`http_api.dart`) | ✅ | ❌ | ❌ | not run |
| Watchdog (`watchdog.dart`) | ✅ | ❌ | ❌ | not run |
| Replay tool (`replay.dart`) | ✅ | ❌ | ❌ | not run |
| Engine entrypoint (`bin/engine.dart`) | ✅ | ❌ | ❌ | not run |
| MQL5 EA (`NixoLink.mq5`) | ✅ | ❌ | ❌ | never compiled in MetaEditor |
| Flutter UI (`apps/ui/`) | ✅ | ❌ | ❌ | never built |
| CI workflow (`.github/workflows/ci.yml`) | ✅ | — | — | to be run on first push |

Legend: ✅ = present, ❌ = not done.

## Roulette: deviations from docs/ROULETTE_SPEC.md

The `packages/core/lib/src/risk/roulette.dart` port is **not** an exact match
to `docs/ROULETTE_SPEC.md`. The deviations below are intentional but have **not
been approved by the owner** (they were carried over from the reference engine's
own documented deviations). They must be reviewed and approved before M5.

| # | Spec (EA) | `roulette.dart` | Why / status |
|---|---|---|---|
| 1 | Order roulette win: `step = min(cap, step + 1)` | Order win doubles: `step = step*2` (capped at max) | Faster growth; NOT approved |
| 2 | `InpRouletteTrigger` default = 4.00% | default `triggerPct = 3.0` | Configurable; NOT approved |
| 3 | `InpMaxStep` default = 50 | default `maxSteps = 3` | Safer default; NOT approved |
| 4 | `InpBaseRisk` default = 0.25% | default `baseRiskPct = 0.5` | Configurable; NOT approved |
| 5 | `InpMaxOrderCount` default = 8 | default `maxOrderCount = 8` | matches |
| 6 | State in MT5 Global Variables | State in SQLite (`roulette_states`) | engine persistence |
| 7 | Flat zone `|profit| < 0.15*riskMoney` | same flat zone | matches |
| 8 | `count > TP levels` not specified in EA | reuses last TP | safest default |
| 9 | `InpSplitRiskAcrossOrders=true` keeps batch risk near one trade | full risk per sub-order | configurable |

**Owner action required:** approve or adjust deviations #1–#4 before M5.

## What is NOT verified (requires live environment)

- Live Telegram login/session/updates/edits/photos (S1).
- MT5 socket round-trip, reconnect, and MetaEditor compile (S2).
- Image OCR/vision accuracy (S3).
- Real proxy failover (S4).
- OrderCalcProfit lot math vs hand calc (S5).
- TradingView webhook reachable through a tunnel (S6).
- Any Flutter build or Dart test run.

## How to run on the owner's PC

```
# core
cd packages/core && dart pub get && dart analyze && dart test
# engine
cd apps/engine && dart pub get && dart analyze && dart test
cd ../.. && dart run apps/engine/bin/engine.dart --self-test
# UI
cd apps/ui && flutter pub get && flutter analyze
# EA: compile mt5/NixoLink.mq5 in MetaEditor (F7)
```
