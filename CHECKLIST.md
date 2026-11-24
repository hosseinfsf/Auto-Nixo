# NIXO LITE — MASTER CHECKLIST

> Authoritative working copy. Status legend:
> - `[x]` = proven by a passing test run.
> - `[~]` = code written but NOT verified yet (needs owner's PC / live env).
> - `[ ]` = not started / requires live environment or owner input.
>
> See `STATUS.md` for the full evidence table.

## B. PRODUCT

Lightweight bilingual (Persian/English, RTL) Windows app that reads trading
signals from INPUTS, validates them, sizes them with money management and
executes on MetaTrader 5, automatically and permanently, with zero user action
after start. Speed and accuracy first. Every input has its own full settings
and its own performance score. Personal account first; prop-firm rules exist as
an optional profile (default OFF). AI is an optional module (OFF for now).

### B1. INPUT REGISTRY

- [~] Table inputs: id, type (telegram_source | tradingview_webhook), name,
      enabled, profile_id, status, last_message_at, last_error. (`engine_py/nixo_engine/db.py`)
- [~] Python Listener runs as a separate manually controlled process; Engine
      consumes its shared SQLite queue without auto-starting Telegram.
- [~] Queue consumer: lease/claim/retry/processed ACK, original timestamp and
      per-channel TTL recheck; queue execution permission defaults OFF.
      (code + regression tests written; owner-PC execution pending)
- [~] Durable execution intents: write immutable order plan before MT5 OPEN;
      preserve uncertain outcomes and retry with the same client order ID.
      (code + lost-ACK regression test written; owner-PC execution pending)
- [ ] Each input shows live health in the UI; a dead input raises an alert and
      auto-retries.
- [ ] Input type "telegram_source": channel/group by @username, t.me link,
      numeric id, or invite link. (needs live Telegram)
- [ ] Input type "tradingview_webhook": see M4.
- [ ] New input types require only a new adapter implementing `InputAdapter`.

## D. GROUND RULES

- [ ] Windows 10/11, always on; engine runs headless on a server later.
- [~] Python engine (headless) + web control center (vanilla HTML/JS over
      localhost, token-protected). UI crash never stops trading. (structure exists)
- [~] Secrets only in Windows Credential Manager/DPAPI; never in logs/repo.
      (.gitignore + config placeholders; no secret store implemented)
- [ ] Demo/Real always visible; Real needs one-time explicit confirmation; SL on
      every order; no min-lot override.
- [~] Never execute a signal that fails the deterministic validator.
      (`engine_py/nixo_engine/signal_parser.py` exists, tested)

## M0. SPIKES

- [ ] S1 TDLib from Python on Windows (login, session, updates, edits, photos,
      history catch-up, reconnect, clock-skew; measure latency). — needs live
      Telegram session.
- [ ] S2 MT5 link per C4 (latency, reconnect, auth; launch config; calendar).
      — `engine_py/nixo_engine/server.py` + `mt5/NixoLink.mq5` written, not run/compiled.
- [ ] S3 Images: vision LLM + OCR + agreement; report accuracy per field. (not started)
- [ ] S4 Proxy: MTProto/SOCKS5/local port; failover; latency. (not started)
- [ ] S5 Sizing: OrderCalcProfit for XAUUSD/FX/index/crypto vs hand calc.
      — `engine_py/nixo_engine/execution.py` uses OrderCalcProfit path, not run.
- [ ] S6 TradingView webhook: POST through tunnel; 200 < 3s. (not started)
- [ ] S7 reports/M0_report.md. (M0_report.md exists, notes "cannot execute here")

## M1. ENGINE CORE + TELEGRAM + PROXY + INPUT REGISTRY

- [~] Layout: listener/, engine_py/, control_center/web/, mt5/NixoLink.mq5,
      tests/, docs/, reports/.
- [~] SQLite (WAL) store: inputs, profiles, raw_messages, signals, decisions,
      orders/legs, execution_intents, journal, samples, outcomes, stats, audit,
      settings. (`engine_py/nixo_engine/db.py`)
- [~] Telegram User Account Listener is a separate manually controlled
      Python/Telethon process; Engine consumes its durable SQLite queue and
      never auto-starts a Telegram session.
- [~] Input registry (B1) with auto-start. (`engine_py/nixo_engine/db.py`)
- [ ] Catch-up after reconnect only inside validity window. (not implemented)
- [ ] Message policies: forwarded, reply, edit, album, caption+photo, deleted.
      (partial in listener)
- [~] Idempotency: durable intent before send; EA reserves client_order_id
      before broker-side effects and returns the original ticket on duplicates.
      Unresolved reservations go to manual review; no exactly-once guarantee.
      Dedupe key = (input_id, message_id, edit_version). (`engine_py/nixo_engine/db.py`,
      `engine_py/nixo_engine/execution.py`, `mt5/NixoLink.mq5`)
- [~] Replay tool with fake executor. (`engine_py/nixo_engine/execution.py`)
- [ ] Tests: fake Telegram, fake EA, chaos tests. (unit tests written, NOT run live)

## M2. EA "NIXO LINK" + EXECUTION

- [~] EA per C4/C5: localhost only, token auth, heartbeat, auto-reconnect,
      refuses other addresses. (`mt5/NixoLink.mq5` — never compiled in MetaEditor)
- [~] Commands: OPEN, MODIFY, CLOSE (partial), CANCEL, CLOSE_ALL, GET_SYMBOLS,
      GET_SYMBOL_INFO, GET_ACCOUNT, GET_POSITIONS, GET_RATES, GET_CALENDAR.
      (`mt5/NixoLink.mq5`)
- [~] Lots via OrderCalcProfit; round down to step; clamp to max; reject below
      min. (`mt5/NixoLink.mq5` + `engine_py/nixo_engine/execution.py`)
- [~] Execution plan inside the EA (legs, SL/TP per leg, break-even, partials,
      trailing). (`mt5/NixoLink.mq5`)
- [~] Events to engine: acks, fills, rejections, closed positions, account
      snapshots, margin mode, trade mode, server time. Netting → degrade/warn.
      (`mt5/NixoLink.mq5`)
- [ ] Demo smoke test: signal → order with correct lot, SL, TP. (not run)

## M3. PARSING, VALIDATION, PROFILES, RISK, UI

- [~] Classifier: signal / management update / recap / noise; Persian+English;
      normalize Persian/Arabic-Indic digits; avoid false positives.
      (`engine_py/nixo_engine/signal_parser.py`)
- [~] Text parser with per-input profile; any symbol; entry ranges; multiple
      TPs; market vs limit/stop from live quote. (`engine_py/nixo_engine/signal_parser.py`)
- [~] Deterministic validator (mandatory): SL/TP geometry, R:R, entry vs live
      quote, spread, stops level, market open, signal age, symbol tradable,
      duplicates. (`engine_py/nixo_engine/signal_parser.py`)
- [ ] Management updates apply to replied signal or latest active signal. (not implemented)
- [~] Per-input profile: enabled; mode OFF/SHADOW/CONFIRM/AUTO; allowed symbols;
      aliases; days/hours; validity; max entry deviation; spread/slippage.
      (`engine_py/nixo_engine/db.py`)
- [~] Sizing: % equity/balance / fixed cash / fixed lot; base risk %; per-input
      multiplier; per-symbol caps; min/max lot; commission+slippage.
      (`engine_py/nixo_engine/execution.py`)
- [~] SL policy: signal / ATR default / fixed points / reject. TP policy:
      signal / default R:R / split ladder; legs; BE; trailing; partials; runner;
      close on opposite. (`engine_py/nixo_engine/execution.py`)
- [~] Per-input limits: max trades/day, max concurrent, daily loss %,
      consecutive-loss pause. (`engine_py/nixo_engine/db.py`)
- [~] Global limits: max open risk %, max positions, daily loss %, max drawdown.
      Trip → block NEW, keep managing, alert. (`engine_py/nixo_engine/db.py`)
- [ ] Kill switch (button + hotkey). (UI placeholder only)
- [~] UI (vanilla HTML/JS, fa/en, RTL, dark/light): dashboard, inputs page, proxy page,
      live feed, logs, settings. (`control_center/web/` — never built/tested)
- [ ] Autostart: Task Scheduler; watchdog; prevent sleep; launch MT5 with
      startup config. (not implemented)

## M4. IMAGES + TRADINGVIEW INPUT + SAMPLE LIBRARY + AI MODULE

- [ ] Read caption first; classify image: signal chart / result recap / noise.
- [ ] Reader A: vision LLM (strict JSON). Reader B: local OCR on cropped axis.
      Agreement = high confidence; disagreement = uncertain.
- [ ] Cross-check with live quote and validator.
- [ ] Uncertain-but-valid: in-app notification with max 10s cancel window;
      execute after timeout unless cancelled. Per-input config.
- [ ] Image path never blocks text path; cache by image hash.
- [~] TradingView input: shelf POST /tv/<token>; 200 immediately, async process.
      (`engine_py/nixo_engine/server.py` — not run)
- [ ] Public HTTPS via tunnel on port 443; secret path token + passphrase; body
      size/rate limits; allowlist IPs.
- [ ] Payload JSON template + plain text through text parser; dedupe by id/time.
- [ ] Sample library: save-as-sample, import/export, regression.
- [ ] AI module (OFF by default): provider interface, states Disabled → Test-only
      → Assist → Active; test panel.

## M5. TRADE MANAGEMENT, ROULETTE, PROP MODE, REPORTS

- [ ] Break-even, partials, trailing, close on opposite, management updates.
- [~] Roulette per input ON/OFF: risk ladder, order roulette, volume roulette
      (parity with docs/ROULETTE_SPEC.md); persisted; reset; log actual vs
      base-risk. (`engine_py/nixo_engine/roulette.py` — ported, tested; deviations
      documented in STATUS.md)
- [ ] Prop mode (global toggle, default OFF): daily loss %, max drawdown, max
      risk/trade, max lots, max positions, news blackout, min hold, weekend ban,
      roulette forced OFF unless overridden.
- [ ] Virtual outcome tracker using MT5 M1 bars + spread (pessimistic SL-first).
- [ ] Per-input metrics (7d/30d/all): n_signals, n_valid, n_executed, win rate,
      avg R, expectancy R, profit factor, maxDD R, avg time, R_per_hour_open,
      R_per_day, net money, skipped %, parse accuracy, avg latency.
- [ ] Ranking score (editable): Score = R_per_hour_open * (n/(n+30)) *
      (1/(1+maxDD_R/10)). n<30 → "insufficient data".
- [ ] UI ranking table with sparkline + SUGGESTED risk multiplier (0.25–2.0),
      applied manually.
- [ ] Reports weekly/monthly per input and overall; CSV/PDF; roulette impact.

## M6. HARDENING AND DELIVERY

- [ ] Reliability matrix (test + alert per row): Telegram drop, proxy dead,
      session invalid, sleep/resume, MT5 closed, EA disconnected, crash mid-order,
      duplicate delivery, edit after trade, requote, market closed, partial fill,
      AI timeout, tunnel down, webhook flood, disk full, clock skew.
- [ ] 72-hour soak test: zero duplicates, zero stale executions.
- [ ] Latency instrumentation p50/p95 (target ~300 ms text, excluding broker).
- [ ] Installer; user docs fa/en; manual Demo smoke-test checklist; list of
      unverified items.
- [ ] reports/M6_report.md + reports/ALL_REPORTS.zip.
