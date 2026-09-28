# Audit Playbook — Comparing a Target Repo Against the GB10 Capability Registry

Use this when you have another repo (or set of docs) and want to know: **which
of the known GB10 power/thermal/efficiency capabilities does it implement,
partially implement, get wrong, or miss?**

Audience: an AI agent (autonomous execution) or a human reviewer (manual
checklist). Both paths are the same procedure; agents automate Phase 1–2.

---

## Inputs

- `registry/features.yaml` — the capability catalog (the source of truth for
  *what* counts as a capability and *how to detect* it)
- `FINDINGS-LANDSCAPE.md` — the evidence behind every capability (read the
  referenced § when a judgment call is needed)
- The target repo path / URL

## Outputs

- `audit/results/<target-name>-AUDIT.md` — filled from
  `audit/AUDIT-TEMPLATE.md`
- A one-paragraph verdict: coverage profile, red flags, and the top gaps

---

## Phase 0 — Classify the target (5 min)

Before grepping, decide what kind of artifact the target is. This sets the
scoring expectation:

| Target type | Expectation |
|---|---|
| **Tooling repo** (scripts/daemons that *apply* levers) | Score on implementation features (GPU-CAP, CPU-CAP, PERI-*, GOV-*, MEAS-*) |
| **Research/docs repo** (findings, guides) | Score on knowledge features (FW-*, CX7-*, OPS-*, NEG-*) — grep for concepts in prose too |
| **Serving/deployment repo** (cluster stack) | Score on integration features (VLLM-*, GPU-CAP-02, OPS-*) |
| **Mixed** | Score all, weight by what the repo *claims* to be |

A repo that claims "idle power optimization" but is type 3 (deployment only)
should be judged against integration features, not dinged for missing research.

## Phase 1 — Automated sweep (agents: grep; humans: search)

For each feature in `features.yaml`, run its `signals.code` patterns against
the target (filename + content). Rules:

1. **Scope the search**: skip vendored code, lockfiles, binaries, and
   `node_modules`/`.venv` equivalents. (GB10 target repos are usually small —
   search everything else.)
2. **Prose counts for knowledge features**: for `FW-*`, `CX7-*`, `OPS-*`,
   `NEG-*` IDs, a README/docs mention with correct substance = "present".
3. **Commands count as implementation**: a repo shipping `nvidia-smi -lgc`
   inside a script or a README copy-paste block both count as `present` for
   GPU-CAP-01 — but check Phase 2 for *correctness* before crediting.
4. Record: feature ID → hit location(s) → tentative status.

Tentative status mapping:
- signal found in executable code → candidate `implemented`
- signal found only in docs/comments → candidate `documented`
- nothing found → candidate `absent` (confirm manually if the feature is
  `tier: core`)

## Phase 2 — Manual verification (the part grep cannot do)

For every candidate `implemented`, open the hit and check **correctness**.
The registry's `verify` field and `anti_signals` exist for this. Common
wrong implementations to look for (each is a finding, not a pass):

| Wrong pattern | Why it's wrong | Affects |
|---|---|---|
| Cap written without `auto_select=0` first | CPPC autonomous mode ignores scaling_max_freq — silent no-op | CPU-CAP-01/02/03 |
| P/E split by hardcoded core indices | Bins vary (3900/3978/4004) and clusters interleave — breaks across units | CPU-DETECT-01 |
| `scaling_min_freq` raised together with max | Kills the idle floor — loses the whole idle win | CPU-CAP-01/02 |
| Idle detection keyed on `utilization.gpu` or `power.draw` alone | Parked NCCL kernel reads ~96 % util at ~15 W — never idles | VLLM-IDLESIG-01 |
| Idle/CPU verification via `ps -o %cpu` | Cumulative-since-start — reports startup work as load | MEAS-CPUTRAP-01 |
| Fan control shipped casually | Exists (EC/FF-A) but accepted-risk territory; no safety story = red flag | FW-EC-01 |
| Clock cap without persistence (no systemd oneshot / boot hook) | Cap dies at reboot; post-thermal-shutdown boot returns to full clock | GPU-CAP-01/02 |
| `-lgc` with both numbers set to the cap (no floor headroom) | Pins instead of caps: blocks idle downclock | GPU-CAP-01 |
| Static idle-floor lock shipped unconditionally (e.g. `-lgc 208,208` at boot) | Serves tokens at the idle floor; the floor lock must be idle-conditional with release on activity | GPU-IDLELOCK-01 |
| Two writers of the same control node (governor + static cap) | Last-writer-wins races; reset undoes the other | GOV-STATIC-01 |
| CX7 `debug_state` automation without cable-stability/panic caveat | mstflint-after-hotplug = kernel panic (mstflint#1786) | CX7-DOMAIN-01/PORT2-01 |
| ASPM without SSH-path caution / console lifeline | r8127 is typically the only mgmt path; powersupersave can drop it | PERI-ASPM-01 |
| Claims any NEG-KNOWLEDGE-01 item as a guaranteed win | Measured ≈ 0 (pollers on lean images), firmware-bound (vcore), or dead (DTPM/VDDQ) | NEG-KNOWLEDGE-01 |

Also check **safety posture** on any live-node mutation feature: baseline
snapshot, revert path, watchdog/timeout, canary (GOV-SAFETY-01). A lever with
no revert path is `implemented (unsafe)` at best.

## Phase 3 — Coverage scoring

For each feature ID, final status:

| Status | Meaning |
|---|---|
| `implemented` | Correct mechanism + correct usage (Phase 2 passed) |
| `implemented-unsafe` | Mechanism present, missing guardrails (no revert/verify) |
| `implemented-wrong` | Mechanism present but the wrong-pattern table (Phase 2) applies |
| `documented` | Described correctly in prose, no code |
| `mentioned` | Named but without actionable substance |
| `absent` | Not found |
| `contradicted` | Target asserts something the landscape evidence refutes (cite both) |

Then compute, per category and tier:

```
coverage(category) = implemented / (all core+valuable features in category)
red_flags          = count(implemented-wrong) + count(contradicted) + unsafe-on-core-features
```

Weighting guide (tune to the review's purpose):
- Thermal stability focus → weight GPU-CAP-01/02, OPS-SOAK-01, GOV-LOOP-01
- Idle power focus → weight VLLM-SPIN-01, PERI-ASPM-01, GPU-IDLE-01, CPU-GOV-01
- Cluster 24/7 focus → weight VLLM-*, OPS-UNIFORM-01, GOV-SAFETY-01, CX7-*
- Research quality focus → weight FW-*, NEG-KNOWLEDGE-01, MEAS-*

## Phase 4 — Verdict

Write the one-paragraph verdict in this shape:

> `<target>` is a **<type>**-style repo covering **<N>/<core>** core
> capabilities and **<N>/<valuable>** valuable ones. Strongest area:
> **<category>**. Critical gaps: **<top 3 IDs>**. Red flags: **<IDs + one
> line each>**. Unique contributions not in this registry: **<list — these
> are valuable, feed them back into features.yaml>**.

The last item matters: anything the target does that the registry lacks should
be proposed as a new feature ID (registry is versioned for exactly this).

---

## Agent execution notes

- Do Phase 0–1 in one pass: `grep -rInE` (or rg) each `signals.code` pattern,
  collect file:line, then batch-read hits for Phase 2.
- Trust ordering: `verify` evidence in target code > docs claims > README
  marketing. Where they conflict, note it as a finding.
- Do not penalize `absent` on `tier: advanced` — list under "growth surface".
- Cap the report at ~2 pages: table + red flags + verdict. Attach raw hit
  lists as an appendix, not inline.
- If the target is private/local, record the path; if remote, record commit
  hash audited.

## Human quick-pass (15-minute version)

1. Read the target's README → classify (Phase 0).
2. Search for: `lgc`, `scaling_max_freq`, `auto_select`, `busy_loop_s`,
   `powersupersave`, `debug_state`, `systemd` — that's GPU-CAP-01,
   CPU-CAP-01/03, VLLM-SPIN-01, PERI-ASPM-01, CX7-DOMAIN-01, GPU-CAP-02 —
   the six capabilities that separate serious from casual.
3. Check the wrong-pattern table (Phase 2) on whatever you found.
4. Fill the template's core-tier rows + verdict.
