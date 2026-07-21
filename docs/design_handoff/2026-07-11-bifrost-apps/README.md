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

## 4. Decisions — one owner ruling, three agent-decided conforming fixes

The design surfaced four proposals that change a spec'd/as-built B1 behaviour. Running the
owner-decision-brief filter (`.codex/skills/owner-decision-brief`) over them: three conform to
rulings the owner already made, are reversible, and are taken as agent decisions (logged here); one
is genuinely the owner's and carries a decision brief.

### 4.1 Owner decision — bottom-tab layout

**Decision:** How should the app's bottom tabs be organized — does the capture feature get its own
tab, and do the Consent and Settings screens stay as tabs or move behind a gear button?

**Why you:** No existing ruling settles the app's primary navigation; it's a product-taste call that
also decides how visible your consent/privacy screen is and where the capture feature lives.

**Context:** The phone app has 6 bottom tabs today (Today · Interests · Entities · Consent · Vault ·
Settings). The capture feature (record audio) is being built and needs a home. iOS shows about 5
tabs before it hides the rest behind an automatic "More" list you don't control.

**Options:**
1. **5 tabs + gear (the design's proposal)** — Today · Interests · Entities · Vault · Capture, with
   Consent + Settings behind a gear. Clean bar, capture one tap away; but your consent screen becomes
   two taps away and less visible.
2. **Keep everything as tabs, add capture** — nothing moves; but the bar overcrowds and iOS may hide
   tabs behind a "More" menu automatically.
3. **Swap Settings behind a gear, keep Consent a tab** — Today · Interests · Entities · Consent ·
   Vault + Capture at 5 tabs, gear for Settings. Capture and Consent both stay one tap; only Settings
   (rarely opened) moves one tap deeper.

**Recommendation:** Option 3 — it keeps the two things you touch daily (capture and consent) one tap
away, stays within iOS's comfortable limit, and only demotes Settings.

**If you don't answer:** the shell keeps its shipped 6-tab layout, the capture client is designed
without claiming a tab, and no navigation uplift or capture-tab work is promoted or built until you
rule.

### 4.2 Taken as agent decisions (conform to existing rulings; reversible, logged here)

- **Phone entity-merge requires an explicit candidate pick** (S4). Silently merging to the first
  candidate collides with your "reversible autonomy / no silent action" ruling, and the iPad spec
  already removed that default. Decision: spec explicit selection + undo on phone merge. Easily
  reverted to a fast default-with-undo if you later prefer the speed.
- **Interests "Never" list gains a Restore gesture** (S3). Read-only conflicts with your
  "every action is one gesture to undo" ruling — a "Never" entry is a prior steering act you can't
  currently reverse. Decision: spec a one-gesture Restore.
- **D3 silent-YAML change** (S5). Silently altering a value like `007` on save violates your
  "failure/change always visible, never silent" ruling. Decision: fix the round-trip so saving never
  mutates the text (hub-side), rather than adding a save-time question; escalate only if a value is
  genuinely ambiguous and can't be preserved losslessly.

Everything else stays inside the walls: posture A operative, ASR hub-side, no transcript on device,
no typed paths, no push, failure always visible.

## 5. Recommended next steps

1. **One owner ruling: the bottom-tab layout (§4.1).** This is the only owner-grade blocker to
   promotion — it shapes both the B1 uplift and where the capture client lives in the shell. The
   other three former flags are agent-decided conforming fixes (§4.2) and need no ruling. Record the
   tab ruling where it belongs: a purely app-shell choice can be a Bifrost-local ADR under
   `docs/adr/`; if it touches ecosystem scope, route to the hub CES/ADR process.
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
