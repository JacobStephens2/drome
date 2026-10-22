const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const workflowPath = path.join(
  __dirname,
  "../../.github/workflows/server-deploy.yml",
);
const workflow = fs.readFileSync(workflowPath, "utf8");

function indentedBlocks(text, key) {
  const lines = text.split("\n");
  const blocks = [];
  for (let i = 0; i < lines.length; i++) {
    const match = lines[i].match(new RegExp(`^(\\s*)${key}:\\s*(.*)$`));
    if (!match) continue;
    const indent = match[1].length;
    const rest = match[2];
    if (rest === "|" || rest === "|-" || rest === ">" || rest === ">-") {
      const body = [];
      for (let j = i + 1; j < lines.length; j++) {
        if (lines[j].trim() === "") {
          body.push(lines[j]);
          continue;
        }
        const nextIndent = lines[j].match(/^(\s*)/)[1].length;
        if (nextIndent <= indent) break;
        body.push(lines[j]);
      }
      blocks.push(body.join("\n"));
    } else if (rest !== "") {
      blocks.push(rest);
    }
  }
  return blocks;
}

test("server-deploy passes rollback_sha and deploy_mode through env, not a shell", () => {
  for (const body of indentedBlocks(workflow, "run")) {
    assert.doesNotMatch(body, /github\.event\.inputs\.rollback_sha/);
    assert.doesNotMatch(body, /github\.event\.inputs\.deploy_mode/);
    assert.doesNotMatch(body, /\$\{\{\s*inputs\.(rollback_sha|deploy_mode)\s*\}\}/);
  }

  assert.match(workflow, /uses:\s*actions\/github-script@v9/);
  assert.match(
    workflow,
    /ROLLBACK_SHA:\s*\$\{\{\s*github\.event_name == 'workflow_dispatch' && github\.event\.inputs\.rollback_sha \|\| ''\s*\}\}/,
  );
  assert.match(
    workflow,
    /DEPLOY_MODE:\s*\$\{\{\s*github\.event_name == 'workflow_dispatch' && github\.event\.inputs\.deploy_mode \|\| ''\s*\}\}/,
  );

  const scripts = indentedBlocks(workflow, "script");
  assert.equal(scripts.length, 1);
  assert.match(scripts[0], /require\('\.\/deploy\/accept-deploy-inputs\.js'\)/);
  assert.doesNotMatch(scripts[0], /\$\{\{/);
  assert.match(scripts[0], /process\.env\.ROLLBACK_SHA/);
  assert.match(scripts[0], /process\.env\.DEPLOY_MODE/);

  const deployRun = indentedBlocks(workflow, "run").find((body) =>
    body.includes("./deploy/deploy.sh"),
  );
  assert.ok(deployRun);
  assert.match(deployRun, /case "\$DEPLOY_MODE"/);
  assert.match(workflow, /steps\.deploy_inputs\.outputs\.sha/);
  assert.match(workflow, /steps\.deploy_inputs\.outputs\.mode/);
});

test("push to main still deploys without workflow_dispatch inputs", () => {
  assert.match(workflow, /push:\n\s+branches:\s*\[main\]/);
  const pushGated = workflow.match(/if:\s*github\.event_name == 'push'/g) || [];
  assert.equal(pushGated.length, 2);
  assert.match(
    workflow,
    /if:\s*>-\n\s+vars\.DEPLOY_ENABLED == 'true' &&\n\s+always\(\) &&\n\s+\(github\.event_name == 'workflow_dispatch' \|\| needs\.build\.result == 'success'\)/,
  );
});
