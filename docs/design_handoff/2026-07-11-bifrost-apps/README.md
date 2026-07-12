# Bifrost apps — Round 3 app-level design handoff (2026-07-11)

**Authority status: Visual guidance only.** This is an imported Claude Design exploration, archived
as a handoff *input*. It is **not** architecture authority, **not** runtime truth, and **not** a
schema or acceptance-criteria declaration. Where it proposes a change to a spec'd B1 acceptance
criterion, that change is **advisory and needs an owner ruling** (see §4) — never a silent redesign.

- **Crossing:** A (archived design input; not yet through a maturity checklist / normalized spec).
- **Surface covered:** all three Bifrost app surfaces — Yggdrasil shell + Mimer-iPhone (built),
  Mimer-iPad thinking canvas (spec'd), Heimdal capture client iPhone + Watch (spec'd).
- **Source:** Claude Design project **"Bifrost apps design handoff"**
  (`9ab09635-7772-4c88-9b1a-089c09b53779`), file `Bifrost Round 3.dc.html`. Imported via the
  claude_design MCP on 2026-07-12.
- **Governance:** this repo inherits ecosystem governance from the hub
  (`RasmusTho/agentic-pkm-mvp`, ADR-0050). The hub's design-handoff chain
  (`companion-ui/docs/DESIGN_HANDOFF_GOVERNANCE.md`) applies:
  `exploration → handoff → normalized spec → issue → PR → validation receipt`. This package is the
  **handoff** link.

## 1. Package contents

| File | What it is |
|---|---|
| `Bifrost Round 3.dc.html` | The design output — the converged Round-3 proposal (canvas doc). Open in a browser to view. |
| `support.js` | Claude Design (`dc-runtime`) render script the `.dc.html` loads. Keep alongside the HTML. |
| `ios-frame.jsx` | The iOS-26 device-frame component the mockups render inside (starter scaffold; raw px/hex by design). |
| `inputs/BIFROST_APPS_DESIGN_BRIEF.md` | The entry brief — canonical naming, the eight fixed rulings (§2 walls), the three surfaces, deliverables. |
| `inputs/CLAUDE_DESIGN_PROMPT.md` | The exact prompt handed to Claude Design. |
| `inputs/CURRENT_IMPLEMENTATION_B1.md` | As-built B1 walkthrough + `Theme.swift` token inventory + pre-found defects (D1–D3, O1–O9). |

**Viewing the prototype:** open `Bifrost Round 3.dc.html` in a browser with `support.js` in the same
folder (it also needs React/ReactDOM, which the Claude Design host provides). The living version is
in the Claude Design project linked above.

## 2. What Round 3 delivered

The design is one converged proposal (no relitigation of the §2 rulings), organized into six sections
inside the canvas doc:

1. **Design system** — the Yggdrasil palette mapped onto native iOS structure; keep/extend/replace
   against the existing `Theme.swift` tokens; the **shared lens scaffold** (one load/empty/error/save
   language for all six lenses); how the Mimer character (rich reader) and Heimdal character (thin,
   truthful daemon) stay visibly siblings.
2. **As-built B1 grades** — two-axis journey grades (see §3).
3. **Surface 1 — Mimer-iPhone uplift** (S1–S6): the shared scaffold applied, missing states filled,
   steering moved from typed ids to gestures on visible items.
4. **Surface 2 — Mimer iPad thinking canvas** (P1–P3): three-column split view, metadata inspector,
   side-by-side entity confirmation, Scribble/keyboard annotation, drag-drop promotion.
5. **Surface 3 — Heimdal capture client** (H1–H4): press-to-record with locked-screen continuation,
   the truthful `staged → delivering → delivered → failed` queue, registration/consent, the live
   device-health glance (the granted telemetry bend), and the one-tap Watch app with distinct haptics.
6. **Per-surface "markdown holds the record" stances + advisory flags** (see §4).

## 3. As-built B1 grades (A = workflow intuitiveness · B = implementation quality)

| Journey | A | B | Headline |
|---|---|---|---|
| S1 Enter | B+ | B | Strongest screens; but landing has no "where am I / what's new" orientation or last-refresh anchor. |
| S2 Review attention | **D** | C | Typed item-id (O1) breaks the no-typed-ids rule; audit trail can misstate the human's act (D1). **Highest-leverage fix.** |
| S3 Steer interests | C | C+ | Raw 0–1 sliders expose the model with no "because you did X" evidence; Never list is a dead end (O6). |
| S4 Confirm entity | C− | B− | Merge silently takes first candidate (O7); no undo (O5) — both collide with reversible autonomy. |
| S5 Read & edit | B | C+ | No dirty state / cancel / save confirmation; D3 (leading-zero YAML) is silent data change; conflict copies unsurfaced. |
| S6 Consent glance | B+ | B | Correctly light and read-only under posture A; needs only the shared scaffold + provenance footer. |

**Uplift moves, ranked by leverage:**
1. **Steering as gestures on visible items** (S2) — swipe attended/skipped on the item itself, truthful audit line per act. Removes O1, closes D1's surface.
2. **The shared lens scaffold** — one load/empty/error/save container adopted by all six lenses. Removes O2, O3, O4 in a single component.
3. **Undo bar on every consequential act** — merge/reject, mark attended/skipped, save. Makes ruling 7 visible. Removes O5.
4. **Explicit candidate choice on phone merge** (S4) — merge disabled until a candidate is picked. Removes O7 *(advisory — changes shipped B1 behaviour; see §4)*.
5. **Editor honesty** (S5) — dirty dot, cancel/discard, saving→saved, save-failure keeps text with Retry/Copy, conflict-copy banner; D3 surfaced as a pre-save warning, never silent.
6. **Identity layer** — app icon, launch screen, verified Yggdrasil dark theme (O8, O9).

## 4. Advisory flags — owner ruling needed (no silent redesigns)

These four proposals conflict with a spec'd/as-built B1 behaviour. They must be ruled on before they
enter a normalized spec or an issue:

1. **Tab topology.** Design shows **5 tabs** (Today · Interests · Entities · Vault · Heimdal) with
   Consent + Settings behind a gear. B1 specs **6 tabs**; adding Heimdal as a 7th degrades all of
   them. → Conflicts with the as-built tab list.
2. **Phone merge requires explicit candidate choice** (S4). The iPad spec already removes the
   first-candidate default; the proposal is for the phone to inherit that now. → Changes shipped B1
   behaviour.
3. **Interests "Never" list gains Restore** (S3). B1 specs it read-only; Restore is a one-gesture
   reversal consistent with ruling 7 — but it is an AC change.
4. **D3 pre-save warning** (S5): "Keep as text / Save anyway" adds a decision point the editor spec
   lacks. Alternative: fix YAML round-tripping hub-side and show no UI at all.

Everything else stays inside the walls: posture A operative, ASR hub-side, no transcript on device,
no typed paths, no push, failure always visible.

## 5. Recommended next steps

1. **Owner rulings on the four §4 flags.** These are the only blockers to promotion. #1 (tab
   topology) is the most structural and should be decided first, since it shapes both the B1 uplift
   and where the Heimdal client lives in the shell. Record rulings where they belong: ecosystem-scope
   ones route to the hub CES/ADR process; a purely Swift-stack/app-shell choice may be a
   Bifrost-local ADR under `docs/adr/`.
2. **Promote to a normalized spec (Crossing B).** Convert the accepted parts into a normalized spec
   before any code. Two natural specs: (a) the **shared lens scaffold + B1 uplift** (rides the
   in-flight shell-hardening wave — bifrost #4–#8; the S2 steering + audit fix also closes D1's
   surface), and (b) the **Mimer-iPad** and **Heimdal-client** experience specs that sit on top of
   the existing MIPAD-01..05 / HCAP-01..09 slices (design-before-build — nothing is written yet).
3. **Cut issues from the normalized spec, not from this HTML.** Per governance, implementation is
   issue-first; each issue references the normalized spec and the source rulings. The B1-uplift work
   is the highest-leverage and lowest-risk to start (it improves a shipped surface without waiting on
   B2/B3).
4. **Do not implement production UI directly from the prototype.** It is guidance only; route through
   the chain above.

## 6. Continuity

- **Round 1** — `heimdall-watch-selection-design` (watch/selection control surface, J1–J7).
- **Round 2** — `heimdall-ux-design` (2026-07-05): the converged journey exploration whose open
  questions the owner ruled into ADRs. J-numbers carry over (J0 capture, JE entity, JC consent,
  JD device).
- **Round 3** — this package: the first *app-level* round (screens, states, family design system).
