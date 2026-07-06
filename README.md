# Bifrost

**Bifrost** is the native-app client surface of the **Yggdrasil** personal agentic ecosystem — the bridge
(guarded by **Heimdal**) between the human and the ecosystem's constituents.

It hosts the client apps under **topology C** (one shell, two bounded clients):
- **Heimdal client** — capture / consent / device-health · iPhone + Apple Watch.
- **Mimer client** — knowledge: chat, review, entity confirmation, settings · iPhone + **iPad-first**.

## Governance — a governed constituent, not a detached project
This repo inherits ecosystem governance and is developed by the same **Builder System** (per **ADR-0050**):
- **Authority:** ecosystem CES/ADR in `RasmusTho/agentic-pkm-mvp` (`docs/adr/`) — esp. **ADR-0049**
  (topology C, markdown-first control surface) and **ADR-0050** (cross-repo governance + this repo's
  naming + Swedish-spelling register). No separate constitution.
- **Development:** the Builder System's Issue/PR contracts, delivery skills, labels, and CI extend here,
  adapted for Swift / iOS / iPadOS / watchOS.
- **The record stays markdown:** the apps are **lenses over the same Obsidian vault** (`.md` is the source
  of record); Obsidian is retained; **no capability is app-only**. Each client binds only to its own
  constituent's contract — clients over contracts, never a merger.

## Status
Builder-System governance scaffolded (setup `RasmusTho/agentic-pkm-mvp#3055`): `AGENTS.md` (inherited
authority), Issue/PR contracts, delivery-skill routing + shared contracts (`.codex/skills/`), the label
taxonomy, and Swift/iOS CI (`.github/workflows/ci.yml`).

B1 (bifrost#1 / hub `RasmusTho/agentic-pkm-mvp#3023`) has landed the `Yggdrasil.xcodeproj` app shell +
Mimer-iPhone client — the Swift build/test/lint gate is now a real hard gate (see `Yggdrasil/README.md`
for the app's structure). B2 (Mimer-iPad) and B3 (Heimdal-iPhone + Watch) are not yet built.

App slices: Epic B (#3020) → B1 (#3023) shell + Mimer-iPhone (landed) · B2 (#3024) Mimer-iPad · B3 (#3026)
Heimdal-iPhone + Watch.

## Repository layout
- `AGENTS.md` — builder-agent instructions; ecosystem authority inherited from the hub.
- `.codex/skills/` — delivery-skill routing + `_shared/` Issue & label contracts.
- `.github/` — Issue template, PR template, CI.
- `docs/adr/` — pointer to the hub ADR record (ecosystem constitution is not forked here).
- `Yggdrasil/` — the Xcode project: the Yggdrasil shell + Mimer-iPhone client (B1).
- `Packages/YggdrasilCore/` — the platform-agnostic Swift package (frontmatter/markdown parsing,
  `_heimdal/**` note models, vault path resolution) the app target depends on; `swift test` runs its
  unit tests without needing a simulator.
