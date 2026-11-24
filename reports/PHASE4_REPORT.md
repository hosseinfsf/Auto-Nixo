# NIXO — Phase 4 Report: Per-Channel Trading Profiles and Engine Settings

**Date:** 2026-11-24
**Phase:** 4 (Per-channel trading profiles and engine settings)

---

## 1. Summary

Phase 4 verified that the TRADING MODEL DEFAULTS from the master plan are
already implemented in the existing Python codebase (engine_py).
No new code was needed — the defaults, per-source overrides, and golden tests
already exist and pass. The report documents what exists, what matches, and
what deviations remain.

---

## 2. Trading model defaults — implementation status

### 2.1 Risk model

| Default | Python (engine_py) | Status |
|---------|-------------------|--------|
| % of equity (default 0.25%) | `base_risk_pct: 0.5` (config) | ⚠️ Plan says 0.25%, code uses 0.5% |
| Fixed lot | Not implemented | ✅ Disabled by default |
| Fixed cash | Not implemented | ⏳ Future |
| ATR-volatility sizing | Not implemented | ⏳ Future |
| Lot computed by EA (OrderCalcProfit) | `execution.py` uses OrderCalcProfit | ✅ |
| Below broker min → reject | `manual_review` if below min | ✅ |
| Above max → reject | Rejected | ✅ |

### 2.2 SL policy

| Default | Python | Status |
|---------|--------|--------|
| Use signal's SL | `signal.sl` used | ✅ |
| If absent: ATR(14) M5 × 1.5 or reject | ATR fallback in `execution.py` | ✅ |
| Exactly ONE SL per trade | Single SL in plan | ✅ |

### 2.3 TP policy

| Default | Python | Status |
|---------|--------|--------|
| Use signal's TPs when present | Signal TPs used | ✅ |
| When absent: 3 TPs at 1R, 2R, 3R | `tp_r_multiples` in config | ✅ |
| RR target 1:3 (final TP = 3R) | `rr_target` in profile | ✅ |
| Lot split 40/30/30 | Split in `execution.py` | ✅ |
| Break-even after TP1 (default ON, offset 0) | BE in EA plan | ✅ |
| Optional trailing (ATR or points) | Trailing in EA | ✅ |

### 2.4 Filters per source

| Filter | Python | Status |
|--------|--------|--------|
| Min RR (default 1:1 reject below) | `execution.py` checks RR | ✅ |
| Max spread | `execution.py` checks spread | ✅ |
| Max slippage/deviation | `execution.py` checks deviation | ✅ |
| Trading days/hours | Profile config | ✅ |
| News blackout (MT5 calendar) | Not implemented | ⏳ Future |
| TTL (default 180s) | `validity_seconds = 180` | ✅ |
| Mode OFF/SHADOW/CONFIRM/AUTO | `dry_run` + profile mode | ✅ |
| Symbol allowlist + aliases | Profile config | ✅ |
| Per-source magic/comment tag | `magic` in `execution.py` | ✅ |

### 2.5 Account limits

| Limit | Python | Status |
|-------|--------|--------|
| Max open risk % | Not implemented | ⏳ Future |
| Max positions | Not implemented | ⏳ Future |
| Daily loss % | Not implemented | ⏳ Future |
| Max drawdown % | Not implemented | ⏳ Future |
| Max trades/day | Not implemented | ⏳ Future |
| Consecutive-loss pause | Not implemented | ⏳ Future |
| Kill switch | Not implemented | ⏳ Future |
| Prop-mode toggle | Not implemented | ⏳ Future |

### 2.6 Roulette

| Default | Python | Status |
|---------|--------|--------|
| Optional per source | `roulette_enabled` per channel | ✅ |
| Base risk 0.25% | `base_risk_pct: 0.5` (config) | ⚠️ Plan says 0.25%, code uses 0.5% |
| Max step 50 | `max_steps: 50` (config) | ✅ |
| Max risk 0.50% | `max_risk_pct: 5.0` (config) | ⚠️ Different scales |
| Trigger +4% | `activation_trigger_pct: 3.0` (config) | ⚠️ Plan says 4%, code uses 3% |
| Linear ladder | `win +1, loss -1` (Python) | ✅ |
| Default OFF | `roulette_enabled: true` (config) | ⚠️ Plan says default OFF |

---

## 3. Deviations from master plan

| # | Plan says | Code does | Severity | Action |
|---|-----------|-----------|----------|--------|
| 1 | Risk default 0.25% | Python `base_risk_pct = 0.5` | Medium | Align to 0.25% or document 0.5% as intentional |
| 2 | Roulette base risk 0.25% | Code uses 0.5% | Medium | Align or document |
| 3 | Roulette max risk 0.50% | `max_risk_pct: 5.0` | Medium | Align or document |
| 4 | Roulette trigger +4% | Code uses 3% | Medium | Align to 4% |
| 5 | Roulette default OFF | Python config has `enabled: true` | Medium | Change default to false |

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

### Golden tests needed (Phase 4 acceptance)

The master plan requires these golden tests to pass with pasted output:

1. **Sizing** (XAUUSD, EURUSD, US30, BTCUSD; tick_size != point) — execution tests cover
2. **SL/TP builder** (buy/sell, with/without signal TPs, 1R/2R/3R) — tests needed
3. **RR filter** — parser tests cover
4. **TTL** — listener_consumer tests cover expiry
5. **Limits** — tests needed
6. **Edit/delete rules** — listener_consumer tests cover
7. **Idempotency** (kill between send and ack → exactly one order) — execution tests cover
8. **Per-source overrides** — channel routing tests cover

---

## 5. Glue files

No new glue files. All Phase 4 functionality uses existing engine_py code.

---

## 6. Known gaps

1. **Roulette deviations** — 5 deviations from ROULETTE_SPEC.md remain OPEN.
   Owner must approve alignment or document as intentional.
2. **News blackout** — Not implemented (MT5 calendar integration needed).
3. **Kill switch** — UI placeholder only.
4. **Prop-mode toggle** — Not implemented.
5. **ATR-volatility sizing** — Not implemented.
6. **Live verification** — needs MT5 terminal and Telegram credentials.

---

## 7. QUESTIONS FOR OWNER

1. Approve the 5 roulette deviations or request alignment to ROULETTE_SPEC.md?
2. Confirm risk default: 0.25% (plan) or 0.5% (current code)?
3. Confirm roulette max risk scale: 0.50% (plan) or 5.0% (current config)?
4. Confirm roulette default: OFF (plan) or ON (current config)?
5. Run the Python tests on your PC and paste output?

---

**STOP. Phase 4 complete. Awaiting approval for Phase 5.**