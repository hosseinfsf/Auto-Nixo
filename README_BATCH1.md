# Batch 1: EA + MT5 link (protocol, link_server, tests)

Copy these files over the repo (same paths):

- mt5/NixoLink.mq5                              (EA v2)
- apps/engine/lib/src/mt5/protocol.dart         (percent-encoding)
- apps/engine/lib/src/mt5/link_server.dart      (framing, per-socket auth, heartbeat timeout, fail-fast)
- apps/engine/test/protocol_test.dart
- apps/engine/test/link_server_test.dart

## One-time setup
1. Make a token (PowerShell):
   -join ((48..57)+(65..90)+(97..122) | Get-Random -Count 40 | ForEach-Object {[char]$_})
2. engine_config.json (copy of engine_config.example.json): "api_token": "<the token>"
3. MT5: open mt5/NixoLink.mq5 in MetaEditor, press F7 (compile), paste any error text back.
4. MT5: Tools > Options > Expert Advisors: allow algorithmic trading and add 127.0.0.1 to
   "Allow WebRequest for listed URL". Attach NixoLink to one chart, set InpAuthToken = <the token>.
5. Real accounts stay blocked unless InpAllowReal = true.

## Tests
cd apps/engine ; dart pub get ; dart analyze ; dart test --reporter expanded 2>&1 | Select-Object -Last 15
