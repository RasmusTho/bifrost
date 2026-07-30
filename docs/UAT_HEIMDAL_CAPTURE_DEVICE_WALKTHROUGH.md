# Heimdal capture-client physical-device walkthrough

Run this after installing the merged Yggdrasil build on a physical iPhone
(and, for the Watch steps, a paired Apple Watch) per
`docs/BIFROST/APP_DEPLOYMENT_POSTURE.md`'s operator runbook. It checks the
truths only a physical device can prove: a real locked-screen pocket
recording, a real incoming call interrupting capture, a real Watch one-tap
capture, and a sanity check of the device-health panel. Everything else about
Heimdal's composed journeys (bind → record → background/foreground → stop →
staged → delivered; register → grant/registered → nameable gap → gap-log
entry; fail → rebind → retry; relaunch mid-queue) is already proven in the
simulator by
`Yggdrasil/YggdrasilUITests/HeimdalCaptureJourneyTests.swift` — do not re-prove
those here.

## Before you start

- Record the exact installed app build SHA and iPhone/Apple Watch models and
  OS versions.
- Bind a real, visible iCloud-synchronised capture folder through **Choose
  Capture Folder** before step 1 (the simulator journeys bypass this picker
  with a test-only fixture; a device run must exercise the real Files sheet).
- Have a second phone (or another person) ready to place a real call to the
  test device for step 2.
- Know the free-tier 7-day re-sign expiry (`APP_DEPLOYMENT_POSTURE.md`): if
  the last install is older than 7 days, re-run from Xcode before starting.

## What CANNOT be automated, and why

The Issue's composed journeys were automated as far as XCUITest and the
Simulator allow. Three things could not be, and are exactly what this doc
scripts instead:

1. **Screen-locked pocket recording over real time.** XCUITest cannot lock a
   Simulator's screen and keep audio capture running unattended for minutes;
   Simulator background audio behavior does not reliably model a physical
   device left in a pocket.
2. **A real incoming phone call.** There is no Simulator or XCUITest seam that
   originates a genuine `CXCallObserver`/interruption from cellular or
   VoIP telephony; existing tests can only simulate an `AVAudioSession`
   interruption notification, which is a different (weaker) proof than a real
   call.
3. **Watch one-tap capture end-to-end, physically.** This repository's
   `YggdrasilWatch` target and `WatchRelayReceiver` are exercised by lower-level
   tests, but Xcode has no supported way to drive two independent paired
   Simulator UI-test runners as one deterministic journey, and the required
   validation for this delivery (`xcodebuild ... -destination
   'platform=iOS Simulator,...'`) targets the iPhone app only. Watch-to-phone
   relay is therefore proven at the unit/component level
   (`WatchRelayReceiverTests`, `WatchRelayCustodyTests`) but the physical
   one-tap-to-staged journey is unverified until this walkthrough runs it.

## Steps and expected observations

1. Pocket recording with the screen locked, ≥10 minutes.

   Start a recording from **Heimdal → Record**. Lock the phone (side button)
   and place it in a pocket or drawer for at least 10 minutes. Expected: the
   microphone indicator (orange dot) remains visible in the status bar the
   whole time, proving capture continues under lock. Unlock, return to
   Heimdal, and stop the recording. Expected: the item appears under **Staged
   Items** with a duration of roughly 10 minutes or more, and is not marked
   "Recovered after restart" (recording never stopped in-process).

2. Real incoming call mid-recording.

   Start a new recording. While it is running, have the second phone call the
   test device. Answer the call, wait a few seconds, then end it. Expected:
   Heimdal shows **Resume Recording** if the pause was not auto-resumed by the
   system, or recording continues automatically if it was (either is a valid
   outcome; note which one happened). If **Resume Recording** appears, tap it
   before stopping. Stop the recording. Expected: the staged item's duration
   reflects the recording time minus the paused call span, and no crash or
   stuck "Placing in capture folder" state occurs.

3. Watch one-tap capture end-to-end.

   On the paired Apple Watch, open the Yggdrasil Watch app and tap to start a
   recording. Expected: a start haptic. Wait about 15 seconds, tap again to
   stop. Expected: a stop haptic, and the Watch app shows the relay as queued
   or sent. On the iPhone, open Heimdal. Expected: the Watch recording appears
   under **Staged Items** and progresses to "Placed in capture folder" without
   any iPhone-side interaction beyond opening the app. If it does not appear
   within a minute, background and foreground the iPhone app once (this
   triggers the retry-undelivered pass) before concluding failure.

4. Device-health panel sanity.

   With Heimdal open and at least one item in the delivery queue (e.g.
   mid-delivery, or use a temporarily unreachable capture folder to force a
   failed item), open the **Device Health** section at the bottom of the
   Heimdal list. Expected: **Session** reflects the live recording phase,
   **Delivery queue** shows a nonzero count while an item is undelivered,
   **Oldest pending** shows an increasing age for that item, **Battery** shows
   a real percentage (not "unknown") once the device has reported one, and
   **Mic permission** reflects the device's actual authorization state. None
   of these values may be stale after backgrounding and foregrounding the app.

### 5. Durable transfer queue (added by the CDLM scope refresh)

The queue surface is what makes the durability contract visible to you; the
simulator journeys prove it derives correctly, but only you can confirm it reads
truthfully on the device you actually carry.

1. Open the **Queue** tab. Expect one row per capture you made above, each
   showing one of: `pending locally`, `transferring`, `backend durably received`,
   `processing`, `complete`, or `needs attention`.
2. With the hub unreachable (airplane mode is fine), expect the queue to state
   that the hub is not answering, and expect **no** row to claim
   `backend durably received` that did not already hold a receipt. A row may show
   a last-known hub state marked stale; it must never advance while offline.
3. Force-quit the app and reopen it. Expect the same rows in the same states,
   rebuilt from disk — nothing lost, nothing advanced by the restart.
4. Confirm that no recording you made has disappeared from the device. Under the
   current contract an original is deleted only after its durable-acceptance
   receipt is stored locally.

Record anything that disagrees with the above; a queue that overstates progress
is the specific failure this capability exists to prevent.

## Receipt to post on hub #3026

Post one comment after the walkthrough, using real observations only:

```text
Heimdal capture-client device walkthrough receipt — build: <merged SHA>;
iPhone: <model, iOS version>; Watch: <model, watchOS version, or "not tested">;
step 1 (locked pocket recording ≥10min): <pass/fail — actual duration observed>;
step 2 (real incoming call mid-recording): <pass/fail — auto-resumed or manual resume, actual duration>;
step 3 (Watch one-tap → phone staging): <pass/fail — time to appear on phone, any manual foreground needed>;
step 4 (device-health panel sanity): <pass/fail — values observed for queue depth, oldest pending, battery, mic permission>;
notes: <brief observations or failure details>.
```

If any step fails, include the failed step number, what was visible, and do
not mark the walkthrough as passed. Do not fabricate any result in this
receipt — it is a record of what a human physically observed, not a
restatement of the simulator test suite.
