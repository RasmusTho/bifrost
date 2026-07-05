# Bifrost delivery-skill routing

Bifrost inherits the **Builder System delivery-skills chain** from the hub repo
`RasmusTho/agentic-pkm-mvp` (`.codex/skills/`). The skill *bodies* are stack-agnostic delivery
orchestration and are **not forked** here; this file routes to them and records the **Swift/iOS
adaptations** that apply when building in this repo.

Load the matching skill (from the hub) before substantial work:

| Task | Skill (in hub `.codex/skills/`) | Bifrost adaptation |
|------|----------------------------------|--------------------|
| GitHub implementation from a bounded Issue | `issue-to-code/SKILL.md` | Validation = Xcode build + test + SwiftLint (see below), not `ruff`/`mypy`/`pytest`. |
| Branch / commit / push / PR publication | `publish-pr/SKILL.md` | PR contract = `.github/pull_request_template.md` (this repo). |
| PR mergeability / CI attachment | `pr-integration/SKILL.md` | CI = `.github/workflows/ci.yml` (this repo). |
| Delivery verification and closure | `verification-and-closure/SKILL.md` | `Verify:` targets resolve to Swift test symbols / build products. |
| Epic / lane / issue-set orchestration | `deliver-issue-set/SKILL.md` | Cross-repo hub is the single source of truth (ADR-0050 §1). |
| Issue / PR / label / Project lifecycle correction | `issue-maintenance-change-control/SKILL.md` | Labels mirror the hub taxonomy (`_shared/LABEL_TAXONOMY.md`). |
| Capture a BuilderOps learning signal | `capture-learning/SKILL.md` | — |

## Shared contracts (this repo)

Stack-agnostic governance contracts are mirrored under `_shared/` so this repo is self-describing:

- `_shared/ISSUE_CONTRACT.md` — the canonical Issue task contract sections.
- `_shared/LABEL_TAXONOMY.md` — the label set and meaning.

## Swift/iOS validation adaptation

The Builder System validation gate for this repo is:

- **Build:** `xcodebuild build` for the app scheme(s).
- **Test:** `xcodebuild test` (unit + UI where present).
- **Lint:** `swiftlint` (config in `.swiftlint.yml` once app sources land).

These replace the Python `ruff check` / `mypy` / `pytest -m "not pg"` gates named in the hub PR contract.
Until app sources exist, CI runs the lint/structure checks that are meaningful and states the gaps
explicitly (fail-loud on real regressions, not silent green).
