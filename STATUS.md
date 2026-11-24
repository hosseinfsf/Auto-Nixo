# STATUS

**Last updated:** 2026-11-24 — Dart/Flutter code removed; Python engine is the runtime.

## Honest status

| Check | Result | Where | Evidence |
|---|---|---|---|
| `git ls-files` (no secrets) | PASS | sandbox | `engine_config.json` no longer tracked |
| gitleaks full-history scan | PASS (0 findings) | sandbox | `reports/gitleaks-full-history.json` = `[]` |
| Pre-commit hook installed | PASS | sandbox | gitleaks 8.30.1 |
| Independent backup created | PASS | sandbox | `C:\Nixo-Backup\Auto-Nixo-backup-20261124-012327.git` |
| Old credentials purged from history | PASS | sandbox | `git grep` CLEAN for all 5 secrets |
| `python -m unittest discover -s tests` (engine_py) | PASS (65/65) | sandbox | Fixed Windows file-locking in `db.py` + `listener_consumer.py` |
| Dart/Flutter artifacts in working tree | NONE | sandbox | no `.dart`, `pubspec.yaml`, `.metadata`, `analysis_options.yaml` |
| MQL5 EA compile | NOT RUN | needs MetaEditor | existing log: 0 errors, 2 warnings |
| Live Telegram / MT5 | NOT RUN | needs credentials + terminal | — |

## Evidence table

| Item | Code exists | Unit-tested | Verified live | Evidence |
|---|---|---|---|---|
| Strict signal parser (`signal_parser.py`) | yes | yes | no | engine_py suite |
| Digit normalizer / classifier | yes | yes | no | engine_py suite |
| Validator (`signal_processor.py`) | yes | yes | no | engine_py suite |
| Roulette (`roulette.py`) | yes | yes | no | engine_py suite |
| SQLite store (`db.py`) | yes | yes | no | engine_py suite |
| MT5 link server (`server.py`) | yes | yes | no | needs MT5 terminal |
| MT5 protocol (`mt5_protocol.py`) | yes | yes | no | engine_py suite |
| Risk planner (`execution.py`) | yes | yes | no | dry-run only |
| Listener queue consumer (`listener_consumer.py`) | yes | yes | no | needs live Telegram |
| Telegram Listener (`listener/`) | yes | no | no | needs live Telegram |
| Web dashboard (`control_center/web/`) | yes | no | no | needs a browser session |
| MQL5 EA (`NixoLink.mq5`) | yes | no | no | never compiled in MetaEditor |

## Roulette: deviations from docs/ROULETTE_SPEC.md

Still **not** an exact match. These remain open and unapproved:

| # | Spec (EA) | `roulette.py` | Status |
|---|---|---|---|
| 1 | Order win: `step = min(cap, step + 1)` | `step + 1` capped | matches |
| 2 | `InpRouletteTrigger` = 4.00% | `activation_trigger_pct = 3.0` | OPEN |
| 3 | `InpMaxStep` = 50 | `max_steps = 50` | matches |
| 4 | `InpBaseRisk` = 0.25% | `base_risk_pct = 0.5` | OPEN |
| 5 | `InpMaxOrderCount` = 8 | `max_order_count = 8` | matches |
| 6 | State in MT5 globals | SQLite `roulette_states` | by design |
| 7 | Flat zone `|profit| < 0.15*riskMoney` | same | matches |

Sizing default risk is **0.25%** when a profile omits `risk_percent`
(`execution.py`), covered by a test.

## Not verified (needs live environment)

- Live Telegram login/session/updates/edits/photos.
- MT5 socket round-trip, reconnect, MetaEditor compile.
- Image OCR/vision accuracy.
- Real proxy failover.
- OrderCalcProfit lot math against a live broker.
- TradingView webhook through a tunnel.
- Any browser session against the dashboard.
- Dart/Flutter code removed from the working tree.

## How to run on the owner's PC

```sh
# one-click
Start_Nixo.bat        # starts the engine, waits for /health, opens the dashboard
Health_Check.bat      # /health + /status + listeners
Stop_Nixo.bat         # stops the engine; state stays in data/nixo.db

# manual
cd engine_py && py -3 -m unittest discover -s tests -v
py -3 -m nixo_engine.listener_consumer --queue-db ..\listener\data\listener_queue.db --engine-db .\data\nixo_engine.db
py -3 -m nixo_engine.signal_processor --engine-db .\data\nixo_engine.db
py -3 -m nixo_engine.execution --config .\engine_config.json --engine-db .\data\nixo_engine.db
# EA: compile mt5/NixoLink.mq5 in MetaEditor (F7)
```

Dashboard: `http://127.0.0.1:9124/` (token via `engine_config.json` → `api_token`;
set `NIXO_TOKEN` for the BAT files).