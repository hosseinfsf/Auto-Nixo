# Agent notes — NIXO LITE (Python engine)

## How to run/test (on Windows)
- Python engine: `cd engine_py && py -3 -m unittest discover -s tests -v`.
- Listener: `cd listener && py -3 -m pip install -r requirements.txt`.
- EA: compile `mt5/NixoLink.mq5` in MetaEditor (F7). Never touch .ex5.

## Environment constraints
- Sandbox has no Windows, no MT5, no live Telegram, and external downloads are
  blocked. Python code is written and unit-tested in the sandbox.
- Engine socket server binds 127.0.0.1:9123; HTTP API on 127.0.0.1:9124.

## Pitfalls
- MT5 protocol is `KEY=VALUE` per line, not JSON.
- Never commit api_id/hash, sessions, proxies, or secrets.
