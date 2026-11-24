# Post-Deletion Report — Dart/Flutter Removal

**Date:** 2026-11-24
**Branch:** test-quality-improvement
**Scope:** Complete removal of all Dart/Flutter code and references from the
repository, leaving the Python engine as the sole runtime.

---

## 1. Summary

All Dart/Flutter source trees, archived copies, build scripts, and zip artifacts
were deleted. Documentation, configuration, and batch files were rewritten to
describe the Python engine as the runtime. The Python test suite passes
(65/65). No `.dart`, `pubspec.yaml`, `.metadata`, or `analysis_options.yaml`
files remain in the working tree or in Git's tracked file list.

## 2. Deleted paths

| Path | Contents |
|---|---|
| `apps/engine/` | Headless Dart engine: config, db, Telegram TDLib FFI, proxy manager, input registry, pipeline, MT5 link server, protocol, HTTP API, watchdog, replay, tests |
| `packages/core/` | Shared Dart package: models, normalizer, classifier, text parser, symbol mapping, validator, sizing, SL/TP, roulette, limits, tests |
| `archive/legacy_dart_flutter/` | Archived copy of the above (engine + core + Flutter UI + CI workflow) |
| `scripts/fetch_tdjson.ps1` | TDLib `tdjson.dll` fetcher (Dart FFI dependency) |
| `nixo_fix_batch1.zip` | Batch-1 zip containing Dart engine files |

## 3. Modified files

| File | Change |
|---|---|
| `README.md` | Rewritten for Python engine + Listener + EA architecture |
| `AGENTS.md` | Python-only run/test instructions |
| `CHECKLIST.md` | Dart/Flutter references replaced with Python paths |
| `DECISIONS.md` | Architecture table and component sections rewritten for Python |
| `STATUS.md` | Dart/Flutter rows removed; Python-only evidence table |
| `OPERATING.md` | Python-only prerequisites, config, and pipeline stages |
| `PUSH_INSTRUCTIONS.md` | Commit plan and CI references updated |
| `README_BATCH1.md` | Python test commands and paths |
| `Start_Nixo.bat` | Launches `nixo_engine.execution` instead of `dart run` |
| `Stop_Nixo.bat` | Updated state DB path |
| `docs/architecture.md` | Python engine + Listener + EA diagram |
| `reports/M0_report.md` | Python paths and Telethon references |
| `reports/M1_report.md` | Python paths and test commands |
| `reports/M2_report.md` | Python test commands |
| `reports/M3_report.md` | Python paths and test commands |
| `reports/PHASE0_REPORT.md` | Config path updated to `engine_py/` |
| `reports/PHASE4_REPORT.md` | Dart columns removed; Python-only comparison |
| `reports/research/REPORT_RESEARCH.md` | Archived section replaced with "Removed" |
| `mt5/NixoLink.mq5` | Comment: `protocol.dart` → `mt5_protocol.py` |
| `engine_py/README.md` | Removed "archived Dart/Flutter" reference |
| `.gitignore` | Removed Dart/Flutter block; removed `apps/engine/engine_config.json` entry |

## 4. Verification

### 4.1 Artifact scan

```
$ find . -name '*.dart' -o -name 'pubspec.yaml' -o -name '.metadata' -o -name 'analysis_options.yaml'
(no results)

$ git ls-files | grep -E '\.dart$|pubspec|\.metadata|analysis_options|legacy_dart_flutter'
(no results)
```

### 4.2 Python tests

```
$ cd engine_py && py -3 -m unittest discover -s tests -v
Ran 65 tests in 9.648s
OK
```

All 65 tests pass (parser, protocol, server, queue consumer, risk planner,
roulette, reconciliation, DB, signal processor).

### 4.3 Remaining references

The only remaining mentions of "Dart" or "Flutter" are in historical report
text describing what was removed (e.g. `reports/research/REPORT_RESEARCH.md`
section 0.2 "Removed"). No code, config, or script references remain.

## 5. What was NOT changed

- `engine_py/` — untouched (Python engine, tests, config example).
- `listener/` — untouched (Telethon Listener, proxy manager, API).
- `mt5/NixoLink.mq5` — only the comment on line 54 was updated.
- `control_center/web/` — untouched (vanilla dashboard).
- `docs/ROULETTE_SPEC.md` — untouched.
- `.github/workflows/python-engine.yml` — untouched.

## 6. Open items

- MQL5 EA compile in MetaEditor (never run).
- Live Telegram / MT5 verification (needs credentials + terminal).
- Roulette deviations from `docs/ROULETTE_SPEC.md` (5 OPEN items).
- Web dashboard browser session (never opened).

## 7. Conclusion

The repository is now a pure Python project. The Dart/Flutter runtime has been
fully removed and all documentation reflects the Python engine as the sole
implementation. The Python test suite (65 tests) passes in the sandbox.
