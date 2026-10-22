const test = require("node:test");
const assert = require("node:assert/strict");
const { acceptDeployInputs } = require("../../deploy/accept-deploy-inputs");

const HEAD = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const PINNED = "0123456789abcdefABCDEF0123456789abcdefAB";

test("workflow_dispatch rejects a rollback_sha that is not empty or a 40-hex SHA", () => {
  assert.throws(
    () =>
      acceptDeployInputs({
        eventName: "workflow_dispatch",
        rollbackSha: "not-a-sha; touch /tmp/pwned",
        deployMode: "normal",
        headSha: HEAD,
      }),
    /rollback_sha must be empty or a 40-hex SHA/,
  );
});

test("workflow_dispatch selects a 40-hex rollback_sha instead of HEAD", () => {
  const accepted = acceptDeployInputs({
    eventName: "workflow_dispatch",
    rollbackSha: PINNED,
    deployMode: "normal",
    headSha: HEAD,
  });
  assert.equal(accepted.sha, PINNED);
  assert.equal(accepted.mode, "normal");
});

test("workflow_dispatch with an empty rollback_sha selects HEAD", () => {
  for (const mode of ["normal", "fresh", "restore"]) {
    const accepted = acceptDeployInputs({
      eventName: "workflow_dispatch",
      rollbackSha: "",
      deployMode: mode,
      headSha: HEAD,
    });
    assert.equal(accepted.sha, HEAD);
    assert.equal(accepted.mode, mode);
  }
});

test("workflow_dispatch rejects a deploy_mode other than normal, fresh, or restore", () => {
  assert.throws(
    () =>
      acceptDeployInputs({
        eventName: "workflow_dispatch",
        rollbackSha: "",
        deployMode: "fresh; curl evil.example",
        headSha: HEAD,
      }),
    /deploy_mode must be normal, fresh, or restore/,
  );
});

test("push does not take rollback_sha or deploy_mode and selects HEAD in normal mode", () => {
  const accepted = acceptDeployInputs({
    eventName: "push",
    rollbackSha: "not-a-sha; touch /tmp/pwned",
    deployMode: "fresh; curl evil.example",
    headSha: HEAD,
  });
  assert.equal(accepted.sha, HEAD);
  assert.equal(accepted.mode, "normal");
});

test("workflow_dispatch rejects rollback_sha values that are not exactly 40 hex digits", () => {
  const rejected = [
    "0123456789abcdef",
    `${PINNED}\nIMAGE_TAG=evil`,
    ` ${PINNED}`,
    `${PINNED} `,
    "deadbeef",
    "0".repeat(39),
    "0".repeat(41),
  ];
  for (const rollbackSha of rejected) {
    assert.throws(
      () =>
        acceptDeployInputs({
          eventName: "workflow_dispatch",
          rollbackSha,
          deployMode: "normal",
          headSha: HEAD,
        }),
      /rollback_sha must be empty or a 40-hex SHA/,
      rollbackSha,
    );
  }
});

test("workflow_dispatch rejects deploy_mode outside the three known names", () => {
  for (const deployMode of ["", "Fresh", "NORMAL", "normal ", " restore", undefined]) {
    assert.throws(
      () =>
        acceptDeployInputs({
          eventName: "workflow_dispatch",
          rollbackSha: "",
          deployMode,
          headSha: HEAD,
        }),
      /deploy_mode must be normal, fresh, or restore/,
      String(deployMode),
    );
  }
});

test("workflow_dispatch treats a missing rollback_sha as empty and selects HEAD", () => {
  const accepted = acceptDeployInputs({
    eventName: "workflow_dispatch",
    deployMode: "restore",
    headSha: HEAD,
  });
  assert.equal(accepted.sha, HEAD);
  assert.equal(accepted.mode, "restore");
});

test("a HEAD that is not a 40-hex SHA is refused on push and on an empty rollback", () => {
  assert.throws(
    () =>
      acceptDeployInputs({
        eventName: "push",
        headSha: "main",
      }),
    /HEAD sha is not a 40-hex SHA/,
  );
  assert.throws(
    () =>
      acceptDeployInputs({
        eventName: "workflow_dispatch",
        rollbackSha: "",
        deployMode: "normal",
        headSha: "main",
      }),
    /HEAD sha is not a 40-hex SHA/,
  );
});
