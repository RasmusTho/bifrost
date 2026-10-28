# Mimer iPad canvas UAT walkthrough (bifrost#13)

This is the acceptance checklist for [Bifrost #13](https://github.com/RasmusTho/bifrost/issues/13).
The [accepted hub routing](https://github.com/RasmusTho/agentic-pkm-mvp/issues/3024#issuecomment-6248726689)
uses automated journeys at the exact native build together with qualified
synthetic TARS TEST evidence. Reuse applicable results; a recurring eyes-on
rerun of the three automated journeys is not an acceptance requirement.
Apple Pencil / Scribble observations still require actual applicable hardware.

Installation follows the hub's
[Bifrost app deployment posture](https://github.com/RasmusTho/agentic-pkm-mvp/blob/main/docs/BIFROST/APP_DEPLOYMENT_POSTURE.md):
Xcode sideload with the operator's Personal Team. Initial signing, installation,
device trust and OS permissions remain separate operator prerequisites. This
checklist neither changes distribution nor records an acknowledgement for them.

## Automated build-bound evidence

1. Record the exact native source SHA/build identity, CI run and destinations.
   Read the individual test outcomes, including skips, rather than inferring
   coverage from a green workflow.
2. On the iPad destination, require actual passes for
   `MimerCanvasJourneyTests.testBrowseAndReadJourney`,
   `testEntityDecisionJourney` and `testCurateJourney` in
   `Yggdrasil/YggdrasilUITests/MimerCanvasJourneyTests.swift`.
3. On the same head, require the B1 iPhone regressions in
   `Yggdrasil/YggdrasilUITests/YggdrasilUITests.swift`:
   `testAuthGatePrecedesVaultContent`, `testVaultSelectionHasNoTextInput`,
   `testHeimdalNoteRenderEditRoundTrip` and `testAllFiveLensesLoadFixtureNotes`.
4. Link the qualified synthetic TARS TEST fixture identity, backend candidate
   and actual roundtrip acceptance receipt required by the hub routing. Native
   UI fixtures and a closed setup issue alone do not prove that live acceptance.
5. Retain the actual per-step outcomes and evidence links on hub #3024. A
   required failed, blocked or skipped result remains incomplete; neither
   simulator nor backend proof supplies a Pencil/Scribble observation.

## Device walkthrough

The three journey scripts below retain the original scenario inventory for
qualified-device execution or diagnosis. Their automated evidence can be reused
as above. Run the Pencil/Scribble steps on a physical iPad with an Apple Pencil
and record the installed build and actual observations. Allow about fifteen
minutes for the full script when a device run is needed.

### Before you start

- Record the exact installed app build SHA and iPad model/iPadOS version.
- Ensure the target iCloud vault is visible in the Files app, contains at
  least one folder with two or more notes, and has an Apple Pencil paired to
  the iPad.
- Use the visible Files folder picker whenever a vault must be selected; no
  filesystem path is entered or pasted.
- Hold the iPad in landscape orientation; the three-column canvas is an
  iPad-only, landscape-first layout.

### Steps and expected observations

#### 1. Browse and read journey

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

#### 2. Entity decision journey

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

#### 3. Curate journey

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

#### 4. Pencil / Scribble (hardware-only, cannot run in the simulator)

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

   Record the actual iPad/Pencil capability. If the available hardware cannot
   exercise this step, record it as blocked with the reason; do not infer a pass.

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

Post the build-bound `mipad.device_walkthrough.v1` receipt on
[hub #3024](https://github.com/RasmusTho/agentic-pkm-mvp/issues/3024), linking
the actual automated results and physical observations. This is an unfilled
template, not acceptance evidence. Keep private vault paths, note content,
bindings, device identifiers and credentials out of the public receipt.

```yaml
receipt: mipad.device_walkthrough.v1
issue: RasmusTho/bifrost#13
observed_at: <actual UTC time>
native_build_sha: <exact installed/tested SHA; identify any differing build>
native_ci: <run URL, exact head, iPad/iPhone destinations and test outcomes>
qualified_test: <fixture identity, backend candidate and acceptance receipt URL, or blocked reason>
device: <iPad model, iPadOS and Apple Pencil model; no device identifier>
install_method: <Xcode Personal-Team sideload; actual prerequisite status>
journey_browse_and_read: <pass/fail/blocked/skipped, execution environment, evidence URL>
journey_entity_decision: <pass/fail/blocked/skipped, execution environment, evidence URL>
journey_curate: <pass/fail/blocked/skipped, execution environment, evidence URL>
pencil_scribble: <actual physical-device result and observation for step 1>
pencil_hover_and_tap: <actual physical-device result and observation for step 2>
pencil_drag_and_drop: <actual physical-device result and observation for step 3>
observations: <redacted notes or exact failed/blocked step and next prerequisite>
```

Do not mark a hardware step passed without running it on the recorded physical
device. The receipt is complete only when every required applicable outcome has
actual build-bound proof. Keep #13 open while proof is missing; MIPAD-06
([hub #3188](https://github.com/RasmusTho/agentic-pkm-mvp/issues/3188)) owns
subsequent B2 closure, including hub #3024 and the Epic B ledger.
