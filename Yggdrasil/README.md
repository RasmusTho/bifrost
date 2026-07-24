# Yggdrasil (app shell) + Mimer-iPhone client

Implements bifrost#1 / hub `RasmusTho/agentic-pkm-mvp#3023` (B1), per ADR-0049 §4 (topology C).

## Structure

- `Yggdrasil.xcodeproj` — the iOS app target (`Yggdrasil`), unit test target (`YggdrasilTests`), and UI
  test target (`YggdrasilUITests`). Depends on the local Swift package `../Packages/YggdrasilCore`.
- `Yggdrasil/App` — app entry point + `RootView` (auth → vault pick → Mimer-iPhone shell routing).
- `Yggdrasil/DesignSystem` — the shared token set (`YggTheme`) and reusable components (`YggCard`,
  `YggPrimaryButton`, etc.) any hosted client draws from instead of styling its own chrome.
- `Yggdrasil/Auth` — the local device gate (Face ID / Touch ID / passcode via `LocalAuthentication`).
  There is no server-side account; this is a single-user, local-first shell.
- `Yggdrasil/Vault` — vault selection (`UIDocumentPickerViewController` folder pick only, no path
  typing), security-scoped bookmark persistence (`VaultManager`), and vault-relative file I/O
  (`VaultFileStore`).
- `Yggdrasil/Markdown` — the generic `.md` renderer (`MarkdownRendererView`) and read/write note editor
  (`NoteDetailView`) that work over *any* vault note, not just `_heimdal/**`.
- `Yggdrasil/Mimer` — the Mimer-iPhone client: `MimerShellView` hosts one lens per A14–A19 `_heimdal/**`
  control-surface note (Attention/A16, Interests+watchlist/A18, Entity confirmation/A17, Consent/A19,
  Settings/A14), plus a generic vault browser.

`../Packages/YggdrasilCore` holds the platform-agnostic logic: the constrained-YAML codec used by
typed `_heimdal/**` wrappers, the production Yams + Tree-sitter semantic/source-range boundary used
for lossless generic-frontmatter provenance custody, `FrontmatterDocument`, and the markdown block
parser. It has no UIKit/SwiftUI dependency, so `swift build`/`swift test` exercise it without a
simulator.

## Client-over-contracts, not a merger

Every `_heimdal/**` note wrapper in `YggdrasilCore/HeimdalNotes.swift` only reads/writes the fields this
client is declared authoritative for (the human-editable half of each note's schema); every other field
is round-tripped untouched. This matters because the vault is multi-writer (Mac runtime, Obsidian, this
app) over iCloud — see "Vault write consistency" below.

## Vault write consistency (multi-writer over iCloud)

The hub's [ADR-0055](https://github.com/RasmusTho/agentic-pkm-mvp/blob/main/docs/adr/ADR-0055-vault-multiwriter-consistency-model.md) is the decided
multi-writer model for this vault. Its item 4 requires every writer to tag writes with writer identity
and timestamp; Bifrost records that attribution in each client-written note's `agent_provenance`
frontmatter. Its item 5 mechanism is this client's coordinated file access through
`NSFileCoordinator`.

`VaultFileStore.readModifyWrite` and the `HeimdalNote` wrappers preserve unknown frontmatter through
read-merge-write, use atomic replacement, and retry a known-stale snapshot. This is Bifrost's
client-side complement to the hub posture, not a replacement consistency model. The applicable
discipline is [`docs/contracts/MIMER_CLIENT_CONTRACT.md` §6](https://github.com/RasmusTho/agentic-pkm-mvp/blob/main/docs/contracts/MIMER_CLIENT_CONTRACT.md),
especially W1–W8, until the ADR-0055 substrate mechanism is fully enacted.

Generic note frontmatter custody targets full valid YAML. The current semantic boundary uses
Yams/libYAML to resolve scalar keys, tags, aliases, and merge projection; its semantic input adapts
YAML 1.2-valid punctuation and Unicode anchor spellings to same-width ASCII reference names before
composition. Tree-sitter YAML remains the concrete-source authority, so the original bytes and
source ranges are retained for every custody decision and mutation. Invalid YAML, non-mapping
documents, parser disagreement, or a non-unique source match keep the requested bytes unchanged and
emit the explicit best-effort provenance failure log. Bifrost changes only semantically proven
provenance tokens and inserts without reserializing foreign bytes. The complete parser runtime chain
is exact-version/revision pinned.

## Validation

The repo's CI (`.github/workflows/ci.yml`) runs strict SwiftLint, the complete
`Packages/YggdrasilCore` test suite, the shared Yggdrasil scheme on discovered iPhone and iPad
simulators, and a Watch companion build. The package tests cover the constrained typed-note codec,
production YAML provenance transformation, note round-tripping, and markdown parsing.
