#!/usr/bin/env node

import assert from "node:assert/strict";
import crypto from "node:crypto";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const workflowPath = fileURLToPath(
  new URL("../workflows/issue-pr-governance.yml", import.meta.url),
);
const workflow = readFileSync(workflowPath, "utf8");

const extract = (start, end) => {
  const afterStart = workflow.split(start, 2);
  assert.equal(afterStart.length, 2, `missing workflow marker: ${start}`);
  const beforeEnd = afterStart[1].split(end, 2);
  assert.equal(beforeEnd.length, 2, `missing workflow marker: ${end}`);
  return beforeEnd[0];
};

const classifierSource = extract(
  "// authority-classifier:start",
  "// authority-classifier:end",
);
const validatorSource = extract(
  "// neutralized-authority-validator:start",
  "// neutralized-authority-validator:end",
);
const pinnedAuthorityDigest = crypto
  .createHash("sha256")
  .update(classifierSource + validatorSource)
  .digest("hex");

assert.equal(
  pinnedAuthorityDigest,
  "ec8102580c1b0fcaa5b7573bbc50afb29ee98cd775348a816e562dc504e74dfb",
  "authority code drifted from the explicitly pinned hub source",
);

const { classifyIssueAuthority, resolveNeutralizedMergeAuthority } = new Function(
  "crypto",
  `${classifierSource}\n${validatorSource}\nreturn { classifyIssueAuthority, resolveNeutralizedMergeAuthority };`,
)(crypto);

const sha256 = (value) =>
  crypto.createHash("sha256").update(value, "utf8").digest("hex");

const makeFixture = () => {
  const repository = "RasmusTho/bifrost";
  const head = "a".repeat(40);
  const originalBody = [
    "Governing-Issue: #25",
    "Refs #25",
    "Fixes #25",
    "Refs #8",
    "",
  ].join("\n");
  const neutralizedBody = [
    "Governing-Issue: #25",
    "Refs #25",
    "Refs #8",
    "Verified-Closing-Issues: #25",
    "",
  ].join("\n");
  const receipt = {
    authenticated_supporting_issues: [],
    body_sha256: sha256(originalBody),
    closing_issues: [25],
    contract: "verified_issue_set_merge_authority.v1",
    governing_issue: 25,
    head_sha: head,
    live_supporting_issues: [8],
    neutralized_body_sha256: sha256(neutralizedBody),
    pr_number: 26,
    repair_budget: { mechanisms: [], policy_version: "v2" },
    repository,
    run_id: "bifrost-pr-contract-fixture",
  };
  const pullRequest = {
    body: neutralizedBody,
    head: { sha: head },
    number: 26,
  };
  return { originalBody, neutralizedBody, pullRequest, receipt, repository };
};

const commentFor = (receipt, authorAssociation = "COLLABORATOR") => ({
  author_association: authorAssociation,
  body: [
    "verified issue-set merge authority:",
    "```json",
    JSON.stringify(receipt),
    "```",
  ].join("\n"),
});

const resolve = ({ comments, pullRequest, repository }) => {
  const issueAuthority = classifyIssueAuthority(pullRequest.body);
  return resolveNeutralizedMergeAuthority({
    comments,
    issueAuthority,
    pullRequest,
    repository,
  });
};

const tests = [];
const test = (name, body) => tests.push({ name, body });

test("normal_issue_backed_body_passes", () => {
  const body = [
    "Governing-Issue: #25",
    "",
    "Fixes #25",
    "",
    "## SBS Impact",
    "- Primary subsystem: Builder System / CES boundary",
    "- Owner-doc impact: none",
    "",
    "## Owner-Doc Writeback",
    "- [x] No owner-doc change implied.",
    "",
    "## BuilderOps Routing",
    "- Records/projections/receipts: none",
    "- Reason: D19 containment is recorded in this ordinary delivery receipt.",
  ].join("\n");
  const authority = classifyIssueAuthority(body);
  assert.equal(authority.valid, true);
  assert.equal(authority.governingIssue, 25);
  assert.deepEqual(authority.closingIssues, [25]);
  assert.match(workflow, /## BuilderOps Routing/);
});

test("trusted_neutralized_authority_passes", () => {
  const fixture = makeFixture();
  const authority = classifyIssueAuthority(fixture.neutralizedBody);
  assert.equal(authority.valid, false);
  assert.equal(authority.neutralizedValid, true);
  assert.deepEqual(authority.neutralizedClosingIssues, [25]);
  assert.deepEqual(authority.supportingIssues, [8]);
  assert.deepEqual(
    resolve({
      comments: [commentFor(fixture.receipt)],
      pullRequest: fixture.pullRequest,
      repository: fixture.repository,
    }),
    fixture.receipt,
  );
});

test("invalid_authority_fixtures_fail_closed", () => {
  const fixture = makeFixture();
  const cases = new Map();

  cases.set("missing", []);
  cases.set("forged", [commentFor(fixture.receipt, "NONE")]);

  const stale = structuredClone(fixture.receipt);
  stale.neutralized_body_sha256 = sha256(`${fixture.neutralizedBody}\nstale`);
  cases.set("stale", [commentFor(stale)]);

  const foreignRepository = structuredClone(fixture.receipt);
  foreignRepository.repository = "RasmusTho/agentic-pkm-mvp";
  cases.set("foreign-repository", [commentFor(foreignRepository)]);

  const wrongHead = structuredClone(fixture.receipt);
  wrongHead.head_sha = "b".repeat(40);
  cases.set("wrong-head", [commentFor(wrongHead)]);

  const wrongBody = structuredClone(fixture.receipt);
  wrongBody.body_sha256 = fixture.receipt.neutralized_body_sha256;
  cases.set("wrong-body", [commentFor(wrongBody)]);

  const wrongIssueSet = structuredClone(fixture.receipt);
  wrongIssueSet.closing_issues = [8];
  cases.set("wrong-issue-set", [commentFor(wrongIssueSet)]);

  const wrongPr = structuredClone(fixture.receipt);
  wrongPr.pr_number = 27;
  cases.set("wrong-pr", [commentFor(wrongPr)]);

  const missingRunId = structuredClone(fixture.receipt);
  missingRunId.run_id = "";
  cases.set("missing-run-id", [commentFor(missingRunId)]);

  const missingRepairBudget = structuredClone(fixture.receipt);
  missingRepairBudget.repair_budget = null;
  cases.set("missing-repair-budget", [commentFor(missingRepairBudget)]);

  const conflicting = structuredClone(fixture.receipt);
  conflicting.run_id = "bifrost-pr-contract-conflict";
  cases.set("conflicting-trusted", [
    commentFor(fixture.receipt),
    commentFor(conflicting),
  ]);

  for (const [name, comments] of cases) {
    assert.equal(
      resolve({
        comments,
        pullRequest: fixture.pullRequest,
        repository: fixture.repository,
      }),
      null,
      `${name} authority must fail closed`,
    );
  }
});

test("workflow_structure_and_source_pin_passes", () => {
  assert.match(
    workflow,
    /RasmusTho\/agentic-pkm-mvp@6aed789fa6d4d25de7d6137894fb20524499b084/,
  );
  assert.match(workflow, /not automatically synchronized with the hub/);
  assert.match(
    workflow,
    /types: \[opened, edited, reopened, synchronize, review_requested\]/,
  );
  assert.match(workflow, /^  pr-contract:\n/m);
  assert.match(workflow, /pull-requests: read/);
  assert.match(workflow, /issues: read/);
  assert.match(workflow, /receipt\.repository === repository/);
  assert.match(workflow, /receipt\.head_sha === pullRequest\.head\?\.sha/);
  assert.match(workflow, /receipt\.neutralized_body_sha256 === liveDigest/);
  assert.match(workflow, /new Set\(valid\.map\(canonicalJson\)\)\.size !== 1/);
});

let failures = 0;
for (const { name, body } of tests) {
  try {
    body();
    console.log(`ok - ${name}`);
  } catch (error) {
    failures += 1;
    console.error(`not ok - ${name}`);
    console.error(error.stack || error);
  }
}

if (failures > 0) {
  process.exitCode = 1;
} else {
  console.log(`1..${tests.length}`);
}
