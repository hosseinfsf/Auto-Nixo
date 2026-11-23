# NIXO — Glue Register

Every glue file (minimal wiring code) is listed here with its purpose,
line count, and which upstream API it calls.

## listener/listener.py (18,335 bytes)
- **Purpose**: Wire Telethon event handlers to SQLite queue; proxy health check loop; source allowlist; catch-up.
- **Upstream APIs**: Telethon (TelegramClient, events.NewMessage/MessageEdited/MessageDeleted, catch_up, set_proxy), sqlite3, hashlib, python-dotenv.
- **Glue functions**: handle_new_message, handle_edit, handle_delete, catchup, check_proxy_health, download_media, make_row, enqueue, init_queue, init_sources_table, init_proxy_table, get_allowlisted_chats, add_proxy, update_proxy_status, get_active_proxies, get_next_proxy, build_proxy_config, write_status, main.
- **Max function length**: ~40 lines (main). Most functions < 20 lines.

## listener/api.py (9,269 bytes)
- **Purpose**: HTTP API for Management Panel (listener control, proxy CRUD, queue stats).
- **Upstream APIs**: http.server (BaseHTTPRequestHandler), sqlite3, subprocess, hmac, json.
- **Glue functions**: Handler.do_GET, Handler.do_POST, _authorized, _validate_host_origin, _read_body, _json, _cors, get_db, _mask_secret, main.
- **Max function length**: ~60 lines (do_POST). Most functions < 20 lines.

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
