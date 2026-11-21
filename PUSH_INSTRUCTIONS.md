# PUSH INSTRUCTIONS — Auto-Nixo

این فایل برای آپلود دستی پروژه به GitHub روی **PC** شماست (نه از داخل اپ).

## هدف
پروژهٔ `nixo_lite/` (بازنویسی Dart/Flutter NIXO LITE) را به repo خصوصی
`https://github.com/hosseinfsf/Auto-Nixo` پوش کنید.

## پیشنیازها (روی PC)
- نصب Git: https://git-scm.com/download/win
- (اختیاری) GitHub CLI: https://cli.github.com/
- یک توکن شخصی (PAT) یا ورود GitHub برای اولین push

## روش ۱ — آپلود دستی از طریق وب (سادهترین)
1. در مرورگر: `https://github.com/hosseinfsf/Auto-Nixo`
2. دکمهٔ «Add file → Upload files»
3. فایل `Auto-Nixo.zip` را بکش و رها کن (یا اول unzip کن و پوشهها را بکش)
4. «Commit changes»

## روش ۲ — با git (توصیهشده برای commits کوچک)
```bash
# 1) پروژه را از zip خارج کن
unzip Auto-Nixo.zip -d Auto-Nixo
cd Auto-Nixo

# 2) git را آغاز کن
git init
git branch -M main

# 3) commit های کوچک و معنادار
git add .gitignore README.md CHECKLIST.md DECISIONS.md STATUS.md AGENTS.md
git commit -m "skeleton/meta: meta files, gitignore, checklist, decisions, status"

git add packages/core
git commit -m "core: models, normalizer, classifier, parser, validator, risk"

git add apps/engine
git commit -m "engine: config, db, telegram tdlib, proxy, pipeline, mt5 link, api, watchdog"

git add mt5
git commit -m "mt5: NixoLink.mq5 EA (socket client, CTrade)"

git add apps/ui
git commit -m "ui: Flutter desktop dashboard/sources/proxy/livefeed/settings"

git add tests
git commit -m "tests: core + engine unit tests"

git add docs reports scripts .github
git commit -m "docs: architecture, reports, fetch_tdjson script, CI"

# 4) ریموت را اضافه و پوش کن
git remote add origin https://github.com/hosseinfsf/Auto-Nixo.git
git push -u origin main
```

> در اولین push، GitHub از تو توکن/ورود میخواهد. اگر از GitHub CLI استفاده میکنی:
> `gh auth login` سپس `gh repo set-default hosseinfsf/Auto-Nixo`.

## بعد از پوش
- CI (`.github/workflows/ci.yml`) خودکار روی `windows-latest` اجرا میشود.
- لاگهای هر مرحله بهصورت artifact آپلود میشوند (حتی در صورت شکست).
- اگر CI قرمز بود، فقط بر اساس لاگها اصلاح کن (یک شکست در هر بار).
- هیچ مرحلهای که به Telegram/MT5/سکرت نیاز دارد در CI اجرا نمیشود.

## نکات امنیتی
- هیچ سکرتی (api_id/api_hash، پروکسی واقعی، توکن) در پروژه نیست.
- `.gitignore` شامل `*.session`, `*.db*`, `.env*`, `secrets/`, `*.dll`,
  `*.exe`, `build/`, `.dart_tool/`, `node_modules/`, `logs/` است.
- `tdjson.dll` هرگز کامیت نمیشود؛ از `scripts/fetch_tdjson.ps1` دانلود میشود.
