# Mimer iPad canvas UAT walkthrough (bifrost#13)

Run this once on a physical iPad after installing the merged Yggdrasil build.
It walks the three composed canvas journeys the automated iPad XCUITest suite
(`Yggdrasil/YggdrasilUITests/MimerCanvasJourneyTests.swift`) already proves in
the simulator, plus one thing the simulator cannot prove: Apple Pencil /
Scribble input against the canvas's text-entry surfaces. Expect about fifteen
minutes with a real iCloud-synchronised vault and an Apple Pencil.

> Anchor note: this walkthrough was asked to reference
> `docs/BIFROST/APP_DEPLOYMENT_POSTURE.md` for install steps, but that path
> does not exist in this repo at the delivering commit. Use whatever install
> path your team currently uses to get a merged Yggdrasil build onto a
> physical iPad (TestFlight or a signed development build); this doc does not
> invent one. Record the actual install method used in the receipt below.

## Before you start

- Record the exact installed app build SHA and iPad model/iPadOS version.
- Ensure the target iCloud vault is visible in the Files app, contains at
  least one folder with two or more notes, and has an Apple Pencil paired to
  the iPad.
- Use the visible Files folder picker whenever a vault must be selected; no
  filesystem path is entered or pasted.
- Hold the iPad in landscape orientation; the three-column canvas is an
  iPad-only, landscape-first layout.

## Steps and expected observations

### 1. Browse and read journey

1. Launch Yggdrasil while it is locked, then unlock with the device owner
   authentication prompt.

   Expected: the local device-authentication gate is presented before any
   vault content is visible.

2. Select the vault via **Choose a Vault Folder** and the visual Files
   picker.

   Expected: after selection, the canvas shows three columns at once — a
   sidebar of lenses on the left, a content column in the middle, and a
   detail column on the right.

3. Tap the **Vault** lens in the sidebar, then tap a folder in the content
   column.

   Expected: the content column lists that folder's notes.

4. Tap a note.

   Expected: the note's rendered markdown appears in the detail column.

5. Open the inspector (toolbar inspector control, or `Cmd+I` with a hardware
   keyboard) and check the note metadata.

   Expected: for a note that has `uuid` / `agent_provenance` frontmatter, the
   inspector shows that uuid and provenance. Open a second note that has no
   such frontmatter and confirm the inspector honestly reports no uuid
   present, rather than carrying over the previous note's metadata.

### 2. Entity decision journey

1. Tap the **Entities** lens in the sidebar.

   Expected: the content column lists pending entity mentions waiting for
   confirmation.

2. Tap a pending mention that has two or more candidates.

   Expected: the detail column shows the mention context on the left and a
   scrollable column of candidate notes on the right, one card per candidate.

3. Without tapping a candidate, check the **Merge** button.

   Expected: **Merge** is disabled until a candidate is explicitly selected.

4. Tap one specific candidate card, then tap **Merge**.

   Expected: the candidate card shows a selected checkmark, **Merge** becomes
   enabled, and after tapping it the decision status reads
   "Merge proposed: `<that candidate's entity id>`" — the id you selected, not
   any other candidate.

5. Tap **Undo**.

   Expected: the decision status returns to "Undecided locally" and the same
   pending mention remains in the queue, ready for another decision later.

### 3. Curate journey

1. With a note open in the detail column, tap the annotate control and enter
   a short note (e.g. "check the June numbers"), then commit it.

   Expected: the annotation text renders in the note.

2. Drag a different note from the content column and drop it onto the open
   note in the detail column (press and hold briefly before dragging so the
   drop registers).

   Expected: a link/embed to the dragged-in note is added to the open note.

3. Re-check the open note.

   Expected: both blocks are visible together — the annotation from step 1
   and the promoted link/embed from step 2 both render in the same note at
   once. Neither one replaces the other.

### 4. Pencil / Scribble (hardware-only, cannot run in the simulator)

1. With the annotation field open (from the curate journey, step 1) or any
   other text-entry surface the canvas exposes, use the Apple Pencil to
   handwrite a short phrase directly into the field using Scribble, instead
   of typing on the on-screen keyboard.

   Expected: iPadOS converts the handwriting to text in the field, and the
   canvas accepts and commits it exactly like typed text — no crash, no
   stuck/uncommitted draft, no corrupted frontmatter in the underlying note
   file after saving.

2. With the Pencil hovering (not touching) over an interactive canvas
   element (a candidate card, a vault entry, a lens icon), observe the hover
   preview iPadOS shows for Pencil hover, then tap to select with the Pencil
   tip.

   Expected: hover shows the standard system hover indicator, and tapping
   with the Pencil performs the same action a finger tap would (selection,
   navigation, or button activation matching the element).

3. Use the Pencil to perform the curate-journey drag-and-drop from step 2 of
   the curate journey (drag a note from the content column onto the open
   note in the detail column) instead of a finger.

   Expected: the same drop behaviour as with a finger — the dragged note's
   link/embed appears in the open note, alongside anything already there.

If any Pencil/Scribble step behaves differently from its finger/keyboard
equivalent (crash, dropped input, stuck editing state, or a written note file
that doesn't match what was entered), treat it as a failure and describe
exactly what was observed.

## Receipt to post on hub #3024

Post one comment after the walkthrough, using real observations only. Do not
mark any step passed without having actually run it on the physical device.

```text
Mimer iPad canvas UAT receipt (bifrost#13) — device: <iPad model, iPadOS version>;
build: <merged SHA>; install method: <TestFlight / dev build, since
docs/BIFROST/APP_DEPLOYMENT_POSTURE.md was not found in-repo>;

Journey 1 — Browse and read: <pass/fail>
Journey 2 — Entity decision: <pass/fail>
Journey 3 — Curate: <pass/fail>
Journey 4 — Pencil/Scribble (steps 1-3): <pass/fail per step>

Observations: <brief notes, or failure details with the exact step number and
what was visible>.
```

If any step fails, include the failed step number, what was visible, and do
not mark the walkthrough as passed.
