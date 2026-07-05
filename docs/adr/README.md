# ADRs — inherited from the Yggdrasil hub

Bifrost does **not** hold its own ecosystem constitution. The authoritative ADR/CES record lives in the
hub repo **`RasmusTho/agentic-pkm-mvp`** under `docs/adr/`. The ADRs that govern this repo:

- **ADR-0050** — cross-repo governance (Bifrost is a governed constituent), the Bifrost name, and the
  traditional-Swedish-spelling register (Heimdal, Bifrost). *This is the ADR that establishes this repo.*
- **ADR-0049** — Heimdal ingestion organ + native-app **topology C** (one shell, two bounded clients).
- **ADR-0044** — acknowledged System-of-Systems + private-bindings-outside-public-repo precedent.
- **ADR-0043** — Norse name register.

Only add an ADR **here** if a decision is genuinely Bifrost-local (e.g. a Swift-stack build/architecture
choice with no ecosystem scope). Cross-repo or ecosystem decisions route through the hub's CES/ADR process.
