// Run with: node --test scripts/lib/wireguard-go-build.test.mjs
// Run the complete build script with an instrumented Go executable. It records
// each compiler invocation and emits a real C archive without downloading Go modules.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const script = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../build-wireguard-go.sh");
for (const customCache of [false, true]) {
  test(`WireGuard build owns its Go caches${customCache ? " with an explicit cache root" : " by default"}`, () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), "cmux-wireguard-cache-"));
    try {
      const go = path.join(root, "go");
      const record = path.join(root, "invocations.jsonl");
      const output = path.join(root, "libwg-go.a");
      const temp = path.join(root, "intermediates");
      const cacheRoot = customCache ? path.join(root, "cache with spaces") : path.join(temp, "wireguard-go", "go-cache");
      fs.writeFileSync(go, `#!${process.execPath}
const fs = require("node:fs");
const cp = require("node:child_process");
const path = require("node:path");
const args = process.argv.slice(2);
if (args[0] === "version") { console.log("go version fixture"); process.exit(0); }
if (args[0] !== "build") process.exit(2);
fs.appendFileSync(process.env.CACHE_TEST_RECORD, JSON.stringify({
  args, arch: process.env.GOARCH, gopath: process.env.GOPATH,
  modcache: process.env.GOMODCACHE, buildcache: process.env.GOCACHE,
  toolchain: process.env.GOTOOLCHAIN, flags: process.env.GOFLAGS
}) + "\\n");
const archive = args[args.indexOf("-o") + 1];
const source = path.join(path.dirname(archive), "fixture.c");
const object = archive + ".o";
fs.writeFileSync(source, "int wgTurnOn(void) { return 1; }\\n");
const arch = process.env.GOARCH === "amd64" ? "x86_64" : "arm64";
let result = cp.spawnSync("/usr/bin/xcrun", ["clang", "-arch", arch, "-c", source, "-o", object]);
if (result.status) process.exit(result.status);
result = cp.spawnSync("/usr/bin/libtool", ["-static", "-o", archive, object]);
process.exit(result.status);
`, { mode: 0o755 });
      const environment = {
        HOME: root, PATH: "/usr/bin:/bin", TMPDIR: root,
        GOPATH: "/go", GOMODCACHE: "/go/pkg/mod", GOCACHE: "/go/build-cache",
        CACHE_TEST_RECORD: record, CMUX_WIREGUARD_GO_BINARY: go,
        CMUX_WIREGUARD_GO_REQUIRE: "1", CMUX_WIREGUARD_GO_ARCHS: "arm64 x86_64 arm64",
        CMUX_WIREGUARD_GO_OUTPUT: output, TARGET_TEMP_DIR: temp,
      };
      if (customCache) environment.CMUX_WIREGUARD_GO_CACHE_DIR = cacheRoot;
      const result = spawnSync("/bin/bash", [script], {
        encoding: "utf8", timeout: 30000, env: environment,
      });
      assert.equal(result.status, 0, result.stderr);
      assert.ok(fs.statSync(output).size > 0);
      const records = fs.readFileSync(record, "utf8").trim().split("\n").map(JSON.parse);
      assert.deepEqual(records.map((r) => r.arch), ["arm64", "amd64"]);
      for (const invocation of records) {
        assert.equal(invocation.gopath, cacheRoot);
        assert.equal(invocation.modcache, path.join(cacheRoot, "pkg", "mod"));
        assert.equal(invocation.buildcache, path.join(cacheRoot, "build"));
        assert.equal(invocation.toolchain, "local");
        assert.equal(invocation.flags, "-mod=readonly");
      }
      const architectures = spawnSync("/usr/bin/lipo", ["-archs", output], { encoding: "utf8" });
      assert.equal(architectures.status, 0, architectures.stderr);
      assert.deepEqual(new Set(architectures.stdout.trim().split(/\s+/)), new Set(["arm64", "x86_64"]));
    } finally {
      fs.rmSync(root, { recursive: true, force: true });
    }
  });
}
