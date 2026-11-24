# Batch 1: EA + MT5 link (protocol, server, tests)

Files in this batch:

- `mt5/NixoLink.mq5` — EA v2
- `engine_py/nixo_engine/mt5_protocol.py` — percent-encoding
- `engine_py/nixo_engine/server.py` — authenticated asyncio TCP server
- `engine_py/tests/test_mt5_protocol.py`
- `engine_py/tests/test_server.py`

## One-time setup
1. Make a token (PowerShell):
   -join ((48..57)+(65..90)+(97..122) | Get-Random -Count 40 | ForEach-Object {[char]$_})
2. `engine_py/engine_config.json` (copy of `engine_config.example.json`): set `api_token` to that token.
3. MT5: open `mt5/NixoLink.mq5` in MetaEditor, press F7 (compile), paste any error text back.
4. MT5: Tools > Options > Expert Advisors: allow algorithmic trading and add 127.0.0.1 to
   "Allow WebRequest for listed URL". Attach NixoLink to one chart, set InpAuthToken = the token.
5. Real accounts stay blocked unless InpAllowReal = true.

## Tests
```powershell
cd engine_py
py -3 -m unittest discover -s tests -v
```
