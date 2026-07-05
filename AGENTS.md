State: Canonical builder-agent instruction file for the Bifrost constituent repo.
# Builder-Agent Instructions — Bifrost

Bifrost is a **governed constituent-surface repo of Yggdrasil**, not a detached project. It hosts the
native-app clients (Heimdal capture client, Mimer knowledge clients) under **topology C** (one shell, two
bounded clients). It **inherits ecosystem governance and does not fork it** (ADR-0050).

This file applies to development-time builder agents and repo automation that modify, review, or validate
this repository. It does not apply to runtime/system agents inside the product.

## Authority — inherited, not forked

The governing authority for this repo lives in the **hub repo** `RasmusTho/agentic-pkm-mvp`:

1. **Ecosystem ADR/CES record** — `docs/adr/` in the hub, especially:
   - **ADR-0043** — Norse name register.
   - **ADR-0044** — acknowledged System-of-Systems + private-bindings-outside-public-repo precedent.
   - **ADR-0049** — Heimdal ingestion organ + native-app topology C (markdown-first control surface).
   - **ADR-0050** — cross-repo governance rule (this repo is a governed constituent), the **Bifrost**
     name, and the traditional-Swedish-spelling register (Heimdal, Bifrost).
2. **SBS operating model** — `docs/architecture/SBS_OPERATING_MODEL.md` in the hub classifies this repo as
   a **Product/Runtime System surface built by the Builder System**; boundary work is classified there.
3. **Builder-System workflow** — the hub's `AGENTS.md`, `.codex/skills/`, and `docs/development/` define
   the delivery loop, TCD routing, governance proportionality, and stop conditions. They apply here,
   **adapted to the Swift/iOS/iPadOS/watchOS stack** (Xcode build + test + SwiftLint in place of the
   Python `ruff`/`mypy`/`pytest` gates).

Cross-repo decisions route through the same ecosystem CES/ADR process in the hub. This repo adds **no
separate constitution**.

## Reading order

1. Read this file first.
2. Read the governing ADRs above in the hub before touching architecture or naming.
3. Use `.codex/skills/README.md` (this repo) for the delivery-skill routing that applies here.
4. For a bounded GitHub Issue, follow the issue-to-code pickup rule (hub
   `.codex/skills/issue-to-code/SKILL.md`): select only `Status=Ready` + `agent:ready`, claim before work.

## One source of truth for tracking

Until Bifrost has its own board, Epic B (#3020), B1–B3 (#3023/#3024/#3026), and setup #3055 are tracked in
the **hub repo**. Do not double-track. When app code lands here, link the hub Issue from the PR.

## Stack adaptation

- **Build/test/lint:** Xcode (`xcodebuild`) build + test; **SwiftLint** for lint. See
  `.github/workflows/ci.yml`.
- **The record stays markdown:** the apps are lenses over the same Obsidian vault; `.md` is the source of
  record. No capability is app-only. Each client binds only to its own constituent's contract.
- **Single-user stance preserved:** one operator; the ecosystem spans repos, the human does not.

## Naming register (Swedish spelling — ADR-0050)

Canonical forms: **Heimdal** (not "Heimdall"), **Bifrost** (not "Bifröst"), **Mimer**, **Yggdrasil**,
**Midgård**, **Nifelheim**. Use these going forward in this repo.
