# Audit Result — `<TARGET NAME>`

- **Audited**: <path or URL> @ <commit/version>
- **Date**: <YYYY-MM-DD>
- **Auditor**: <agent name or person>
- **Registry version**: features.yaml v2
- **Target type** (Phase 0): tooling / research / deployment / mixed

## Verdict (one paragraph)

> <Fill from Playbook Phase 4>

## Coverage scorecard

| Category | Core | Valuable | Advanced | Red flags |
|---|---|---|---|---|
| gpu | / | / | / | |
| cpu | / | / | / | |
| inference | / | / | / | |
| firmware | / | / | / | |
| fabric | / | / | / | |
| peripherals | / | / | / | |
| governance | / | / | / | |
| measurement | / | / | / | |
| ops | / | / | / | |

## Feature detail

| ID | Feature | Status | Evidence (file:line) | Notes |
|---|---|---|---|---|
| GPU-CAP-01 | GPU SM clock cap | | | |
| GPU-CAP-02 | Cap persistence (systemd) | | | |
| GPU-IDLELOCK-01 | Idle clock floor lock (208, idle-keyed) | | | |
| GPU-PHASE-01 | Phase-based clocks | | | |
| GPU-IDLE-01 | Idle-floor diagnosis | | | |
| GPU-UV-01 | Clock-offset undervolt | | | |
| GPU-PWR-01 | GPU-rail power guard | | | |
| CPU-CAP-01 | P-core freq cap | | | |
| CPU-CAP-02 | All-core cap (E separate) | | | |
| CPU-CAP-03 | auto_select=0 first | | | |
| CPU-DETECT-01 | P/E auto-detection | | | |
| CPU-AFFINITY-01 | Serving-thread P-core affinity | | | |
| CPU-GOV-01 | schedutil → EAS | | | |
| CPU-GOV-02 | CPPC autonomous + EPP | | | |
| CPU-UCLAMP-01 | uclamp clamp | | | |
| CPU-COOL-01 | ACPI cooling device | | | |
| CPU-MPAM-01 | MPAM/resctrl mem-bandwidth | | | |
| CPU-OFFLINE-01 | P-core offlining | | | |
| CPU-FLOOR-01 | scaling_min_freq floor | | | |
| VLLM-SPIN-01 | busy_loop_s spin fix | | | |
| VLLM-RAY-01 | No-Ray / Ray shm channel | | | |
| VLLM-NCCL-01 | NCCL heartbeat guard | | | |
| VLLM-IDLESIG-01 | Scheduler-gauge idle signal | | | |
| FW-SPBM-01 | SPBM telemetry | | | |
| FW-SPBM-02 | SPBM PL overrides | | | |
| FW-EC-01 | EC/FF-A surface | | | |
| FW-DIAG-01 | perf_limited diagnostic | | | |
| CX7-DOMAIN-01 | CX7 domain GPIO power-off | | | |
| CX7-PORT2-01 | Port-2 NV config | | | |
| CX7-LINK2-01 | Second link drop / gen-downshift | | | |
| CX7-THROTTLE-01 | 13 Gb/s throttle trap | | | |
| FAB-DAC-01 | DAC low-power pinning | | | |
| FAB-HEALTH-01 | Fabric health canaries | | | |
| FAB-RATE-01 | Link-rate sweep | | | |
| PERI-ASPM-01 | ASPM powersupersave | | | |
| PERI-HEADLESS-01 | Headless posture | | | |
| PERI-R8127-01 | r8127 link power mgmt | | | |
| PERI-RF-01 | Wi-Fi/BT/USB/NVMe | | | |
| PERI-POLLER-01 | Poller cleanup | | | |
| PERI-KCMD-01 | Kernel cmdline bundle | | | |
| GOV-LOOP-01 | Closed-loop governor | | | |
| GOV-SAFETY-01 | Safety harness | | | |
| GOV-STATIC-01 | Static cap oneshots | | | |
| MEAS-AB-01 | A/B discipline | | | |
| MEAS-SURVEY-01 | Survey tool | | | |
| MEAS-CPUTRAP-01 | ps-pcpu trap awareness | | | |
| MEAS-WAKE-01 | Wakeup census | | | |
| MEAS-CONSOLE-01 | Serial-console lifeline | | | |
| OPS-DRIVER-01 | Driver pinning policy | | | |
| OPS-SOAK-01 | Sustained soak | | | |
| OPS-UNIFORM-01 | Fleet uniformity | | | |
| OPS-FW-01 | Firmware guidance | | | |
| OPS-WATCHDOG-01 | Unattended-serving watchdog | | | |
| OPS-PAGECACHE-01 | Page-cache boot management | | | |
| OPS-UMA-01 | UMA serving limits | | | |
| OPS-RECOVERY-01 | Failure-mode recovery lore | | | |
| NEG-KNOWLEDGE-01 | Negative-results awareness | | | |

Status vocabulary: implemented · implemented-unsafe · implemented-wrong ·
documented · mentioned · absent · contradicted

## Red flags (wrong-pattern table hits + contradictions)

| ID | Pattern violated | Evidence | Impact |
|---|---|---|---|
| | | | |

## Safety-posture review (live-node mutation features)

- Baseline snapshot/restore: <yes/no/unknown>
- Revert path documented: <yes/no/unknown>
- Watchdog/timeout on mutation: <yes/no/unknown>
- Serving-canary during tests: <yes/no/unknown>

## Unique contributions (not in registry — propose new IDs)

| Candidate ID | What the target does | Evidence |
|---|---|---|
| | | |

## Growth surface (advanced-tier gaps, non-penalized)

- <IDs>

## Appendix — raw grep hits

<agent: paste hit lists here; human: skip>
