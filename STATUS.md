# STATUS

**Last updated:** 2026-11-24 — Phase 0 security cleanup complete.

## Honest status

| Check | Result | Where | Evidence |
|---|---|---|---|
| `git ls-files` (no secrets) | PASS | sandbox | `engine_config.json` no longer tracked |
| gitleaks full-history scan | PASS (0 findings) | sandbox | `reports/gitleaks-full-history.json` = `[]` |
| Pre-commit hook installed | PASS | sandbox | gitleaks 8.30.1 |
| Independent backup created | PASS | sandbox | `C:\Nixo-Backup\Auto-Nixo-backup-20261124-012327.git` |
| Old credentials purged from history | PASS | sandbox | `git grep` CLEAN for all 5 secrets |
| `python -m unittest discover -s tests` (engine_py) | PASS (65/65) | sandbox | Fixed Windows file-locking in `db.py` + `listener_consumer.py` |
| `dart analyze` (packages/core) | NOT RUN | needs Dart SDK | — |
| `dart analyze` (apps/engine) | NOT RUN | needs Dart SDK | — |
| `dart test` (packages/core) | NOT RUN | needs Dart SDK | — |
| `dart test` (apps/engine) | NOT RUN | needs Dart SDK | — |
| `flutter analyze` (apps/ui) | NOT RUN | needs Flutter SDK | — |
| MQL5 EA compile | NOT RUN | needs MetaEditor | existing log: 0 errors, 2 warnings |
| Live Telegram / MT5 | NOT RUN | needs credentials + terminal | — |

## Evidence table

| Item | Code exists | Unit-tested | Verified live | Evidence |
|---|---|---|---|---|
| Core models (`models.dart`) | yes | yes | no | core suite |
| Digit normalizer (`normalizer.dart`) | yes | yes | no | core suite |
| Classifier (`classifier.dart`) | yes | yes | no | core suite |
| Text parser (`text_parser.dart`) | yes | yes | no | core suite |
| Symbol mapping (`symbol_mapping.dart`) | yes | yes | no | core suite |
| Validator (`validator.dart`) | yes | yes | no | core suite |
| Sizing (`sizing.dart`) | yes | yes | no | core suite |
| SL/TP resolver (`sl_tp.dart`) | yes | yes | no | core suite |
| Roulette (`roulette.dart`) | yes | yes | no | core + engine suite |
| Limits (`limits.dart`) | yes | yes | no | core suite |
| SQLite store (`db.dart`) | yes | yes | no | persistence suite |
| TDLib FFI client (`tdlib_client.dart`) | yes | no | no | needs tdjson.dll |
| Telegram source (`telegram_source.dart`) | yes | no | no | needs live session |
| Proxy manager (`proxy_manager.dart`) | yes | no | no | not run |
| Input registry (`input_registry.dart`) | yes | yes | no | engine suite |
| Pipeline (`pipeline.dart`) | yes | yes | no | engine suite (incl. demo integration) |
| MT5 link server (`link_server.dart`) | yes | no | no | needs MT5 terminal |
| MT5 protocol (`protocol.dart`) | yes | yes | no | engine suite |
| HTTP API + web dashboard (`http_api.dart`, `web/`) | yes | no | no | needs a browser session |
| Watchdog (`watchdog.dart`) | yes | no | no | not run |
| Replay tool (`replay.dart`) | yes | yes | no | engine suite |
| Engine entrypoint (`bin/engine.dart`) | yes | no | no | not run |
| MQL5 EA (`NixoLink.mq5`) | yes | no | no | never compiled in MetaEditor |
| Flutter UI (`apps/ui/`) | yes | no | no | never built |
| Web dashboard (`apps/engine/web/`) | yes | no | no | served by the engine, not opened in a browser |
| Python engine (`engine_py/nixo_engine/`) | yes | yes (65/65) | no | full test suite |
| Telegram listener (`listener/`) | yes | no | no | needs live Telegram |

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
- Dart SDK / Flutter SDK not available in sandbox.

## How to run on the owner's PC

```sh
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