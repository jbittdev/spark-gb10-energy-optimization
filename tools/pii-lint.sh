#!/usr/bin/env bash
# pii-lint.sh — privacy lint for repo content destined for a public GitHub repo.
#
# FAIL classes = hard blockers (exit 1): direct identifiers.
# WARN classes = review before publishing (exit 0): soft fingerprints such as
#                raw two-decimal measurements, topology hints, brand names.
#
# Deliberately contains NO private literals (no real names, hosts, or addrs):
# it detects *classes*, so it is safe to ship inside the public repo itself.
#
# Usage:
#   ./tools/pii-lint.sh [PATH]        # default: repo root (script's ../..)
#   PII_LINT_STRICT=1 ...             # treat WARNs as FAILs (CI mode)
#
# Scope: *.md *.yaml *.yml *.sh *.py *.json *.txt *.toml, skipping .git,
#        node_modules, .venv, results/ archives.

set -u
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
STRICT="${PII_LINT_STRICT:-0}"
fail=0; warn=0

scan() { # class, severity, regex
  local class="$1" sev="$2" re="$3" hits
  hits=$(grep -rInE --include='*.md' --include='*.yaml' --include='*.yml' \
    --include='*.sh' --include='*.py' --include='*.json' --include='*.txt' \
    --include='*.toml' "$re" "$ROOT" 2>/dev/null \
    | grep -vE '/(\.git|node_modules|\.venv|__pycache__|results/)/' \
    | grep -v 'tools/pii-lint.sh' || true)
  if [ -n "$hits" ]; then
    if [ "$sev" = FAIL ]; then fail=$((fail+1)); else warn=$((warn+1)); fi
    printf '[%s] %s\n%s\n' "$sev" "$class" "$hits"
  fi
}

# ---------------- FAIL classes: direct identifiers ----------------
scan 'email address'            FAIL '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9-]+\.[a-zA-Z0-9.-]{2,}'
scan 'IPv4 address'             FAIL '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b'
scan 'IP subnet notation'       FAIL '\b[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}\b|\b10\.[0-9]+\.[0-9]+\.0\b|\b192\.168\.\b'
scan 'home / tilde path'        FAIL '/home/[a-zA-Z0-9_.-]+|\x7E/[a-zA-Z0-9_.-]+'
scan 'ssh user@host'            FAIL '\bssh\x20+[a-zA-Z0-9_]+@[a-zA-Z0-9.-]+'
scan 'numbered node label'      FAIL '\b(gx|gx10|spark|node|srv|host)[-_]?[0-9]{2,4}\b'
scan 'MAC address'              FAIL '\b([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}\b'
scan 'hash-like digest'         FAIL '\b[0-9a-f]{32,64}\b'
scan 'BIOS/firmware build str'  FAIL '\b[A-Z0-9]{4,}\.[0-9]{4}\.[0-9]+\.[0-9]+\b|\b[0-9]\.[0-9]{2}_[0-9A-Z]{4,}\b'
scan 'private container tag'    FAIL '\b[a-z0-9]+:[a-z0-9]+-v[0-9]+-[a-z0-9]+\b'
scan 'UUID v4'                  FAIL '\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b'
scan 'literal "localhost" creds' FAIL '(password|passwd|token|secret)\s*[:=]\s*\S+'

# ---------------- WARN classes: soft fingerprints ----------------
scan 'two-decimal measurement'  WARN '\b[0-9]+\.[0-9]{2}\s*(W|°C|GHz|ms|µs)\b'
scan 'topology hint (node×rank)' WARN '\b(4|8)[- ×]?(node|rank)|\bTP[48]\b'
scan 'UPS/hardware brand'       WARN '\b(CyberPower|APC\b|Eaton|TrippLite|Cyber\x20Power)\b'
scan 'specific port number'     WARN ':[0-9]{4,5}\b'
scan 'exact timestamp'          WARN '\b20[0-9]{2}-[0-9]{2}-[0-9]{2}[T\x20][0-9]{2}:[0-9]{2}\b'
scan 'model deployment matrix'  WARN '(serving|deployment).{0,40}(matrix|inventory)|node.{0,10}table'

# ---------------- report ----------------
printf '\npii-lint: %d FAIL, %d WARN  (root: %s)\n' "$fail" "$warn" "$ROOT"
if [ "$fail" -gt 0 ]; then exit 1; fi
if [ "$STRICT" = 1 ] && [ "$warn" -gt 0 ]; then exit 1; fi
exit 0
