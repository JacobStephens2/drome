"use strict";

const SHA = /^[0-9a-fA-F]{40}$/;
const MODES = new Set(["normal", "fresh", "restore"]);

function acceptDeployInputs({ eventName, rollbackSha, deployMode, headSha }) {
  if (eventName === "workflow_dispatch") {
    const rollback = rollbackSha ?? "";
    const mode = deployMode ?? "";
    if (rollback !== "" && !SHA.test(rollback)) {
      throw new Error("rollback_sha must be empty or a 40-hex SHA");
    }
    if (!MODES.has(mode)) {
      throw new Error("deploy_mode must be normal, fresh, or restore");
    }
    const sha = rollback === "" ? headSha : rollback;
    if (!SHA.test(sha)) {
      throw new Error("HEAD sha is not a 40-hex SHA");
    }
    return { sha, mode };
  }
  // Push (and any non-dispatch event) does not take workflow_dispatch inputs.
  if (!SHA.test(headSha ?? "")) {
    throw new Error("HEAD sha is not a 40-hex SHA");
  }
  return { sha: headSha, mode: "normal" };
}

module.exports = { acceptDeployInputs };
