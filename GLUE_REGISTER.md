# NIXO — Glue Register

Every glue file (minimal wiring code) is listed here with its purpose,
line count, and which upstream API it calls.

## listener/listener.py (18,335 bytes)
- **Purpose**: Wire Telethon event handlers to SQLite queue; proxy health check loop; source allowlist; catch-up.
- **Upstream APIs**: Telethon (TelegramClient, events.NewMessage/MessageEdited/MessageDeleted, catch_up, set_proxy), sqlite3, hashlib, python-dotenv.
- **Glue functions**: handle_new_message, handle_edit, handle_delete, catchup, check_proxy_health, download_media, make_row, enqueue, init_queue, init_sources_table, init_proxy_table, get_allowlisted_chats, add_proxy, update_proxy_status, get_active_proxies, get_next_proxy, build_proxy_config, write_status, main.
- **Max function length**: ~40 lines (main). Most functions < 20 lines.

## listener/api.py (FastAPI rewrite)
- **Purpose**: FastAPI HTTP API for Management Panel (listener control, source CRUD, proxy import/list/test/remove, queue stats).
- **Upstream APIs**: FastAPI, uvicorn, pydantic, sqlite3, subprocess, hmac, json, urllib.parse.
- **Glue functions**: security_middleware, listener_status, listener_start, listener_stop, sources_list, sources_add, sources_remove, proxy_link_get, proxy_link_set, proxy_list, proxy_import, proxy_test, proxy_remove, queue_stats, queue_recent, get_db, _authorized, _validate_host_origin, main.
- **Max function length**: ~30 lines. Most functions < 15 lines.

## listener/proxy_manager.py (new)
- **Purpose**: Proxy link parsing (stdlib urllib.parse), proxy DB CRUD, Telethon proxy conversion, quarantine/failover logic.
- **Upstream APIs**: urllib.parse, sqlite3, Telethon set_proxy, time.
- **Glue functions**: parse_proxy_link, parse_proxy_links_bulk, init_proxy_table, add_proxy, get_proxies, get_active_proxy, update_proxy_status, quarantine_proxy, to_telethon_proxy, build_proxy_config, mask_secret.
- **Max function length**: ~25 lines. Most functions < 15 lines.

## control_center/web/index.html (11,163 bytes)
- **Purpose**: Dashboard HTML with listener/proxy/queue sections.
- **Upstream**: None (static HTML). Uses existing Nixo CSS variables.

## control_center/web/app.js (21,484 bytes)
- **Purpose**: Dashboard JS for listener control, proxy management, queue display.
- **Upstream**: fetch API, DOM manipulation.
- **Glue functions**: startListener, stopListener, refreshStatus, addProxy, testProxy, removeProxy, loadProxies, loadQueue.

## control_center/web/style.css (4,311 bytes)
- **Purpose**: CSS for listener/proxy/queue UI components.
- **Upstream**: None (CSS).

## control_center/web/listener.html (12,057 bytes)
- **Purpose**: Standalone listener page (reference).
- **Upstream**: None (static HTML).

## mt5/NixoPanel.mqh (125 lines)
- **Purpose**: Read-only on-chart link/account monitor using MetaQuotes' bundled Controls library. Displays EA authentication state, last engine RX age, account login/type, balance/equity; explicitly marks Telegram status and ping RTT unavailable in the current protocol. No trade controls or order calls.
- **Upstream APIs**: MetaQuotes Standard Library `CAppDialog`, `CLabel`, `ChartRedraw`; MQL5 `AccountInfoInteger`, `AccountInfoDouble`, `AccountInfoString`, `GetTickCount64`.
- **Glue functions**: CreateLine, RefreshDue, AccountText, MoneyText, SetTextIfChanged, CreatePanel, Refresh, ForwardChartEvent.
- **Update policy**: called from the EA timer; samples at most every 500 ms and redraws only when displayed values change.
