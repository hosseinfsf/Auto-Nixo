# NIXO — Third-Party Components

## Telethon
- **URL**: https://github.com/LonamiWebs/Telethon
- **SPDX License**: MIT
- **Latest release**: 1.46.0 (Nov 17, 2026)
- **Last commit**: UNVERIFIED (moved to Codeberg)
- **CI/tests**: UNVERIFIED (no CI badge observed)
- **Windows support**: Yes (pure Python, py3-none-any wheel)
- **Install size**: 836.2 KB wheel + 766.6 KB sdist
- **Pinned version**: 1.46.0
- **Hash**: sha256:8357f5719376a9c1ddf0999136a44594a5b21b453647f1e146c169483b6a67df (sdist)
- **Usage**: Telegram MTProto client (user account), proxy support, catch_up, auto_reconnect, set_proxy
- **Attribution**: MIT License, Copyright (c) 2016-Present LonamiWebs

## python-socks
- **URL**: https://github.com/romis2012/python-socks
- **SPDX License**: Apache-2.0
- **Latest release**: 3.2.2
- **Windows support**: Yes (pure Python)
- **Install size**: 49 KB wheel
- **Pinned version**: 3.2.2
- **Usage**: SOCKS5/HTTP proxy support for Telethon (Telethon prefers python-socks over PySocks)
- **Attribution**: Apache-2.0

## python-dotenv
- **URL**: https://github.com/theskumar/python-dotenv
- **SPDX License**: BSD-3-Clause
- **Latest release**: 1.0.1
- **Windows support**: Yes (pure Python)
- **Pinned version**: 1.0.1
- **Usage**: Load .env configuration files
- **Attribution**: BSD-3-Clause

## Telethon FakeTLS (ee) Proxy Support
- **Verified**: Telethon 1.46.0 supports MTProto proxies with FakeTLS secrets (ee prefix).
- **Evidence**: Tested with proxy REDACTED_PROXY_HOST:2096 (ee secret) → connection successful.
- **normalize_secret()**: Strips "ee" prefix, decodes hex, takes first 16 bytes.
- **Conclusion**: mtg (FakeTLS-only) CAN be used with Telethon. No need for TDLib/Pytdbot for proxy support.
- **Note**: Telethon does NOT support domain fronting (domain is stripped). For domain fronting, use TDLib/Pytdbot.

## Removed from dependencies
- **Pytdbot 0.8.8**: Removed from requirements.txt. Telethon 1.46.0 provides sufficient proxy support (including FakeTLS/ee secrets). Pytdbot remains available as a fallback if TDLib-specific features are needed.
