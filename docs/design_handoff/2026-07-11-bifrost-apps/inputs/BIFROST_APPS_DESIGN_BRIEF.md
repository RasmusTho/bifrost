# Bifrost apps — App-level Design Brief (round 3)

**Date:** 2026-07-11 · Working artifact (Desktop, not repo) · Entry brief for a Claude Design exploration

This is the **third design round** for the native-app dimension of a personal agentic knowledge
system, and the first at **app level**:

- **Round 1** (`heimdall-watch-selection-design`) explored the watch/selection control surface (J1–J7).
- **Round 2** (`heimdall-ux-design`, 2026-07-05) explored Heimdal's whole human-facing surface
  journey-by-journey; the owner then **ruled** (capture posture, app topology, the two markdown-first
  "bends"), the rulings were enacted as ADRs, and full implementation specs were written.
- **Round 3 (this brief):** the apps are now real. A first app shell is **built and running on the
  owner's iPhone**; the iPad and capture clients are **fully spec'd with 17 bounded implementation
  slices**. What is missing is exactly the layer Claude Design owns: **concrete screen and
  interaction design** — layout, hierarchy, states, component design — for three app surfaces,
  before/while the remaining slices are built.

Everything strategic is **decided**. Round 2's open questions are this round's fixed walls. Design
inside them; do not relitigate.

---

## 1. The system in one paragraph (naming is canonical — honour it)

**Yggdrasil** is the whole: a personal, single-human ("the principal") agentic knowledge system whose
canonical record is a plain-markdown **vault** (edited natively in Obsidian). **Mimer** is the
knowledge/cognition constituent (notes, interests, entities, attention). **Heimdal** is the
sensor/ingestion constituent (capture → transcribe → attribute, hub-side). **Bifrost** is the
native-app repo — the bridge between the human and the system. The shipped app is named
**"Yggdrasil"**: one shell, two bounded clients inside (topology C, decided): a **Mimer client**
(iPhone + iPad-first) and a **Heimdal capture client** (iPhone + Watch, never iPad). Spellings:
Heimdal, Bifrost (no double-l, no ö).

## 2. Fixed rulings (the walls — decided, enacted, not up for debate)

1. **"Markdown holds the record; the app is a lens."** Every capability is fully doable in Obsidian
   as `.md` files. Delete the app → lose nothing. Exactly **two UI-only "bends"** are granted:
   (a) the item-level attention/skip firehose, (b) **live device telemetry** (battery/signal/queue).
   Everything else the UI shows must be backed by an editable note.
2. **Capture posture:** the *target* is **B-full** (continuous wearable audio via a pendant) — but it
   is **gated behind five activation gates (G1–G5)** (hardware, host ASR load, the B3 client itself,
   cross-scope fusion gating, operational consent). **Posture A — discrete press-to-record — is what
   ships and runs now.** Design the capture client for A, with B-full as a legible future mode, not a
   near-term toggle. Operator **voice-enrollment** may be offered already under A; third-party
   voiceprints only ever via explicit per-person consent.
3. **ASR is hub-side, always.** The phone/Watch captures and delivers **raw audio only**. There is
   never a transcript on the device at capture time, no on-device ML, no "transcribing…" state. The
   transcript reappears later, hub-authored, in the vault.
4. **No sign-in, no cloud, v1.** Clients talk only to the operator's own hub over LAN/tailnet, or to
   the vault directly on the filesystem (iCloud-synced). There is no account, no auth flow, no
   multi-tenant concept. **"Can't reach hub" is a first-class, expected state** — not an error edge.
5. **Deployment reality:** free-provisioning sideload — installs expire every 7 days, max 3 apps,
   **no push notifications**, no App Store. Reassurance UIs (queue status, device health) must work
   by foreground refresh/polling, never assume push.
6. **Dyslexia-safe rule (hard):** no typed or pasted paths anywhere, ever. Every vault/folder
   selection is a native **visual pick**. Minimal cognitive load; lead with the answer; fewest
   decisions per screen.
7. **Reversible autonomy:** the agent proposes, the principal steers *after the fact*; every action
   is one gesture to undo. Entity merges are appended, reversible decisions — history is never edited.
8. **Failure is always visible, never silent.** A failed write keeps the user's content on screen
   with an explicit error and retry/copy affordance. A stopped recording is never lost — it is always
   accountably in exactly one visible place.

## 3. The three design surfaces

### Surface 1 — Yggdrasil shell + Mimer-iPhone (BUILT — critique & uplift)

Delivered (B1) and running: local auth gate → visual vault picker → a tab shell with six areas:
**Today** (attention), **Interests**, **Entities** (confirmation queue), **Consent** (read-only),
**Vault** (notes browser: browse → render → edit → save `.md`), **Settings**. See the attached
`CURRENT_IMPLEMENTATION_B1.md` for the as-built walkthrough, every screen's states, and the existing
design-token inventory (`Theme.swift`).

This surface was built engineer-first against acceptance criteria. Your job: a **deep, journey-based
review and uplift design** — not per-screen aesthetics. Grade each journey on two axes:
(A) workflow intuitiveness, (B) implementation quality. Then show what the screens *should* be,
reusing the same information architecture unless you argue otherwise.

Journeys (walk each end-to-end):
- **S1 Enter:** launch → auth → (first run: visual vault pick) → oriented "where am I, what's new".
- **S2 Review the agent's attention:** Today/Attention lens — what was ingested vs skipped and why;
  one-gesture override; the audit trail must state truthfully what the human did.
- **S3 Steer interests:** Interests lens — the agent's model of me, with "because you did X"
  evidence and one-tap steering.
- **S4 Confirm an entity (JE, phone form):** review queue → candidates → merge/reject → undo.
- **S5 Read & edit a note:** browse `_heimdal/**` → render → edit → save; conflict-copy surfacing.
- **S6 Consent glance:** read-only standing-grant view (posture A: this is deliberately light).

### Surface 2 — Mimer iPad "thinking canvas" (SPEC'D — design before build)

The design-of-record promise: **iPadOS earns its own design** — the primary canvas for focused
review/curation/thinking. Spec'd as MIPAD-01..06 (17-slice wave, unbuilt). Fixed structure from the
spec — design the experience inside it:

- **Three-column `NavigationSplitView`** (regular width only; iPhone keeps its tab shell):
  sidebar (six lens entries) · content column (lens list / folder listing) · detail (rendered note).
- **Inspector panel** (`⌘I`): frontmatter metadata — uuid, zone/origin, provenance, modified date;
  absence is *stated*, never hidden.
- **Side-by-side entity confirmation (JE, canvas form):** pending mention on one side, candidate
  cards on the other, matching attributes highlighted (MDM/Reltio pattern); merge requires explicit
  candidate selection; Merge/Reject/**Undo** as reversible appended decisions; "no note yet"
  candidates get an honest empty state.
- **Annotation:** a text affordance on the open note — Apple Pencil via system **Scribble** (plain
  text only, no ink persistence) or hardware keyboard; commits as an appended, attributed callout
  block in the note.
- **Drag-and-drop promotion:** drag a list item (note row, entity, attention item) onto a note;
  drop appends a markdown-link promotion block. Append-only; never reorders existing content.
- **Keyboard:** arrows/Tab across columns and lists, `⌘F` local filter, `⌘I` inspector.

Journeys: **P1 Browse-and-read** (vault → columns → folder → note → inspector), **P2 Entity
decision** (side-by-side JE with undo), **P3 Curate** (annotate + drag-promote into a note).

Explicitly out of scope (spec-ruled): ink/PencilKit canvases, backlinks/recent-notes surfaces
(no endpoint exists), batch operations, structured attribution-correction flow (v1 = generic
annotation), episode-object semantics.

### Surface 3 — Heimdal capture client, iPhone + Watch (SPEC'D — design before build)

Character: **background daemon made human** — thin, truthful, permission-heavy; the anti-app. Spec'd
as HCAP-01..10 (unbuilt). Replaces the current floor (stock Voice Memos + a Shortcut into a watched
iCloud folder). The client **captures and delivers audio; nothing else**. No transcript ever appears
here; the only vault content it authors is its own device note.

Fixed structure from the spec:
- **Heimdal area in the shell** (tab), with: a visual "choose capture folder" first-run flow
  (security-scoped bookmark; no typed path), a record surface, and a staged-items queue.
- **Capture (J0):** press-to-record; true background/locked-screen continuation; interruption
  (call/Siri) pause with resume affordance; truthful mic-permission pre-prompt framed on
  single-party discrete recording.
- **Delivery queue:** each item visibly `staged → delivering → delivered-awaiting-sync → failed`,
  with timestamps and manual retry. Wording must not overclaim — "delivered" means *placed in the
  folder*, not *hub-admitted*.
- **JC — registration & consent:** shows the standing consent grant (read-only, from the vault
  note), this device's registration state, one-tap "Register this device", and a visible
  "not registered — captures may be refused" warning. Granting/revoking consent is owner/hub-side
  only. Under posture A this surface is deliberately light — but design it so B-full inherits a
  working mechanism (withheld third-party spans, per-person grants) rather than a bolt-on.
- **JD — device health (the granted UI-only bend):** live glance — recording state, queue depth +
  oldest-pending age, battery, storage headroom, mic-permission state. Persists nothing; durable
  facts (capture-gap log, last-known snapshot) land in the device note instead.
- **Watch app:** one large record/stop button; elapsed time + "still capturing?" indicator; queued
  relay count; **distinct haptic patterns** for start/pause/resume/stop/relay-failure; honest
  "phone unreachable — queuing on watch" statement. Relay-only (no networking of its own), and
  **never any Mimer/knowledge content on the wrist**.

Journeys: **H1 Capture** (bind folder → record incl. pocket/locked → stop → staged → delivered),
**H2 Identity & health** (register → JC truthful → JD glance → gap log), **H3 Recovery** (failed
delivery visible → rebind → retry; relaunch rebuilds queue from disk), **H4 Wrist capture**
(one-tap + haptics + relay).

## 4. What we want back (deliverables)

1. **Screen designs (mockups) per journey, per surface** — S1–S6 uplift, P1–P3, H1–H4 — at real
   device sizes (iPhone, iPad regular-width landscape, Watch). Show key states: empty, loading,
   error/failed, offline/"can't reach hub", unregistered, conflict-copy.
2. **A design system for the app family**, grounded in the existing `Theme.swift` tokens (attached
   inventory): what to keep, extend, replace; typography/color/spacing scale; the shared lens
   scaffold (one load/error/save pattern for all six lenses); how the Mimer character (rich reader)
   and Heimdal character (thin daemon) stay visibly siblings.
3. **The two-axis journey grades for the as-built B1** (workflow intuitiveness / implementation
   quality) with the top uplift moves ranked by leverage.
4. **A per-surface stance on how the app expresses "markdown holds the record"** — e.g. where the
   UI shows "this is a note; open it in Obsidian" affordances — within the ruled bends.
5. **Anything that conflicts with a spec AC:** flag it explicitly as *advisory, needs an owner
   ruling* — do not silently redesign a spec'd behaviour.

## 5. Out of scope

- The backend/pipeline (hub-side ASR, ingestion, entity resolution algorithms) — settled.
- Relitigating rulings in §2 (posture, topology, bends, ASR-side, markdown-first).
- Posture-B activation UX as a shippable feature (design B-full as a legible *future* mode only).
- Video/camera capture (undecided, out of scope).
- Push-notification-dependent patterns (none exist under sideload).
- Building anything — design only; implementation stays issue-first in the existing 17-slice wave.

## 6. Attached / read first

- `CURRENT_IMPLEMENTATION_B1.md` — as-built walkthrough + design-token inventory (same folder).
- Round 2 output for continuity (optional): `heimdall-ux-design/CLAUDE_DESIGN_OUTPUT_v2.html` —
  the converged journey exploration that these rulings came from. The J-numbers (J0 capture,
  JE entity, JC consent, JD device) carry over.
