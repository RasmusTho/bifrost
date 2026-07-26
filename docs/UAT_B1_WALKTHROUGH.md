# B1 iPhone UAT walkthrough

Run this after installing the merged Yggdrasil build on a physical iPhone. It
checks the thin shell and Mimer-iPhone reader against a real iCloud-synchronised
vault in about ten minutes. Use a disposable markdown note for the edit step.

## Before you start

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

Post one comment after the walkthrough, using real observations only:

```text
UAT walkthrough receipt — device: <iPhone model, iOS version>; build: <merged SHA>;
steps 1–5: <pass/fail for each>; notes: <brief observations or failure details>.
```

If any step fails, include the failed step number, what was visible, and do not
mark the walkthrough as passed.
