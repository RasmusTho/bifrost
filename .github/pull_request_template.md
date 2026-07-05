## Change Lane
- [ ] Implementation lane
- [ ] Docs authoring lane
- [ ] Governance lane

Docs authoring applies only to docs-only changes. Governance lane applies to bounded repo-governance changes
(templates, labels, CI policy, skills routing). Neither may be used for product/runtime app implementation.

## Linked Issue
Fixes #

Required for implementation lane. App slices are tracked in the hub repo until Bifrost has its own board
(ADR-0050 §1) — link the hub Issue, e.g. `Fixes RasmusTho/agentic-pkm-mvp#<n>`.

## SBS Impact
Classify Product/Runtime System, Builder System, or boundary work per the hub's
`docs/architecture/SBS_OPERATING_MODEL.md` §3, then fill impact per §4; use "none"/"unaffected" explicitly
rather than leaving a field blank. Bifrost is a Product/Runtime surface built by the Builder System.
- Primary subsystem:
- Secondary subsystem(s):
- Write class:
- Authority impact:
- Persistence impact:
- Human knowledge impact:
- Sync/deployment impact:
- External boundary impact:
- New or changed contract:
- Owner-doc impact:
- Transition debt impact:
- Boundary risk:

## Owner-Doc Writeback
Resolve to exactly one (hub `docs/architecture/SBS_OPERATING_MODEL.md` §9). A "to update later" note is not acceptable.
- [ ] No owner-doc change implied.
- [ ] Owner-doc updated in this PR (or a linked hub PR).
- [ ] Owner-doc follow-up issue created and linked.

## Summary
-
-

## Implementation Scope Check
- [ ] Change stays within the linked Issue scope.
- [ ] Constraints from the linked Issue were followed.
- [ ] Acceptance Criteria from the linked Issue are satisfied.
- [ ] The markdown vault stays the source of record; no capability is app-only.
- [ ] Docs were updated in the same change when behavior/contracts changed.

## Validation
Implementation lane (Swift/iOS):
- [ ] `xcodebuild build` succeeds for the app scheme(s)
- [ ] `xcodebuild test` passes (unit/UI where present)
- [ ] `swiftlint` clean, or gaps stated explicitly
- [ ] Additional targeted checks run as needed

Docs authoring / Governance lane:
- [ ] Checks appropriate for the touched surfaces run
- [ ] Any validation gaps or tooling limitations are stated explicitly

## BuilderOps Routing
- Records/projections/receipts: <ids or "none">
- Reason: <why no BuilderOps material was created, or what was routed>

## Notes
- State any residual risks, follow-ups, or assumptions.
