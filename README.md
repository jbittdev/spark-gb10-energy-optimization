# spark-energy-optimization

Power, thermal, and efficiency knowledge for the NVIDIA GB10 platform
(NVIDIA DGX Spark / ASUS Ascent GX10 and siblings), compiled into a
testable capability registry. Built for people running sustained inference
(24/7 agents, tensor-parallel clusters, resident vLLM) who need the box to
stay cool, quiet, and alive without giving up serving capability.

## What's here

```
FINDINGS-LANDSCAPE.md    every known finding: platform facts, ranked levers,
                         SPBM firmware surface, measurement methodology,
                         myths vs reality, negative results, sources
registry/
  features.yaml          capability registry: 57 discrete, testable features
                         (v2) with detection signals, verify methods, tiers
audit/
  AUDIT-PLAYBOOK.md      procedure for comparing any target repo against the
                         registry (agent-automatable; human quick-pass included)
  AUDIT-TEMPLATE.md      output format for an audit
tools/
  pii-lint.sh            privacy lint (class-based, no private literals) —
                         run before every commit
```

## Two ways to use this repo

**1. Apply the findings** — work from `FINDINGS-LANDSCAPE.md`: §0 for the
platform facts that constrain everything, §1–§5 for the ranked levers, §6–§7
for the firmware and governor surfaces, §8 for measurement methodology, §12
for dead ends not worth re-chasing.

**2. Audit another repo** — run `audit/AUDIT-PLAYBOOK.md` against the target,
fill `audit/AUDIT-TEMPLATE.md`, write the result to
`audit/results/<target>-AUDIT.md`. The registry's detection signals are
grep-able so an agent can execute the whole comparison autonomously.

## Registry design notes

- **Stable IDs** (`GPU-CAP-01` etc.) are the citation currency: issues, PRs,
  and audits reference IDs, not prose.
- **Tiers**: core (serious repos have them) / valuable (situational) /
  advanced (expert surface — absence is never penalized).
- **`anti_signals`** mark known *wrong* implementations — a hit can be a
  finding, not a pass. The playbook's wrong-pattern table is the manual
  counterpart.
- **Versioned** (`version: 2`): audits of other repos that contribute new
  capabilities bump the version and append new IDs.

## Conventions

- New findings land in `FINDINGS-LANDSCAPE.md` first, then get promoted to
  registry IDs.
- Measurements are published as banded values per the banding policy in
  `FINDINGS-LANDSCAPE.md` §8 — band first, then paste.
- Run `tools/pii-lint.sh .` before every commit — zero FAIL required; WARNs
  get individual review. The lint detects *classes* only (no private
  literals), so it is safe to ship inside this public repo itself.

## Licenses & attribution

This repo is licensed under the MIT license — see `LICENSE`. Use it, fork it,
ship it; keeping the copyright notice is the only ask. The community projects
cited in `FINDINGS-LANDSCAPE.md` §14 are already public and are credited
there. This repo documents findings only — no kernel modules or executable
artifacts are distributed with it.
