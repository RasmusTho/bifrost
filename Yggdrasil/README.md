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

This slice does not invent a new consistency model. It follows the same discipline the hub's Python
backend (`app/heimdal/*`) already uses for every `_heimdal/**` note: **read-merge-write**, atomic
per-file writes (`String.write(atomically: true)`), and idempotent appends (a duplicate override/decision
write is a no-op, matching the backend's fold semantics). `VaultFileStore.readModifyWrite` and the
`HeimdalNote` wrappers implement this directly. iCloud's own document coordination handles concurrent
file replication between devices; this client does not add file coordination on top of that beyond the
read-merge-write discipline above, which is the same posture the existing backend already relies on — so
no new multi-writer design decision was required to land this slice. If a gap in that shared model
surfaces in practice (e.g. lost updates under near-simultaneous edits from two devices), that is hub
architecture work, not something to redesign inside this client.

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
