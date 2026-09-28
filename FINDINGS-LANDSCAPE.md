# GB10 / NVIDIA DGX Spark (ASUS Ascent GX10) — Power & Thermal Optimization Landscape

Purpose: capture **every known method** for reducing power draw, managing heat,
and improving efficiency on the NVIDIA GB10 platform (DGX Spark / ASUS Ascent
GX10 and siblings), assembled from first-party measurements, source-level
research of NVIDIA's kernel fork, and community data. Target audience: people
running sustained inference (24/7 agents, TP clusters, resident vLLM) on GB10
who need the box to stay cool, quiet, and alive without giving up serving
capability.

Reading guide: §0 platform facts · §1–§5 the levers (GPU clocks, CPU caps,
serving-stack idle behavior, measured results, fabric) · §6–§7 firmware and
governor surfaces · §8 measurement methodology · §9–§10 stability and
peripherals · §11 myths · §12 negative results · §13 open questions · §14
sources.

---

## 0. Platform facts that constrain everything

| Fact | Detail | Consequence |
|---|---|---|
| SoC | GB10 (Blackwell GPU + 20-core Arm: 10× Cortex-X925 "P", 10× Cortex-A725 "E"), 140 W TDP class, 1.13 L chassis | Cooling is firmware-controlled; chassis, not the chip, is the bottleneck |
| Memory | 128 GB LPDDR5X-9400 unified (no VRAM); ~273 GB/s bandwidth ceiling | Decode is bandwidth-bound → clock caps are nearly free for decode |
| GPU stock clock | 3003 MHz boost | Default boots full-speed; caps do NOT persist across reboots |
| CPU stock | P-cores 3900–4004 MHz (floor 1378 MHz), E-cores 2808/2860 MHz (floor 338 MHz); bins vary by unit/OEM (3900/3978/4004 reported) | Detect P/E by largest gap between distinct `cpuinfo_max_freq` values, never by core index; core numbering is interleaved |
| `nvidia-smi -pl` | N/A on GB10 | "No power limit" is false (see SPBM, §6) |
| Fan control | No OS API via nvidia-smi; EC fan service exists (see §6.3) | Don't build on fan control; build on clocks/caps |
| P/E layout | P = cpus 5–9, 15–19; E = cpus 0–4, 10–14; clusters interleave (2 P + 2 E clusters per SPBM telemetry) | `taskset`/affinity and cap scripts must discover, not hardcode |
| Idle floor (drained) | ~12–16 W sys_total measured (varies by ambient/day); SoC uncore ≈ 10–11 W invariant | Uncore is firmware-bound; OS levers only touch the rest |
| Resident CUDA context | ANY context (even ~100 MB, 0 % util) forces GPU P0/1391 MHz, +1.6 W gpu rail; releases instantly on context death | The GPU "idle floor" on serving nodes is context residency, NOT clock caps — cap relaxation will not lower it |
| vLLM + GB10 quirks | `gpu-memory-utilization` ≈ 0.85 max (hard reboot near 0.95 during graph capture); `nvidia-smi` mem% fields unsupported (UMA) | Ops guidance belongs in the repo |
| Secure Boot + lockdown | On by default; unsigned kernel modules are a dead end | MOK enrollment is the sanctioned path for local modules |

---

## 1. GPU clock capping (thermal protection — the headline fix)

**Problem.** Sustained 24/7 inference at 96 % util → high-70s–80s °C, periodic
thermal shutdowns (some units die at lower temps — power-delivery instability;
one forensic report found driver alloc failures at only 60 °C). MoE decode is
~45 W but concurrent prefill bursts spike 45→75 W in seconds.

**Fix: `nvidia-smi -lgc 300,2200`** (cap SM clock at 2200 MHz):
- Before: high-70s–80s °C, sustained shutdowns → After: mid-to-high-60s °C, zero shutdowns
- Perf cost ≈ zero for MoE decode (memory-bound); decode is link- and
  clock-independent (±3 %), prefill pays (+3.9 % @ 2200, +13 % @ 1800 — a
  decode-only benchmark will falsely report the cap as free)
- Community sweet spot: **2000–2300 MHz** depending on ambient + unit
- Units reported aborting near ~75 W GPU rail at temps far below the ~95 °C
  trip point → the cap is also a **power-delivery** guard, not just thermal

**Persistence.** Cap does not survive reboot (and a thermal-shutdown cycle
boots straight back to 3003 MHz). Ship a systemd oneshot:
```ini
[Unit]
After=nvidia-persistenced.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/nvidia-smi -pm 1
ExecStart=/usr/bin/nvidia-smi -lgc 300,2200
[Install]
WantedBy=multi-user.target
```

**Related GPU knobs:**
- `nvidia-smi -lgc <min>,<min>` while idle; `nvmlDeviceResetGpuLockedClocks` on demand
- `nvmlDeviceSetPowerMizerMode_v1(ADAPTIVE)` — new NVML API in 580+; may be rejected, harmless to try
- **Idle clock floor lock** — `-lgc 208,2200` (serving form; 208 is the RM hard
  minimum, lower values clamp to it) holds a resident context near ~1 GHz while
  idle and releases the ceiling on activity: measured ≈2.5 W/node (≈10 W
  multi-node), over-delivering rail-level predictions — suspected DVFSRC/uncore
  coupling. Must ship **conditional** (idle-keyed daemon): a static floor-lock
  serves tokens at the floor. Costs: first request after long idle can pay
  ~250 ms TTFT (poll-interval bound; tune poll or raise the idle floor), and
  re-check clocks after release — a post-release app-clock wedge (~5 W
  residual at 0 % util) was observed once
- Clock-offset "undervolt": lock clock, then positive GPC offset via
  `nvmlDeviceSetClockOffsets` (driver ≥ 555) — runs that clock at a lower
  voltage point; 0 W idle value, 5–15 W under load. No VF-curve editor on Linux.
  Silent-corruption risk: validate with a determinism envelope + token-garbage
  detector, step +25 MHz, back off 50. Memory clock/memlock is NOT exposed on
  the unified LPDDR5X controller (expect NOT_SUPPORTED) — DRAM operating point
  is firmware-only
- Phase-based caps: prefill at the 2200 knee, decode drops to ~1700, switched
  off vLLM prompt-token rate (the closed-loop governor does this)
- Watch for `nvidia-modeset/kthread_q` wedged at 100 % after monitor hotplug
  on a long-headless box (clean boot fixes; monitor-at-idle costs ≈ +0.4 W)

**Headless fan bug:** some units don't spin fans in headless boot mode —
verify fans actually run. ASUS firmware v0103 reportedly −8–10 °C + better CX7
links (verify current firmware first; torn driver/firmware pairs brick).

**Low-power stuck state after a thermal event:** P8 / 5 W / 0 % util limbo →
full power cycle, battery disconnected 5 min, usually clears.

---

## 2. CPU frequency caps, governors, scheduling

### 2.1 Static caps (scaling_max_freq)
- `scaling_max_freq` is a **ceiling**; never touch `scaling_min_freq` → cores
  still idle to hardware floors (1378 MHz P / 338 MHz E). "Lose top-end clock,
  not idle behaviour."
- Cap **P-cores only** for best thermal-per-MHz (E-cluster draws ~10 W of a
  ~92 W package at stock; clipping E-cores buys little). Start ~3.2 GHz, walk down
- All-core cap (`gb10-allcore-cap 1800`): P **and** E ≤ 1800; second arg caps
  E-cores independently (`gb10-allcore-cap 2000 1600`). E-cores run
  housekeeping → clamp them harder than P-cores
- Requires `auto_select=0` per policy first (CPPC autonomous mode would ignore
  scaling_max_freq — a silent no-op if skipped)
- Anything under 1378000 kHz clamps up to the floor
- Persist via systemd oneshot (After=multi-user.target suspend.target
  hibernate.target; ExecStop= reset)

### 2.2 Governor / EAS
- DGX OS ships `performance` on all 20 policies. At idle it barely matters
  (idle cores sit at min); the real prize: **switching to `schedutil` turns on
  Energy Aware Scheduling** — small wake-ups land on E-cores (338 MHz floor)
  instead of P-cores (1378 MHz floor). Bigger idle effect than the frequency
  choice itself. EAS preconditions all hold on GB10 except the governor
- Autonomous CPPC mode + EPP=255 hands control to MediaTek MCUPM firmware with
  finer granularity than the kernel tick (`auto_select`,
  `energy_performance_preference_val`, `min_perf/max_perf`, `auto_act_window`,
  module param `cppc_cpufreq.auto_sel_mode=1`)
- **Measured negative:** vcore is governor-invariant (≈3.7 W across 5
  governors, vLLM resident) and frequency-invariant at idle (0 delta at 338 MHz
  cap) → vcore ≈ 3.7 W is firmware-state-bound; no OS prize here
- `perf_limited` CPPC register (NVIDIA SAUCE): tells you when the *platform*,
  not the OS, is capping frequency — essential diagnostic when tuning SPBM caps

### 2.3 Other CPU-side levers
- **uclamp**: a spinning thread reports util 1024 → schedutil maxes the clock.
  Put vLLM in a slice, `cpu.uclamp.max` it (or clamp only while governor is in
  IDLE state) — makes any unpatchable spin cheap. Works inside vendor containers
- **ACPI "Processor" cooling device**: 3 states × −20 % max freq via frequency
  QoS — survives governor changes that would rewrite scaling_max_freq
- **P-core offlining** (only if cpuidle offers nothing deeper than WFI; GB10
  has LPI-0..3, so usually unnecessary): keep E-cores + 2 P-cores online
- DTPM (kernel-enforced µW CPU cap) is compiled in but DT-instantiated → dead
  on ACPI; would need an in-tree patch. Highest-ceiling untapped lever, blocked
- MPAM/resctrl backported: cap a background job's memory bandwidth share
- **Serving-thread P-core affinity**: decode is host-launch-bound; letting
  vLLM/NCCL threads float onto E-cores (338 MHz floor) costs decode headroom.
  Pin serving/NCCL threads (cpuset/taskset) to P-cores — discovered via
  cpuinfo_max_freq, never hardcoded indices

---

## 3. vLLM / inference-stack idle behavior (biggest cheap win)

Three distinct idle bugs on multi-node TP deployments:

1. **CPU spin — `shm_broadcast.SpinCondition`** spins with `sched_yield` for
   `busy_loop_s` (default 1.0 s) after every read; any periodic wake-up keeps a
   core pegged forever per reader process. Measured on-cluster: `VLLM::Worker_TP`
   40 %+ CPU + EngineCore 15 %+ + ~8,000 IRQ/s with **zero traffic**.
   - Fix: plugin/patch sets `busy_loop_s=0.002` (+ `VLLM_SLEEP_WHEN_IDLE=1` on
     older builds). Community numbers: **−73 % idle CPU, −24 °C SoC**; measured
     cluster result: Worker 40 %+ → 0–5 %, kcompactd gone, **~−10 W multi-node idle (UPS)**,
     idle temps down
   - Deployable as a vLLM general plugin (entry point `vllm.general_plugins`)
     pip-installed into a derived image, or `docker cp` + pip into the
     container's writable layer
   - **vLLM v0.28.0 is idle-clean natively** (post-busy-window it parks in a
     blocking zmq poll bounded by 5 s): EngineCore single digits %, IPI ~100/s vs
     ~1,500/s unpatched. Retest before building patched images on newer upstream
2. **GPU pinned at max clock while "idle" under Ray** (forum 365325/358755):
   idle workers hold ~2.4 GHz / 100 % util. Fixes in order: run multi-node
   **without Ray** (`--nnodes/--node-rank/--master-addr`, mp backend); if Ray
   + PP>1 is required, `VLLM_USE_RAY_COMPILED_DAG_CHANNEL_TYPE=shm`; blunt
   fallback: governor GPU clock lock while no requests in flight
3. **Idle death of the no-Ray path** (vllm#42742): NCCL watchdog SIGABRTs a
   worker after long idle → `TORCH_NCCL_HEARTBEAT_TIMEOUT_SEC=86400` or
   `TORCH_NCCL_ENABLE_MONITORING=0`

Also: disable Ray dashboard/usage stats; Ray daemons poll constantly. Don't
use `utilization.gpu` as an idle signal (parked NCCL kernel reads ~96 % at
~15 W); use the scheduler gauges (`num_requests_running+waiting == 0`).

**Throughput-relevant efficiency notes** (adjacent but they shape the
power/perf tradeoff): decode on GB10 is host-launch-bound (dropping eager = 4×
win) → the biggest untried perf lever is raising/lifting the CPU cap, traded
against power/heat; MoE backend `marlin` beats DEEPGEMM *under* a CPU cap
(ranking may flip uncapped); `nvidia-smi -lgc 0,2000` costs prefill, keeps
decode (memory-bound).

**Serving-ops efficiency adjacent:**
- **Boot-time page-cache management** — large KV-cache allocations fail
  against a full page cache (unified memory + container caps interact badly);
  a flusher (drop_caches + compaction) with a settle window before launch
  makes the allocation reliable. Weights re-read from NVMe every boot (large
  read burst/rank) → keep-server-up is the only full fix for cold boots
- **Unattended-serving watchdog** — head-node service polling the health
  endpoint; N consecutive failures → capture logs, tear down ALL ranks, run
  the memory ritual, relaunch worker-first, wait healthy (~15-min unattended
  recovery). Rationale: no in-process engine restart exists, and container
  restart policies cannot recover a multi-node deployment — workers exit and
  blind restarts race the stale rendezvous

---

## 4. Measured idle-power levers (A/B results, one node)

Method: per-rail SPBM telemetry (see §8) or UPS wall reading; same-session
baselines; one lever at a time; drained vs resident-idle vs drained-again.

| Lever | Expected | Measured | Notes |
|---|---|---|---|
| vLLM spin fix | 2–6 W/node | **~−10 W multi-node idle (UPS)** | biggest soft win; also −temps |
| GPU idle clock floor lock (`-lgc 208,2200`, idle-keyed) | ≤1.6 W/node predicted | **≈2.5 W/node (~10 W multi-node)** | over-delivered — suspected DVFSRC/uncore coupling; conditional only, never static |
| PCIe ASPM `powersupersave` | 0.5–2 W | **≈ −3 W** (sys_total ≈ 13→10 W) | biggest single measured lever; ≈ −1 W each from prereg (PHY/links) and root ports; SSH survived; CX7 endpoints don't support ASPM (excluded); persistence = `pcie_aspm.policy=powersupersave` cmdline + multi-day soak |
| CX7 domain power-off (GPIO, all-or-nothing) | ~18 W (uncabled) | **≈ 20 W** (full-node wall draw dropped ~20 W, cable stays inserted) | see §5; kills fabric → not for serving nodes |
| Resident CUDA context | ~1.5–2 W | **≈ +1.5 W gpu rail / sys_total similar** | floor = context residency; levers are DPM=2 / TegraGpuPgMask class, not clock caps |
| Poller cleanup (cups, avahi, ModemManager, fwupd, packagekit, snapd, dgx-dashboard, ~15 timers) | 0.5–1.5 W | **≈ 0** (residual below the instrument drift floor) | gutted on this image; retest on heavier telemetry stacks |
| Governor (schedutil/powersave) | 0.3–1.5 W | **0** (vcore governor-invariant) | but EAS-on-schedutil placement win remains real for wake-ups |
| scaling_min floor (338 kHz write) | small | **0** | 10/20 cores have CPPC clamp at 1378 kHz min anyway |
| Timer slack (idea) | — | **skipped** | LPI-3 residency already >98 %, IRQs in the low hundreds — platform is idle-clean at wake-up level |
| r8127 EEE on mgmt link | 0.3–1 W | untested (SSH path risk) | keep 2nd session open |
| Headless `multi-user.target` + display unplug + `nvidia-drm.modeset=0` | ~3 W + ~3 W | known-good | ≈ +0.4 W if a monitor is attached at idle |

Expected-lever table from source-level research (per node, one CX7 port linked,
~37–43 W floor): spin fix 2–6 W · unused CX7 port 1–4 W · CPU floors+EPP+gov
0.5–2 W · headless+peripherals 3–7 W · dynamic caps 0–3 W · EAS/uclamp 1–4 W ·
GPU idle lock 0–2 W (much more if GPU refuses to downclock).

---

## 5. ConnectX-7 / fabric power

- **The whole CX7 domain (both chips, 4 PFs, 2 PCIe domains) costs ~18–20 W/node**
  with a cable present. The `MTKP0001` ACPI hotplug controller owns BOOT/PRSNT/
  PERST/**EN (power enable)** GPIOs for the package; `pcie_hotplug/debug_state`
  (0 = force plug-out / power off, 1 = restore) + `echo 1 > /sys/bus/pci/rescan`
  after removing the 4 PFs is the electrical power-off that works **with the
  cable inserted**. Round-trip is clean (links retrain, IPs restore). ~30 s to
  return to baseline wall draw
- **Unused port-2 NV config** (firmware `mlxconfig` knobs):
  `AUTO_POWER_SAVE_LINK_DOWN_P2=1`, `KEEP_ETH_LINK_UP_P2=0`,
  `KEEP_LINK_UP_ON_BOOT_P2=0`, `KEEP_LINK_UP_ON_STANDBY_P2=0`, optionally
  `HIDE_PORT2_PF=1` (needs `ADVANCED_PCI_SETTINGS=1`). Runtime:
  admin-down both port-2 netdevs (every physical port has 2 PFs — socket-direct
  wiring; both must be downed) + `mstlink --port_state DN`. Expected 1–4 W.
  Applies **only after NIC reset**; do NV changes right after boot with cable
  state stable (mstflint-after-hotplug = kernel panic, mstflint#1786)
- **Driver power-throttle trap**: 580.126.09 reports insufficient PCIe slot
  power (27 W) → NIC throttled to ~13 Gb/s (or stuck throttle after cable
  hot-swap). Fix: driver ≥ 580.142 (or 580.173.02) / reboot. Canary:
  `lspci -vvv` LnkSta vs LnkCap, baseline `ib_write_bw` per link half
- **Breakout DAC low-power trap**: passive DACs on QSFP-DD breakout switches stick
  at low power/half rate → force `auto-negotiation=no speed=<rate>` on master
  subports (switch side), pin node side too
- **Rate sweep idea** (untested): drop fabric link rate (both ends, switch +
  `PHY_RATE_MASK`) for power; 200G pays only on cold prefill/aggregate — decode
  is link-independent (±3 %)
- **Second socket-direct link reduction** (documented only): the CX7 hangs off
  two Gen5 x4 host links; removing the second domain's PFs and Link-Disabling
  its root port (setpci Link Control; restore = clear + rescan) saves ~1–2 W
  and caps host↔NIC to ~110 Gb/s — decode is latency-bound (kB/step) and
  won't notice; long-prefill all-reduces might. Pin `NCCL_IB_HCA` to the
  surviving device so NCCL doesn't wait on the removed one. A gentler variant
  (host-PCIe gen downshift, est. 5–14 W) risks failed-retrain fabric drops —
  maintenance windows only
- **Linked-port non-levers**: MTU/flow-control/interrupt-moderation don't
  touch the SerDes cost; ASPM never engages on the active link while NCCL
  traffic flows; speed-down breaks the 200G requirement
- **Fabric health canaries**: error-counter deltas (err/drop/retrans/
  out_of_seq/PFC/ECN) before vs after sustained load — growth means PFC/ECN
  is missing and throughput throttles; DOM rx/tx power margins catch lane
  degradation before bandwidth loss; GID tables drift after reboots (re-check
  or set IB GID auto-detect)
- MTKP0001 `debug_state` write lagged wall-meter by a few s (PMIC settle) —
  wait before measuring

---

## 6. SPBM firmware surface (the "impossible" knobs)

MediaTek SSPM "System Power Budget Manager" — shared-memory window with
per-rail telemetry **and** writable power limits. Community module
`spark_hwmon` proved OS-side writes; a superset kernel module (MOK-enrolled,
read-only by default) exposes the full `_DSM` regmap.

### 6.1 Telemetry (replaces UPS guessing; drift floor 0.03 W)
Rails: `sys_total` (~12–16 W drained; ~22–25 W stock headless per community),
`soc_pkg`, `cpu_gpu`, `gpu`, `vcore`, `prereg`, `cpu_p`, `cpu_e`, 8 temp
channels, PROCHOT flag, 100 ms PID loop over EWMA power.
- **Uncore = soc_pkg − cpu_gpu ≈ 10–11 W ≈ two-thirds of SoC idle — invariant** across
  residency and states; firmware-bound
- **VDDQ/DRAM telemetry register exists but reads 0 on current firmware** →
  cannot split uncore into memory vs fabric (negative result)

### 6.2 Power-limit overrides
- `*_VAL_OS` registers for PL1–PL4, SYSPL1–SYSPL4, PL_EDPC_CPUE/CPUP + poke
  `UPDATE_SPBM` → the only true wattage lever on the platform
- Measured effective limits on one unit: package PL1/PL2 ≈ 20 W, system PL
  ≈ 30 W, elevated tier ≈ 40 W, burst tiers ≈ 250–300 W (defaults vary by
  unit/firmware) — all 3–6× above idle draw
  → caps matter for **load-shaping** (near-idle bursts, TTFT spikes), not idle
- **Agressive active cap ≈ undervolt**: firmware picks lower V/F points to hold
  a cap (e.g. SysPL1 120 W). Community clock-cap data: GPU 56→23.5 W between
  2455→1800 MHz at only 4 % decode loss; the SPBM cap gives the same trade
  without touching clocks
- 10 writable `_OS_` slots + `_EC_`/`_UEFI_` twins per rail (three override
  authorities) + `BUDGETER` controller family (W1/W2 weights, budget
  reallocation runs even fully drained) + per-rail PID gains exposed
- Restore model: PL caps revert on write-0 or reboot; keep a 4 KiB register
  snapshot as baseline

### 6.3 EC (Microchip MEC1723) via Arm FF-A — `MSFT000C` ACPI device
Services: management, **power**, battery, **thermal**, **fan** (ACPI
`PNP0C0B`), UCSI, input, time-alarm. A community member drives the fan via
"EC command 5 through the FF-A eSPI service". The power/thermal services are
where a platform power mode or fan floor would live; packet layouts are
greppable from a DSDT dump. **No fan-control experiments were run here
(accepted-risk policy) — document as "exists, unexplored".**
Sibling `_DSM` windows CPUEB/SSPM/HFRP (resources 0/2/3) are mapped but
unexplored — the only remaining path into the uncore/vcore question.

---

## 7. Closed-loop governor (the dynamic approach)

Static caps leave perf on the table when the box is cool. A per-node daemon
(`gb10-governor.py`, v1.1) implements:

- **ACTIVE loop**: holds a temperature target on the *hottest sensor* (SPBM
  per-cluster CPU temps + thermal zones + nvidia-smi), walking P-core
  `scaling_max_freq` and GPU SM cap down **independent ladders**
  (`CPU_LADDER_PCT = [100,92,84,76,68,60,52,45]` of each policy's own
  cpuinfo_max_freq — percentages, because bins vary 3900/3978/4004 MHz).
  E-cores never touched. With SPBM loaded, which ladder moves first depends on
  where the heat actually is (GPU-hot → leave P-cores alone)
- **Guards**: PROCHOT (SPBM) short-circuits the target entirely; a GPU-rail
  power ceiling catches the power-delivery failure mode (~75 W aborts)
- **Phase-based GPU clocks**: prefill runs at the 2200 MHz knee, decode drops
  to ~1700, switched off vLLM prompt-token rate
- **IDLE loop**: keys on **vLLM scheduler gauges** (not GPU util — parked NCCL
  reads 96 %), drops P-cores to powersave floor + clamps GPU cap; restores on
  first queued request; multi-node wake converges via all nodes polling the
  head's `/metrics`; fails safe to BUSY. Worker nodes run no API server →
  idle signal falls back to fabric-traffic activity (>~2 Mbit/s on the CX7
  netdev) plus NVML utilisation; optional deterministic wake via a `/wake`
  listener the front proxy POSTs before forwarding (clock restore is tens of
  ms — noise next to prefill)
- Explicit non-goals: never touches CX7 (kills NCCL/TP group), never unloads
  the model, never offlines cores, never suspends
- Fixed-pin mode: `--cpu-max-mhz 2200 --cpu-min-mhz 2200 --no-idle` (verified:
  ladder collapses to the pin; E-cores untouched); `--install` → systemd unit,
  ExecStopPost restores clocks
- Companion **mechanical-test harness** (`gb10-mech-test.py`): 4-layer safety
  (JSON baseline snapshot → in-process restore on signals → detached watchdog
  process w/ heartbeat → systemd transient backstop; aborts on temp/PROCHOT/
  GPU-rail-power/TP-canary). Answers "mechanism X runs for N minutes on a
  live node — does anything break, and does it come back exactly?" — the TP
  canary (real 1-token completions through the head's endpoint) catches
  straggler-induced NCCL timeouts before they kill the engine

### Static one-number companions (systemd oneshots, zero deps)
- `gb10-pcore-cap <MHz|reset|status>` — P-cores only
- `gb10-allcore-cap <MHz> [ecore-MHz]` — both clusters (E-second-arg = where
  savings live); run this **or** pcore-cap, never both as services
- `gb10-gpu-cap <MHz|reset|status>` — `nvidia-smi -lgc 0,<MHz>` ceiling-only;
  run this **or** the governor's GPU control, never both
- All follow the same philosophy: write the ceiling, leave the floor alone

---

## 8. Measurement methodology (what made the numbers trustworthy)

- **Per-rail wattmeter**: signed MOK + read-only MMIO sysfs shim over the SPBM
  window (`sys_total` drift floor 0.03 W; MOK is firmware-persistent, reload ≈
  2 min after reboot; no dkms, nothing auto-loads, reboot = clean slate).
  Without it: **UPS wall reading** (record before/after every state change,
  2-min settle). Note UPS includes the monitor/brick losses; absolutes carry
  ~+0.6 W monitor offset, deltas stay clean if legs match
- **A/B discipline**: one lever at a time; same-session baselines (cross-session
  drift up to 2 W ambient); drained → measure → apply → measure → revert →
  measure (residue check); two passes for spread
- **CPU measurement trap**: `ps -eo pcpu` is cumulative-since-start — after a
  relaunch it lies (108 %). Use short-window sampling (`top -bn2 -d5 -1`,
  read the second sample)
- **Wake-up census**: LPI residency + IRQ rate (`/sys/devices/system/cpu/
  cpu*/cpuidle`, states LPI-0..3, latencies 0/42/231/433 µs; arch_timer/IPI
  signatures identify spin vs timer floors)
- **Survey-first**: a read-only inventory script covering cpufreq policies,
  ASPM LnkCap/LnkCtl per endpoint, cpuidle, runtime-PM, NVMe APST, USB
  autosuspend, services/pollers, GID tables, thermal zones
- **Safety rails for sysfs-risk windows**: serial console (ttyS0) is the
  lifeline — the console is NOT revivable over SSH on a headless box
  (simpledrm, no connectors); stage a serial cable before ASPM-class tests;
  keep a second SSH session open on r8127-path experiments
- **ACPI dump**: DSDT → SPBM register names, `_LPI`, `_CPC`, EC packet
  layouts, fan methods — the static map that shows where the levers live
- **Journal forensics**: wall-clocks skew after power-off; sequence order is
  trustworthy; journalctl -b -1 proves clean vs panicked shutdowns
- **Publication banding**: measurements are written as 1–2 significant-figure
  bands, not exact values (synthetic examples of the transform: 43.7 % → 40 %+ ·
  −3.1 W → ≈ −3 W · 10.7 W → ≈ 10–11 W · 98.4 % → >98 % · 212 regs → ≈ 200 ·
  19.8 W → ~20 W delta). Exceptions kept precise because they are public
  platform facts or attributed community numbers: clock bins (3900/3978/4004),
  floors (1378/338 MHz), P-states (P0/1391, P8/208), instrument
  characteristics (0.03 W drift floor). When adding findings: **band first,
  then paste.**

---

## 9. Firmware / driver / update policy (efficiency-adjacent stability)

- **Driver minefield** (as of late 2026): 580.126.09 = 13 Gb/s NIC
  power-throttle; 580.159.03 = 3.5× perf regression + GID reorder; 580.173.02 =
  stable choice but bricks if OTA firmware pairing is torn; 580.178.04 =
  deferred (pairing conflict); 590.x = CUDAGraph deadlock; 580.142 = fastest
  decode, fixes the 13 Gb/s NIC bug but conflicts with some platform firmware
  → pin with `apt-mark hold`, stage on a test pair, `nvidia-spark-ota-check`
  before/after, full reboot between (driver holds ~100 GiB until clean reboot)
- **Platform firmware**: ASUS v0103 (Mar 2026) reportedly −8–10 °C + better CX7
  links; EC-firmware regression traced for one "painfully hot chassis" report →
  **check firmware before buying fans**; Feb-2026 hot-plug update path took
  community idle 37 W → 25 W → 22 W (CX7 hot-plug fix); fwupdmgr before
  trusting CPU power telemetry
- **EC firmware pairing with kernel version matters**; torn pairs = brick risk
- **Headless fan-spin bug** on some units: verify fans actually spin when
  running without a monitor
- **Bit-for-bit uniformity across cluster nodes** = documented order-of-2× prefill
  win (fleet sync) — the highest-leverage "efficiency" action for clusters
- **Sustained-soak test** before trusting any config: multi-hour prefill+decode,
  watch thermal zones, Clocks Event Reasons, XID/ECC; verify BMC/IPMI
  reachability per node (silent-power-off recovery path); GX10 silent-power-off
  under sustained load is the known chassis failure mode (some OEM chassis
  handle it better than others — vapor-chamber variants run 10–15 °C cooler);
  prove persistence with a one-reboot verification when no cmdline changes
  are involved
- **Failure-mode recovery lore**: post-thermal P8/5 W/0 % limbo usually clears
  with a full power cycle (battery disconnected ~5 min); a unit wedged with a
  dead power button recovers via unplug/replug; a display-stack kthread wedged
  at 100 % after monitor hotplug needs a clean boot (module unload is blocked);
  some units don't spin fans in headless boot — verify

---

## 10. Peripherals & services checklist

| Item | Action | Expected |
|---|---|---|
| Desktop stack | `systemctl set-default multi-user.target` | ~3 W |
| Display | unplug + `nvidia-drm.modeset=0` | ~3 W |
| PCIe ASPM | `pcie_aspm.policy=powersupersave` + per-device `l1_aspm=1`, runtime PM `auto` | 0.5–2.8 W |
| r8127 10GbE (mgmt) | vendor-driver `options r8127 aspm=1 eee_enable=1 eee_giga_lite=1` (policy alone isn't enough on Realtek) | 0.5–2.5 W; careful: SSH path |
| Wi-Fi7 + BT (MT7925) | rfkill block / unbind / UEFI disable (Feb-2026 UEFI has a switch → clean D3cold) | 0.5–1 W |
| USB | xHCI runtime PM auto, `usbcore.autosuspend=1` | small |
| NVMe | verify APST + deepest state reachable (`nvme_core.default_ps_max_latency_us`) | small |
| Pollers | nvsm/dcgm/dgx-dashboard exporters, snapd, fwupd-refresh, unattended-upgrades, ModemManager, cups, avahi — anything calling NVML on a timer wakes GPU+cores | ~0–1.5 W (image-dependent) |
| Kernel cmdline (reboot-only bundle) | `pcie_port_pm=force nvme_core.default_ps_max_latency_us=100000 usbcore.autosuspend=1 nvidia-drm.modeset=0 pcie_aspm.policy=powersupersave cppc_cpufreq.auto_sel_mode=1` | aggregate |
| kcompactd / memory pressure | monitor; THP/swappiness tuning if compaction episodes recur | episodic |

---

## 11. Myths vs reality (NVIDIA-claims vs measured)

| Claim | Reality |
|---|---|
| "No method to monitor CPU power" | SPBM telemetry, per rail, 100 ms |
| "No power limit on GB10" (`-pl` N/A) | PL1–PL4/SYSPL1–4 writable via SPBM `_OS_` regs |
| "No fan control from the OS" | FF-A fan service + EC command 5 (community), `PNP0C0B` exists — unexplored here by policy |
| "CX7 can only be powered down by unplugging" | `debug_state` GPIO forces EN pin with cable inserted |
| "CPU frequency can't go lower" | `scaling_min_freq` defaults above `lowest_perf`; CPPC autonomous + EPP hands the floor to firmware |
| "A clock cap costs throughput" | Decode is memory-bound: ~free for decode, costs prefill only; phase-based caps get both |
| "GPU idle floor is from the clock cap" | Floor = CUDA-context residency (P0/1391 at 0 % util); caps are irrelevant to it |

## 12. Negative results (don't re-chase these)

- Poller cleanup ≈ 0 W on a lean image (measured twice)
- Governor choice moves nothing at idle (vcore governor- and frequency-invariant ≈ 3.7 W — firmware-state-bound)
- `scaling_max_freq` → 338 kHz: zero sys_total delta (CPPC floor clamps half the cores anyway)
- Timer-slack tuning: skipped — platform already at >98 % LPI-3, low-hundreds IRQ/s
- VDDQ/DRAM telemetry register: dead on current firmware (no memory-vs-fabric uncore split available)
- EEE on the mgmt NIC: poor odds + it's the SSH path — only with console access
- DTPM: machinery present, DT-instantiation dead on ACPI (would need in-tree patch)
- Fan control: exists via EC/FF-A but explicitly out of scope here (accepted-loss risk policy)

---

## 13. Open questions / future surface

- ASPM adoption: measured ≈ −3 W; needs cmdline persistence + multi-day soak before cluster-wide rollout
- CX7 rate sweep (both ends + switch) — separate maintenance window
- CPUEB/SSPM/HFRP `_DSM` windows read-only recon — last remaining uncore path
- EC/FF-A power + thermal services recon (platform power mode, fan floor)
- DPM=2 / TegraGpuPgMask-class GPU floor levers for resident contexts (cluster-wide: every TP worker holds a context at idle)
- micro-context vs model-resident GPU floor: settled (context alone forces it)
- `prochot=1 @ pl_level=1 @ idle` register semantics (found in recon, unexplained)

---

## 14. Sources

Community sources (public — cited where their numbers appear in this file):

antheas/spark_hwmon · drowzeys/vllm-gb10-spin-wait-fix · agjs/gb10-clock-cap ·
tonyd2wild/DGX-Spark-Hard-Poweroff-Fix · eugr/spark-vllm-docker ·
digchick/dgx-spark-200g-link-fix · ThomasKaiser/sbc-bench#127 · NVIDIA/NV-Kernels
(mtk-pcie-hotplug.c, nvidia-ffa-ec.c, cppc_cpufreq SAUCE) · mstflint mlxconfig
DB + issue #1786 · vllm shm_broadcast/ray_executor/issues · NCCL proxy.cc ·
~15 DGX Spark forum threads (361845, 371302, 348562, 362513/367604, 365325,
362964/364636, 358755, 380995/372381/360020, 374275, 376039, 382065) ·
Tom's Hardware idle-power coverage · Arm learning path + SPEC GB10 submission

Licenses & attribution: this repository is MIT-licensed (see `LICENSE`). The
community projects above are already public; citing them preserves their
attribution. This repo documents findings only — no kernel modules or
executable artifacts are distributed with it.

