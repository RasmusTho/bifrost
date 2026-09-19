# Yggdrasil (app shell) + Mimer-iPhone/iPad client

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
- `Yggdrasil/Mimer` — the Mimer client: compact width hosts one lens per A14–A19 `_heimdal/**`
  control-surface note (Attention/A16, Interests+watchlist/A18, Entity confirmation/A17, Consent/A19,
  Settings/A14), plus a generic vault browser. Regular-width iPad uses the first three-column thinking
  canvas slice: lens sidebar, vault/lens content column, rendered note detail, and metadata inspector.

## Native design handoff binding

The Round 3 handoff is applied to the built B1 surface as visual guidance: the shared Yggdrasil palette
now has native light/dark semantic roles, serif record titles, monospaced evidence, shared loading/error/
refresh/source scaffolding, and semantic status/banner/undo components. Attention uses visible-item swipe
actions; Interests uses More/Less/Never/Restore; Entity confirmation requires an explicit candidate before
merge. On regular-width iPad the shell now uses the handoff's three-column canvas with a note-detail
inspector. The handoff remains Crossing A visual guidance, not a replacement for the hub contracts or
runtime truth.

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

## Verification

Verified locally after the handoff binding:
- `xcodebuild build` for the iOS Simulator SDK succeeds.
- `swiftlint --strict` succeeds for the checked-in app and package source/test paths.
- `swift test --package-path Packages/YggdrasilCore` passes all 16 tests.
- `xcodebuild test` could not start because this machine has no installed iOS Simulator device; CI remains
  the authoritative full build/test gate.
