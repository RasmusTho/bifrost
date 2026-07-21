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

`../Packages/YggdrasilCore` holds the platform-agnostic logic: the constrained-YAML frontmatter
codec, `FrontmatterDocument`, the typed `_heimdal/**` note wrappers, and the markdown block parser.
It has no UIKit/SwiftUI dependency, so `swift build`/`swift test` exercise it without a simulator.

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

## Known environment gap

This slice was built in an environment with only Xcode Command Line Tools (no `Xcode.app`), so
`xcodebuild build`/`test` and `swiftlint --strict` could not be run locally end-to-end here. What *was*
verified locally:
- `swift build` for `Packages/YggdrasilCore` compiles cleanly.
- `plutil -lint` on `project.pbxproj` plus a scripted reference-integrity check (no dangling object ids,
  every referenced source path exists on disk).
- Manual review against every opt-in SwiftLint rule in `.swiftlint.yml` (no force-unwraps, no implicitly
  unwrapped optionals, etc. — `swiftlint` itself couldn't run because `sourcekitdInProc` requires the
  full Xcode toolchain, not just the Command Line Tools).

The repo's CI (`.github/workflows/ci.yml`, `macos-14` runner with full Xcode) is the real gate for
`xcodebuild build`/`test`/`swiftlint --strict` and is the authority on whether this slice actually builds.
`Packages/YggdrasilCore`'s unit tests (`swift test`, once XCTest is available) cover the frontmatter
codec, note round-tripping, and markdown block parsing.
