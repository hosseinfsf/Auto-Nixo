# STATUS

**Last updated:** dashboard + persistence + recovery + demo integration pass.

## Honest status

Everything below was **run on the owner's Windows PC** (Dart 3.x on PATH).
Nothing here was executed in the authoring sandbox.

| Check | Result | Where |
|---|---|---|
| `dart analyze` (packages/core) | No issues found | owner PC |
| `dart analyze` (apps/engine) | No issues found | owner PC |
| `dart test` (packages/core) | 46 passed | owner PC |
| `dart test` (apps/engine) | 50 passed | owner PC |
| `flutter analyze` (apps/ui) | not run | — |
| MQL5 EA compile | not run (needs MetaEditor) | — |
| Live Telegram / MT5 | not run (needs credentials + terminal) | — |

## Evidence table

| Item | Code exists | Unit-tested | Verified live | Evidence |
|---|---|---|---|---|
| Core models (`models.dart`) | ✅ | ✅ | ❌ | core suite |
| Digit normalizer (`normalizer.dart`) | ✅ | ✅ | ❌ | core suite |
| Classifier (`classifier.dart`) | ✅ | ✅ | ❌ | core suite |
| Text parser (`text_parser.dart`) | ✅ | ✅ | ❌ | core suite |
| Symbol mapping (`symbol_mapping.dart`) | ✅ | ✅ | ❌ | core suite |
| Validator (`validator.dart`) | ✅ | ✅ | ❌ | core suite |
| Sizing (`sizing.dart`) | ✅ | ✅ | ❌ | core suite |
| SL/TP resolver (`sl_tp.dart`) | ✅ | ✅ | ❌ | core suite |
| Roulette (`roulette.dart`) | ✅ | ✅ | ❌ | core + engine suite |
| Limits (`limits.dart`) | ✅ | ✅ | ❌ | core suite |
| SQLite store (`db.dart`) | ✅ | ✅ | ❌ | persistence suite |
| TDLib FFI client (`tdlib_client.dart`) | ✅ | ❌ | ❌ | needs tdjson.dll |
| Telegram source (`telegram_source.dart`) | ✅ | ❌ | ❌ | needs live session |
| Proxy manager (`proxy_manager.dart`) | ✅ | ❌ | ❌ | not run |
| Input registry (`input_registry.dart`) | ✅ | ✅ | ❌ | engine suite |
| Pipeline (`pipeline.dart`) | ✅ | ✅ | ❌ | engine suite (incl. demo integration) |
| MT5 link server (`link_server.dart`) | ✅ | ❌ | ❌ | needs MT5 terminal |
| MT5 protocol (`protocol.dart`) | ✅ | ✅ | ❌ | engine suite |
| HTTP API + web dashboard (`http_api.dart`, `web/`) | ✅ | ❌ | ❌ | needs a browser session |
| Watchdog (`watchdog.dart`) | ✅ | ❌ | ❌ | not run |
| Replay tool (`replay.dart`) | ✅ | ✅ | ❌ | engine suite |
| Engine entrypoint (`bin/engine.dart`) | ✅ | ❌ | ❌ | not run |
| MQL5 EA (`NixoLink.mq5`) | ✅ | ❌ | ❌ | never compiled in MetaEditor |
| Flutter UI (`apps/ui/`) | ✅ | ❌ | ❌ | never built |
| Web dashboard (`apps/engine/web/`) | ✅ | ❌ | ❌ | served by the engine, not opened in a browser |

Legend: ✅ = done, ❌ = not done.

## Roulette: deviations from docs/ROULETTE_SPEC.md

Still **not** an exact match. These remain open and unapproved:

| # | Spec (EA) | `roulette.dart` | Status |
|---|---|---|---|
| 1 | Order win: `step = min(cap, step + 1)` | `step = step*2` capped | OPEN |
| 2 | `InpRouletteTrigger` = 4.00% | `triggerPct = 3.0` | OPEN |
| 3 | `InpMaxStep` = 50 | `maxSteps = 3` | OPEN |
| 4 | `InpBaseRisk` = 0.25% | `baseRiskPct = 0.5` | OPEN |
| 5 | `InpMaxOrderCount` = 8 | 8 | matches |
| 6 | State in MT5 globals | SQLite `roulette_states` | by design |
| 7 | Flat zone `|profit| < 0.15*riskMoney` | same | matches |

Sizing default risk is **0.25%** when a profile omits `risk_percent`
(`pipeline.dart`), covered by a test.

## Not verified (needs live environment)

- Live Telegram login/session/updates/edits/photos.
- MT5 socket round-trip, reconnect, MetaEditor compile.
- Image OCR/vision accuracy.
- Real proxy failover.
- OrderCalcProfit lot math against a live broker.
- TradingView webhook through a tunnel.
- Any browser session against the dashboard.
- Any Flutter build.

## How to run on the owner's PC

```
# one-click
Start_Nixo.bat        # starts the engine, waits for /health, opens the dashboard
Health_Check.bat      # /health + /status + listeners
Stop_Nixo.bat         # stops the engine; state stays in data/nixo.db

# manual
cd packages/core && dart pub get && dart analyze && dart test
cd ../../apps/engine && dart pub get && dart analyze && dart test
cd ../.. && dart run apps/engine/bin/engine.dart --self-test
# EA: compile mt5/NixoLink.mq5 in MetaEditor (F7)
```

Dashboard: `http://127.0.0.1:9124/` (token via `engine_config.json` → `api_token`;
set `NIXO_TOKEN` for the BAT files).
