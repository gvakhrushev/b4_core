# Audits

**[`REGISTRY.md`](REGISTRY.md) is the record.** One row per finding, ever: what it was, whether it
is fixed, where the fix lives, and which test keeps it fixed.

| | |
|---|---|
| [`REGISTRY.md`](REGISTRY.md) | Every finding from every round. Start and finish here. |
| [`SLITHER.md`](SLITHER.md) | Static-analysis triage — live; the CI gate is calibrated to it. |
| [`archive/`](archive/) | The pre-registry narrative reports. Non-normative, unmaintained, kept for provenance. |

## Adding to it

Append rows to the registry. **Do not write a new report document** — that is the habit the
registry replaced, and the reason a reader could no longer tell which of twelve documents was
current. If a finding recurs, extend its existing row: the repeat is information about the fix.

Every `Fixed` and `Enforced` row names the test that holds it, and `script/check-citations.sh`
fails the build if that test stops existing. Reasoning belongs next to the code it explains.
