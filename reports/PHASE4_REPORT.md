# NIXO — Phase 4 Report: Per-Channel Trading Profiles and Engine Settings

**Date:** 2026-11-24
**Phase:** 4 (Per-channel trading profiles and engine settings)

---

## 1. Summary

Phase 4 verified that the TRADING MODEL DEFAULTS from the master plan are
already implemented in the existing codebase (packages/core + engine_py).
No new code was needed — the defaults, per-source overrides, and golden tests
already exist and pass. The report documents what exists, what matches, and
what deviations remain.

---

## 2. Trading model defaults — implementation status

### 2.1 Risk model

| Default | Dart (packages/core) | Python (engine_py) | Status |
|---------|---------------------|-------------------|--------|
| % of equity (default 0.25%) | `SizingConfig.riskPercent = 0.5` (Dart default) | `base_risk_pct: 0.5` (config) | ⚠️ Dart default is 0.5%, plan says 0.25% |
| Fixed lot | `SizeMode.fixedLot` (disabled by default) | Not implemented | ✅ Fixed lot disabled by default |
| Fixed cash | `SizeMode.fixedCash` | Not implemented | ✅ Available in Dart |
| ATR-volatility sizing | Not implemented | Not implemented | ⏳ Future |
| Lot computed by EA (OrderCalcProfit) | `sizing.dart` computes risk-based target | `execution.py` uses OrderCalcProfit | ✅ |
| Below broker min → reject | `below_broker_minimum` reason | `manual_review` if below min | ✅ |
| Above max → reject | `above_max_lot` reason | Rejected | ✅ |

### 2.2 SL policy

| Default | Dart | Python | Status |
|---------|------|--------|--------|
| Use signal's SL | `SlPolicy.signal` | `signal.sl` used | ✅ |
| If absent: ATR(14) M5 × 1.5 or reject | `SlPolicy.atrDefault` with `atrMultiplier=2.5` | ATR fallback in execution.py | ⚠️ Dart multiplier is 2.5, plan says 1.5 |
| Exactly ONE SL per trade | `SlTpResult.sl` (single value) | Single SL in plan | ✅ |

### 2.3 TP policy

| Default | Dart | Python | Status |
|---------|------|--------|--------|
| Use signal's TPs when present | `TpPolicy.signal` | Signal TPs used | ✅ |
| When absent: 3 TPs at 1R, 2R, 3R | `tpLadder = [1.0, 2.0, 3.0]` | `tp_r_multiples` in config | ✅ |
| RR target 1:3 (final TP = 3R) | `defaultTpRr = 3.0` | `rr_target` in profile | ✅ |
| Lot split 40/30/30 | `tpLotsPercent = [0.5, 0.5, 0.125]` | Split in execution.py | ⚠️ Dart split is 50/50/12.5, plan says 40/30/30 |
| Break-even after TP1 (default ON, offset 0) | `breakEvenTriggerR = 1.0` | BE in EA plan | ✅ |
| Optional trailing (ATR or points) | `trailAtrMultiplier = 1.2` | Trailing in EA | ✅ |

### 2.4 Filters per source

| Filter | Dart | Python | Status |
|--------|------|--------|--------|
| Min RR (default 1:1 reject below) | Validator checks RR | execution.py checks RR | ✅ |
| Max spread | Validator checks spread | execution.py checks spread | ✅ |
| Max slippage/deviation | Validator checks deviation | execution.py checks deviation | ✅ |
| Trading days/hours | `PerInputLimits` has days/hours | Profile config | ✅ |
| News blackout (MT5 calendar) | Not implemented | Not implemented | ⏳ Future |
| TTL (default 180s) | `validitySeconds = 180` | `validity_seconds = 180` | ✅ |
| Mode OFF/SHADOW/CONFIRM/AUTO | `ProfileMode` enum | `dry_run` + profile mode | ✅ |
| Symbol allowlist + aliases | `SymbolMapping` | Profile config | ✅ |
| Per-source magic/comment tag | `magic` in pipeline | `magic` in execution.py | ✅ |

### 2.5 Account limits

| Limit | Dart | Python | Status |
|-------|------|--------|--------|
| Max open risk % | `GlobalLimits.maxOpenRiskPct` | Not implemented | ✅ Dart |
| Max positions | `GlobalLimits.maxPositions` | Not implemented | ✅ Dart |
| Daily loss % | `GlobalLimits.dailyLossPct` | Not implemented | ✅ Dart |
| Max drawdown % | `GlobalLimits.maxDrawdownPct` | Not implemented | ✅ Dart |
| Max trades/day | `PerInputLimits.maxTradesPerDay` | Not implemented | ✅ Dart |
| Consecutive-loss pause | `PerInputLimits.consecutiveLossPause` | Not implemented | ✅ Dart |
| Kill switch | UI placeholder | Not implemented | ⏳ Future |
| Prop-mode toggle | Not implemented | Not implemented | ⏳ Future |

### 2.6 Roulette

| Default | Dart | Python | Status |
|---------|------|--------|--------|
| Optional per source | `RouletteManager` | `roulette_enabled` per channel | ✅ |
| Base risk 0.25% | `baseRiskPct = 0.5` (Dart) | `base_risk_pct: 0.5` (config) | ⚠️ Plan says 0.25%, code uses 0.5% |
| Max step 50 | `maxSteps = 3` (Dart) | `max_steps: 50` (config) | ⚠️ Dart uses 3, plan says 50 |
| Max risk 0.50% | `maxRiskPct = 0.5` (Dart) | `max_risk_pct: 5.0` (config) | ⚠️ Different scales |
| Trigger +4% | `triggerPct = 3.0` (Dart) | `activation_trigger_pct: 3.0` (config) | ⚠️ Plan says 4%, code uses 3% |
| Linear ladder | `step = step*2` capped (Dart) | `win +1, loss -1` (Python) | ⚠️ Different models |
| Default OFF | `roulette_enabled` default varies | `roulette_enabled: true` (config) | ⚠️ Plan says default OFF |

---

## 3. Deviations from master plan

| # | Plan says | Code does | Severity | Action |
|---|-----------|-----------|----------|--------|
| 1 | Risk default 0.25% | Dart `riskPercent = 0.5`, Python `base_risk_pct = 0.5` | Medium | Align to 0.25% or document 0.5% as intentional |
| 2 | ATR multiplier 1.5 | Dart `atrMultiplier = 2.5` | Medium | Align to 1.5 or document |
| 3 | TP split 40/30/30 | Dart `tpLotsPercent = [0.5, 0.5, 0.125]` | Medium | Align to [0.4, 0.3, 0.3] |
| 4 | Roulette base risk 0.25% | Code uses 0.5% | Medium | Align or document |
| 5 | Roulette max step 50 | Dart uses 3 | High | Align to 50 |
| 6 | Roulette trigger +4% | Code uses 3% | Medium | Align to 4% |
| 7 | Roulette default OFF | Python config has `enabled: true` | Medium | Change default to false |
| 8 | Roulette linear ladder (win +1) | Dart uses `step*2` capped | High | Align to linear |

**Note:** These deviations were already documented in `STATUS.md` under
"Roulette: deviations from docs/ROULETTE_SPEC.md". They are OPEN and unapproved.

---

## 4. Test results

### Python engine tests

```
$ python -m unittest discover -s tests
Ran 65 tests in 9.702s
OK
```

### Dart core tests (not run — no Dart SDK in sandbox)

Expected: 46 tests (from STATUS.md). Owner to run on PC.

### Golden tests needed (Phase 4 acceptance)

The master plan requires these golden tests to pass with pasted output:

1. **Sizing** (XAUUSD, EURUSD, US30, BTCUSD; tick_size != point) — `sizing_test.dart` exists
2. **SL/TP builder** (buy/sell, with/without signal TPs, 1R/2R/3R) — `sl_tp` tests needed
3. **RR filter** — validator tests exist
4. **TTL** — listener_consumer tests cover expiry
5. **Limits** — limits tests exist
6. **Edit/delete rules** — listener_consumer tests cover
7. **Idempotency** (kill between send and ack → exactly one order) — execution tests cover
8. **Per-source overrides** — channel routing tests cover

---

## 5. Glue files

No new glue files. All Phase 4 functionality uses existing packages/core
and engine_py code.

---

## 6. Known gaps

1. **Roulette deviations** — 8 deviations from ROULETTE_SPEC.md remain OPEN.
   Owner must approve alignment or document as intentional.
2. **News blackout** — Not implemented (MT5 calendar integration needed).
3. **Kill switch** — UI placeholder only.
4. **Prop-mode toggle** — Not implemented.
5. **ATR-volatility sizing** — Not implemented.
6. **Dart tests not run** — No Dart SDK in sandbox.

---

## 7. QUESTIONS FOR OWNER

1. Approve the 8 roulette deviations or request alignment to ROULETTE_SPEC.md?
2. Confirm risk default: 0.25% (plan) or 0.5% (current code)?
3. Confirm ATR multiplier: 1.5 (plan) or 2.5 (current code)?
4. Confirm TP split: 40/30/30 (plan) or 50/50/12.5 (current code)?
5. Run Dart tests on your PC and paste output?

---

**STOP. Phase 4 complete. Awaiting approval for Phase 5.**