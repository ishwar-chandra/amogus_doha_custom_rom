# Documentation

Design and working records for the amogus_doha builds. `README.md` stays in the
repository root because that is what GitHub renders; everything else lives here.

| File | What it is |
|---|---|
| `../README.md` | Authoritative design record: requirements, install/flash/GApps/Magisk, Status, per-fix rationale |
| `GUIDE.md` | Step-by-step build (local and GCP), flash, GApps, root, release, troubleshooting |
| `TODO.md` | Live worklist: open hardware issues with on-device evidence, and the tuning backlog |
| `BUGREPORT.md` | On-device sweep results: defects, evidence, what was ruled out |
| `OPTIMIZATION.md` | Optimization plan of record: measured baseline, phases, success criteria, rollback |

Root-level files that must stay in the root: `README.md` (GitHub), `AGENTS.md` and
`CLAUDE.md` (agent instructions are only picked up from the repository root).
