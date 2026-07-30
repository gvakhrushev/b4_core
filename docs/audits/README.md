# Audit & security record

Every internal audit round, remediation, and static-analysis triage for B4, in one place. The
normative spec these are judged against is in [`../../spec/`](../../spec/); the security dossier
that summarizes what is and isn't proven is [`REPORT.md`](REPORT.md).

## Start here

| Document | What it is |
|---|---|
| [`REPORT.md`](REPORT.md) | The security dossier — trust model, what's proven vs. pending, and the running invariant/gate status. Read this first. |
| [`SLITHER.md`](SLITHER.md) | Static-analysis (Slither) triage and the CI `--fail-high` gate. |

## Audit rounds (chronological)

| Date | Round | Outcome |
|---|---|---|
| 2026-07-21 | [`AUDIT-2026-07-structural-leverage.md`](AUDIT-2026-07-structural-leverage.md) | Structural-leverage design review. |
| 2026-07-22 | [`AUDIT-V6.md`](AUDIT-V6.md) | No Critical/High; 6 Medium, 9 Low. |
| 2026-07-22 | [`AUDIT-V7.md`](AUDIT-V7.md) | Adversarial fan-out on V6-M-2; 5 Low, all NAV-preserving. |
| 2026-07-23 | [`AUDIT-V8.md`](AUDIT-V8.md) | No Critical/High; 4 Medium, 8 Low. |
| 2026-07-25 | [`AUDIT-2026-07-25-full-security.md`](AUDIT-2026-07-25-full-security.md) | Full security pass: 2 Critical (C-1, C-2), 4 High, 3 Medium, 6 Low. |
| 2026-07-25 | [`REVIEW-2026-07-25-agent-changes.md`](REVIEW-2026-07-25-agent-changes.md) | Review of unrequested agent fixes (NR-1…NR-6). |
| 2026-07-25 | [`REMEDIATION-2026-07-25.md`](REMEDIATION-2026-07-25.md) | Fixes for the 2026-07-25 round. |
| 2026-07-29 | [`AUDIT-2026-07-29.md`](AUDIT-2026-07-29.md) | Security scan F1–F4. F1/F2/F4 closed in `2514fd9`; **F3 (High) was left unapplied**. |
| 2026-07-30 | [`REMEDIATION-2026-07-30.md`](REMEDIATION-2026-07-30.md) | Closes **F3** (the unapplied wedge) + A1–A4 residuals + a new weight-integrity vector. Every fix fail-before/pass-after. |

## Raw scan archives

| Path | What it is |
|---|---|
| [`scans/2026-07-29-claude-security/`](scans/2026-07-29-claude-security/) | Raw output of the automated security scan behind `AUDIT-2026-07-29.md` — the finding write-ups (`F1`–`F4`), `PATCHES.md`, and the verified `F3.patch` (now applied). Kept as provenance. |

> Automated-scan output directories are gitignored at the repo root (`CLAUDE-SECURITY-*/`); the
> markdown/patch provenance worth keeping is promoted here under `scans/`, the raw JSONL logs are not.
