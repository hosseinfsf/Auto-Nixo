# PUSH INSTRUCTIONS — Auto-Nixo

این فایل برای آپلود دستی پروژه به GitHub روی **PC** شماست (نه از داخل اپ).

## هدف
پروژهٔ NIXO LITE (موتور Python + Listener + EA) را به repo خصوصی
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

git add listener
git commit -m "listener: Telethon Telegram Listener + Management Panel"

git add engine_py
git commit -m "engine: Python parser, risk planner, MT5 link, tests"

git add mt5
git commit -m "mt5: NixoLink.mq5 EA (socket client, CTrade)"

git add control_center
git commit -m "web: vanilla dashboard"

git add docs reports .github
git commit -m "docs: architecture, reports, CI"

# 4) ریموت را اضافه و پوش کن
git remote add origin https://github.com/hosseinfsf/Auto-Nixo.git
git push -u origin main
```

> در اولین push، GitHub از تو توکن/ورود میخواهد. اگر از GitHub CLI استفاده میکنی:
> `gh auth login` سپس `gh repo set-default hosseinfsf/Auto-Nixo`.

## بعد از پوش
- CI (`.github/workflows/python-engine.yml`) خودکار تستهای Python را اجرا میکند.
- لاگهای هر مرحله بهصورت artifact آپلود میشوند (حتی در صورت شکست).
- اگر CI قرمز بود، فقط بر اساس لاگها اصلاح کن (یک شکست در هر بار).
- هیچ مرحلهای که به Telegram/MT5/سکرت نیاز دارد در CI اجرا نمیشود.

## نکات امنیتی
- هیچ سکرتی (api_id/api_hash، پروکسی واقعی، توکن) در پروژه نیست.
- `.gitignore` شامل `*.session`, `*.db*`, `.env*`, `secrets/`, `*.dll`,
  `*.exe`, `build/`, `node_modules/`, `logs/` است.
- فایلهای سشن و توکنها هرگز کامیت نمیشوند.
