p = "reports/research/PHASE4_REPORT.md"
s = open(p).read()
# Remove proxy IP/port from evidence
s = s.replace("MTProto proxy REDACTED_PROXY_HOST:2096 → ok=True, latency=3514ms", "MTProto proxy (host/port redacted) → ok=True, latency=3514ms")
open(p, "w").write(s)
print("patched PHASE4_REPORT.md")
