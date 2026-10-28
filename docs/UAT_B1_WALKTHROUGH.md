# B1 iPhone UAT walkthrough

This is the B1 acceptance guide for the thin shell and Mimer-iPhone reader.
Per the owner direction on [Bifrost #7](https://github.com/RasmusTho/bifrost/issues/7)
and [hub #3023](https://github.com/RasmusTho/agentic-pkm-mvp/issues/3023)
(2026-10-11), technical acceptance uses automated journeys at the exact accepted
native build and qualified synthetic TEST evidence. Recurring operator eyes-on
walkthroughs are not the technical acceptance route.

The physical steps below retain the actual device observations, including real
authentication and Files/iCloud access. Simulator fixtures do not prove those
outcomes. The device sequence takes about ten minutes; use a disposable markdown
note for its edit step.

## Automated acceptance path

1. Record the exact native source/build SHA and the executed test destination.
   Reuse passing CI evidence only when it covers that candidate and the required
   tests; a green workflow badge alone is insufficient. In
   `Yggdrasil/YggdrasilUITests/YggdrasilUITests.swift`, the B1 iPhone journeys are:

   - `testAuthGatePrecedesVaultContent`
   - `testVaultSelectionHasNoTextInput`
   - `testHeimdalNoteRenderEditRoundTrip`
   - `testAllFiveLensesLoadFixtureNotes`

   Also retain
   `Yggdrasil/YggdrasilTests/TestSeamGatingTests.swift::testFixtureVaultSeamRequiresLaunchArgument`.
   These journeys use a synthetic fixture vault and test-only auth seams. Their
   deliberate iPad skips are outside B1 and do not count as iPhone proof.
2. Reconcile the same native candidate with the qualified TEST channel identity
   and `control_surface_roundtrip.v1` from the existing
   [hub #3169 procedure](https://github.com/RasmusTho/agentic-pkm-mvp/issues/3169).
   Its owner verifies app-shaped note writes, watcher/runtime convergence,
   preservation of foreign fields and channel isolation. A closed setup issue
   or a historical backend receipt does not establish current TEST acceptance.
   This guide grants no channel, deployment or vault-write authority.
3. When physical outcomes are required, retain actual per-step results from a
   qualified-device run against the same accepted native build. An automated
   device run proves only the observations it actually exercises. A fixture
   auth gate or temporary vault cannot stand in for device authentication,
   visual Files selection, real iCloud access or persistence after relaunch.
   Missing device access or automation remains a named recovery prerequisite.
4. Post the combined evidence on hub #3023. A failed, blocked, skipped or
   unexecuted required observation does not pass acceptance; leave #7 open for
   the exact missing proof.

## Before you start

- Initial device signing/install and OS permission prerequisites remain separate
  operator operations under the hub's
  [Personal-Team deployment posture](https://github.com/RasmusTho/agentic-pkm-mvp/blob/main/docs/BIFROST/APP_DEPLOYMENT_POSTURE.md).
  Confirm device availability and supported OS before any authorized device run.
  This guide does not authorize signing, installation or permission changes.
- Record the exact installed app build SHA and iPhone model/iOS version.
- Ensure the target iCloud vault is visible in the Files app and contains at
  least one `_heimdal/` note.
- Use the visible Files folder picker whenever a vault must be selected; no
  filesystem path is entered or pasted.

## Steps and expected observations

1. Launch Yggdrasil while it is locked.

   Expected: the local device-authentication gate is presented before any vault
   note, lens, or vault content is visible. Unlock with the device owner
   authentication prompt.

2. Select the vault.

   Expected: Yggdrasil shows recent vault tiles and a **Choose a Vault Folder**
   button. Selecting that button opens the visual Files picker; choose the
   iCloud vault by navigating folders and tapping it. There is no manual
   location-entry control.

3. Browse and edit a vault note.

   Expected: open **Vault**, navigate visually to `_heimdal/`, then open a
   disposable markdown note. Its markdown renders. Choose **Edit**, append a
   short marker such as `UAT saved`, then choose **Save**. Reopen the note (or
   inspect it in Files/Obsidian after sync) and confirm the marker persisted.

4. Check the five Mimer lenses.

   Expected: **Today** (Attention), **Interests**, **Entities**, **Consent**,
   and **Settings** each load their corresponding `_heimdal/**` note without a
   red error message. In **Consent**, verify that grants are displayed but there
   is no edit or save control; consent remains read-only in Mimer.

5. Close and relaunch Yggdrasil.

   Expected: the local auth gate again protects vault content. After unlocking,
   the selected vault can be reopened through its visible recent-vault tile.

## Receipt to post on hub #3023

Post actual automated evidence and physical observations together, using the
existing `b1.device_walkthrough.v1` receipt target. Include links to the executed
native results and the qualified TEST roundtrip for the same accepted native
build. Keep runtime bindings, private note content and credentials out of the
comment. The physical portion records:

```text
b1.device_walkthrough.v1 — device: <iPhone model, iOS version>;
installed native build: <exact SHA>; native results: <executed result link>;
qualified TEST roundtrip: <receipt link and matched native candidate>;
steps 1–5: <actual pass/fail/blocked/skipped for each>;
notes: <brief observations, failure details or exact missing prerequisite>.
```

Do not create an acceptance PASS from a prepared template. If a required step
fails or cannot run, record its number and actual outcome, retain the exact next
recovery action on #7, and keep hub #3023 open until all applicable evidence is
reconciled.
