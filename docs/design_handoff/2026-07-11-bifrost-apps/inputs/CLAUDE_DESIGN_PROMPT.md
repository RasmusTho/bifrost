# Claude Design — ready-to-paste prompt (Bifrost apps, app-level design, round 3)

**Date:** 2026-07-11. Copy everything below the line into Claude Design. Attach
`BIFROST_APPS_DESIGN_BRIEF.md` and `CURRENT_IMPLEMENTATION_B1.md` (same folder). Optionally attach
`heimdall-ux-design/CLAUDE_DESIGN_OUTPUT_v2.html` (round 2's converged journey exploration) for
continuity — its J-numbers (J0 capture, JE entity, JC consent, JD device) carry over.

---

I need **concrete, app-level screen and interaction design** for the native apps of my personal
agentic knowledge system. Full context is in the attached `BIFROST_APPS_DESIGN_BRIEF.md` — read it
first; it is the source of truth for naming, rulings, and scope. The as-built state of the shipped
app is in `CURRENT_IMPLEMENTATION_B1.md` — treat it as the accurate visual record (no screenshots
exist; the app is sideloaded on my phone and builds only in CI).

**This is round 3.** Round 2 (which you may have attached as `CLAUDE_DESIGN_OUTPUT_v2.html`)
explored the journeys; I then **ruled** on its open questions, the rulings became ADRs, and full
implementation specs with 17 bounded slices were written. Round 2's questions are now **walls** —
brief §2 lists them (markdown-holds-the-record with exactly two UI-only bends; capture posture
B-full decided but gated, posture A operative; ASR hub-side, never a transcript on device; no
sign-in/no cloud, hub over LAN/tailnet only; sideload = no push notifications; no typed paths
anywhere; reversible autonomy; failure always visible). **Design inside them — do not relitigate.**

**The three surfaces (brief §3):**

1. **Yggdrasil shell + Mimer-iPhone — BUILT: deep review & uplift.** Journey-based, not per-screen
   aesthetics. Walk S1–S6 end-to-end and grade each on two axes: (A) workflow intuitiveness,
   (B) implementation quality. `CURRENT_IMPLEMENTATION_B1.md` §4 pre-finds nine issues (D1–D3,
   O1–O9) — start past those. Then design the uplift: the shared lens scaffold
   (load/empty/error/save as one visual language), the missing states, and the steering
   interactions as gestures on visible items rather than typed ids.
2. **Mimer iPad "thinking canvas" — SPEC'D, unbuilt: design before build.** Three-column
   NavigationSplitView, note + metadata inspector, side-by-side entity confirmation with explicit
   candidate choice and reversible Merge/Reject/Undo, Scribble/keyboard annotation, drag-drop
   promotion. Journeys P1–P3. The structure is spec-fixed; the experience — hierarchy, comparison
   layout, drag affordances, keyboard flow, how "thinking canvas" actually feels — is yours.
3. **Heimdal capture client, iPhone + Watch — SPEC'D, unbuilt: design before build.** The
   anti-app: a background daemon made human. Press-to-record with locked-screen continuation, a
   truthful staged→delivering→delivered→failed queue (wording must not overclaim), the
   registration/consent surface (light under posture A, but B-full must inherit it), the live
   device-health glance (the one granted telemetry bend), and a one-tap Watch app with distinct
   haptic patterns. Journeys H1–H4. **No transcript ever appears here** — the calm confidence that
   nothing is lost *is* the product.

**Hand back (brief §4):**
1. Screen designs per journey per surface (S1–S6 uplift, P1–P3, H1–H4) at real device sizes —
   iPhone, iPad regular-width landscape, Watch — including the unglamorous states: empty, loading,
   failed, "can't reach hub", unregistered device, conflict copy.
2. A design system for the app family grounded in the existing `Theme.swift` tokens (inventory in
   the implementation doc): keep/extend/replace, plus how the Mimer character (rich reader/thinker)
   and Heimdal character (thin, truthful daemon) stay visibly siblings.
3. The two-axis grades for as-built B1, with uplift moves ranked by leverage.
4. A per-surface stance on how the UI expresses "markdown holds the record" (e.g. open-in-Obsidian
   affordances) within the two ruled bends.
5. Any conflict with a spec'd acceptance criterion flagged explicitly as *advisory — owner ruling
   needed*; never a silent redesign.

**Hard constraints to honour on every screen:** dyslexia-safe (visual pick, no typed paths or ids,
lead with the answer, fewest decisions); reversible autonomy (one gesture to undo, steering after
the fact); failure visible, never silent; Dynamic Type/system-dynamic colors (dark mode must hold);
SF Symbols unless you argue otherwise; no push-notification-dependent patterns.

**Out of scope (brief §5):** backend/pipeline; relitigating §2 rulings; posture-B activation UX as
a shippable feature (show it only as a legible future mode); video capture; building anything —
implementation stays issue-first in the existing slice wave.
