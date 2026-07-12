# Yggdrasil app — as-built walkthrough (B1, shipped)

**Date:** 2026-07-11 · Source: the actual SwiftUI code in the `bifrost` repo (`Yggdrasil/Yggdrasil/`).
This is what runs on the owner's iPhone today. Read together with `BIFROST_APPS_DESIGN_BRIEF.md`.
No screenshots are attached — the app builds only via CI/simulator on another machine — so this
walkthrough is the visual source of truth; treat it as accurate.

## 1. Navigation structure

```
YggdrasilApp
 └─ RootView — plain state router (no NavigationStack at this level)
     ├─ AuthGateView            — until local auth unlocks
     ├─ VaultPickerView         — unlocked but no active vault
     └─ MimerShellView          — unlocked + vault active
         top safe-area inset: VaultSwitcherBar (vault name + "Switch" button)
         TabView, 6 tabs:
          1. Today      → AttentionLensView
          2. Interests  → InterestsLensView
          3. Entities   → EntityConfirmLensView
          4. Consent    → ConsentLensView (read-only)
          5. Vault      → NoteBrowserView (own NavigationStack; folders push
                          recursively; files push NoteDetailView)
          6. Settings   → SettingsLensView
```

## 2. Screens and their states

1. **AuthGateView** — lock-shield icon + "Yggdrasil" title. `locked/authenticating` → spinner;
   `unavailable(reason)` → error text + "Try Again". No biometry enrolled → auto-unlocks
   (deliberate fail-open for a single-user local vault).
2. **VaultPickerView** — NavigationStack "Yggdrasil". Recents → adaptive LazyVGrid of `VaultTile`
   cards (folder icon, name, relative "last opened"); none → styled `YggEmptyState`
   ("No Vault Yet"). Primary button "Choose a Vault Folder" → `UIDocumentPicker` folder sheet
   (visual pick, no typed path — the dyslexia-safe pattern, held here). Errors: inline red text.
3. **MimerShellView / VaultSwitcherBar** — folder icon, vault display name, "Switch" (closes vault,
   back to picker). No own loading/error state.
4. **AttentionLensView (Today)** — List: "Today's Overrides" (inline empty text), "Counts"
   (key/count rows), "Steer Attention" — **two plain text fields (item id, reason)** +
   "Mark Attended"/"Mark Skipped" buttons (disabled until an id is typed). Load error = red text.
   Missing file treated as valid empty state.
5. **InterestsLensView** — Form: "Interest Weights" (name + Slider 0…1), "Watching" (list + add
   text field), "Never" (read-only list, no add/remove affordance).
6. **EntityConfirmLensView (Entities)** — List of pending mentions: surface form, confidence %,
   candidate entity IDs, Merge (prominent) / Reject (bordered). Empty → `YggEmptyState`
   ("Queue Clear"). Phone form only — no side-by-side comparison; merge takes the first candidate
   by default (the iPad spec explicitly removes that default).
7. **ConsentLensView** — read-only: "Grants" (scope/basis/grantedAt) + a static "Dormant in v1"
   section listing withhold-review/erasure flags as labels. No edit affordance (by design).
8. **NoteBrowserView (Vault tab)** — recursive folder/file list from vault root. Empty folder →
   plain text. Error → red text.
9. **NoteDetailView** — read mode via `MarkdownRendererView`; Edit swaps to a monospaced
   `TextEditor` over raw markdown + "Save"/"Saving…". Edit disabled if load failed. **No dirty
   indicator, no cancel/discard, no save confirmation.**
10. **SettingsLensView** — Form: Stepper for retention window (1–365 days, autosaves on change) +
    NavigationLink to raw `settings.md` in NoteDetailView.
11. **MarkdownRendererView** — pure block renderer: h1–h3, paragraphs, bullet/numbered lists,
    blockquotes (left rule), code blocks (monospace card), divider. Inline bold/code/links ride on
    SwiftUI `Text` markdown; no tables, no callouts, no wikilinks.

## 3. Design-token inventory (`DesignSystem/Theme.swift`)

- **Colors** (all system-dynamic, zero custom hex): background/secondary/tertiary =
  `systemBackground` tiers; accent = `Color.accentColor`; text = `primary`/`secondary`;
  divider = `.separator`; warning = `.orange`; success = `.green`.
- **Spacing:** xs 4 · sm 8 · md 16 · lg 24 · xl 32 pt.
- **Radius:** card 14 · control 10.
- **Typography** (all Dynamic-Type system fonts, no custom family): title = `.title2.semibold`;
  sectionHeader = `.headline`; body = `.body`; caption = `.caption`; monospaceBody =
  monospaced `.body`.
- **Component library (complete list):** `YggCard` (rounded secondary-bg container — used only by
  vault tiles so far), `YggSectionHeader`, `YggEmptyState`, `YggPrimaryButton`
  (borderedProminent, full width). Nothing else: no secondary/destructive button, no chip/badge,
  no toast, no banner, no sheet styling. All icons are SF Symbols.

## 4. Known defects & observed issues (pre-found — start past these)

From the shell-completion spec (documented defects):
- **D1** Attention-lens audit trail can misstate what the human actually did (override recorded
  incorrectly) — a trust/legibility defect in the S2 journey.
- **D2** A numbered-list markdown form mis-renders.
- **D3** YAML leading-zero values (e.g. `007`) can silently change on save — silent data mutation,
  violates the never-silent rule in spirit.

Observed in code (designer-relevant roughness):
- **O1** "Steer Attention" requires **typing an item id into a text field** — an id-entry chore
  that collides head-on with the no-typed-identifiers/dyslexia-safe rule; steering should be a
  gesture on a visible item.
- **O2** Empty states are inconsistent: two screens use the styled `YggEmptyState`, the rest use
  plain secondary text inline.
- **O3** Error states are uniformly a bare red `Text` — no icon, no retry affordance, no banner
  pattern (each lens hand-rolls its own load/error/save scaffold; the spec itself asks for one
  shared scaffold).
- **O4** No loading states outside the auth gate; no pull-to-refresh (reload only `onAppear`).
- **O5** No confirmation or undo affordance on consequential actions (Merge/Reject, Save,
  Mark Attended/Skipped) — yet "reversible autonomy, one gesture to undo" is a ruled constraint.
- **O6** Interests "Never" list is display-only — no way to add/remove from the UI.
- **O7** Entity merge on phone defaults to the first candidate — no explicit candidate choice.
- **O8** Dark mode is inherited from system dynamic colors but never visually verified.
- **O9** No app icon / launch screen / onboarding language designed.

## 5. Slice status (what's built vs planned)

- **Built & closed:** B1 = everything in §1–§3 (bifrost #1).
- **Shell hardening in flight:** coordinated vault writes, writer provenance, review follow-ups
  (D1–D3), UAT journeys (bifrost #4–#8; mix of ready/blocked).
- **Not started:** the entire iPad canvas (bifrost #9–#13 = MIPAD-01..05) and the entire Heimdal
  capture client incl. Watch (bifrost #14–#21 = HCAP-01..07/09), plus hub-side sidecar consumption
  and closure tracking (hub #3188/#3190–#3192). None of that exists in code.

Design work delivered against this brief therefore lands at the perfect moment: before any B2/B3
screen is written, and while the B1 uplift can still ride the shell-hardening wave.
