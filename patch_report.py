p = "reports/research/PHASE4_REPORT.md"
s = open(p).read()
# Remove proxy IP/port from evidence
s = s.replace("MTProto proxy 194.60.228.210:2096 → ok=True, latency=3514ms", "MTProto proxy (host/port redacted) → ok=True, latency=3514ms")
open(p, "w").write(s)
print("patched PHASE4_REPORT.md")
