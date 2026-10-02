// Run with: node --test scripts/lib/reload-auth.test.mjs
// Execute reload's argument parser and auth preflight before tag cleanup/build.
// Like reload-shim.test.mjs, the harness avoids starting a real build.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const scriptDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
function runPreflight(args, credentials, mode = 0o600) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "cmux-reload-auth-"));
  try {
    const source = fs.readFileSync(path.join(scriptDir, "reload.sh"), "utf8");
    const boundary = source.indexOf('\nif [[ -n "$TAG" ]]; then\n');
    assert.ok(boundary > 0, "auth preflight must precede tag isolation");
    fs.mkdirSync(path.join(root, "lib"));
    for (const name of ["mobile-attach.sh", "dev-secrets.sh"]) {
      fs.copyFileSync(path.join(scriptDir, "lib", name), path.join(root, "lib", name));
    }
    const harness = path.join(root, "reload-preflight.sh");
    fs.writeFileSync(harness, source.slice(0, boundary) + '\nprintf "preflight-ok:%s:%s\\n" "$AUTH_PROFILE" "$AUTH_EXPECTED_ACCOUNT"\n');
    const credentialPath = path.join(root, "credentials.env");
    if (credentials !== undefined) fs.writeFileSync(credentialPath, credentials, { mode });
    const argv = args.map((arg) => arg === "CREDENTIALS" ? credentialPath : arg);
    return spawnSync("/bin/bash", [harness, "--tag", "auth-regression", ...argv], {
      encoding: "utf8", timeout: 5000,
      env: { HOME: root, PATH: "/usr/bin:/bin", TMPDIR: root },
    });
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
}

for (const args of [["--launch"], ["--launch", "--prod-auth"], []]) {
  test(`local reload ${args.join(" ")} needs no cloud credentials`, () => {
    const result = runPreflight(args);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout, "preflight-ok::\n");
  });
}
for (const profile of ["personal", "agent"]) {
  test(`explicit ${profile} launch rejects missing credentials`, () => {
    const result = runPreflight(["--launch", "--auth-profile", profile]);
    assert.notEqual(result.status, 0);
    assert.doesNotMatch(result.stdout, /preflight-ok/);
  });
}
const personal = "CMUX_DOGFOOD_STACK_EMAIL=Person@Example.test\nCMUX_DOGFOOD_STACK_PASSWORD=fixture-password\n";
test("explicit profile validates and normalizes the selected account", () => {
  const result = runPreflight(["--launch", "--auth-profile", "personal", "--credentials-file", "CREDENTIALS", "--expected-account", "person@example.test"], personal);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, "preflight-ok:personal:person@example.test\n");
  assert.doesNotMatch(result.stdout + result.stderr, /fixture-password/);
});
test("explicit profile rejects a different expected account", () => {
  const result = runPreflight(["--launch", "--auth-profile", "personal", "--credentials-file", "CREDENTIALS", "--expected-account", "other@example.test"], personal);
  assert.notEqual(result.status, 0);
  assert.doesNotMatch(result.stdout, /preflight-ok/);
});
test("agent launch cannot borrow personal credentials", () => {
  const result = runPreflight(["--launch", "--auth-profile", "agent", "--credentials-file", "CREDENTIALS"], personal);
  assert.notEqual(result.status, 0);
  assert.doesNotMatch(result.stdout, /preflight-ok/);
});
test("explicit credential file rejects unsafe permissions", () => {
  const result = runPreflight(["--launch", "--credentials-file", "CREDENTIALS"], personal, 0o644);
  assert.notEqual(result.status, 0);
  assert.doesNotMatch(result.stdout, /preflight-ok/);
});
