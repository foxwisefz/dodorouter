import test from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const script = resolve("scripts/codex_compare.mjs");
const args = ["--model", "test-model", "--base-url", "https://example.test/r/codex/v1"];
test("dry run plans sixteen turns without credentials or network", () => {
  const result = spawnSync(process.execPath, [script, ...args, "--dry-run"], { encoding: "utf8" });
  assert.equal(result.status, 0);
  assert.equal(JSON.parse(result.stdout).planned_cli_turns, 16);
});
test("missing credentials fail before sending traffic", () => {
  const env = { ...process.env };
  delete env.DODO_API_KEY_CODEX;
  const result = spawnSync(process.execPath, [script, ...args], { encoding: "utf8", env });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /is missing; no requests were sent/);
});
test("rejects URLs containing credentials", () => {
  const result = spawnSync(process.execPath, [script, "--model", "test", "--base-url", "https://secret@example.test/r/codex/v1", "--dry-run"], { encoding: "utf8" });
  assert.notEqual(result.status, 0);
});
test("paired runner resumes separate sessions, alternates order, and retains usage", () => {
  const bin = mkdtempSync(join(tmpdir(), "codex-compare-test-"));
  writeFileSync(join(bin, "codex"), `#!${process.execPath}
const fs = require("node:fs");
const assert = require("node:assert/strict");
const args = process.argv.slice(2);
const prompt = fs.readFileSync(0, "utf8");
const dodo = args.includes('model_provider="dodorouter"');
assert.equal(Boolean(process.env.DODO_API_KEY_CODEX), dodo);
assert.ok(args.includes("--ignore-user-config"));
assert.ok(args.includes('sandbox_mode="read-only"'));
if (args[1] === "resume") assert.ok(args.includes(dodo ? "dodo-session" : "direct-session"));
const i = Number([...prompt.matchAll(/record-(\\d+)\\?/g)].at(-1)[1]);
console.log(JSON.stringify({type:"thread.started", thread_id:dodo ? "dodo-session" : "direct-session"}));
console.log(JSON.stringify({type:"item.completed", item:{type:"agent_message",text:"CODE"+String(i*37+101).padStart(6,"0")}}));
console.log(JSON.stringify({type:"turn.completed",usage:{input_tokens:1000,cached_input_tokens:800,output_tokens:5}}));
`, { mode: 0o700 });
  const result = spawnSync(process.execPath, [script, ...args], {
    encoding: "utf8", env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, DODO_API_KEY_CODEX: "test-secret" },
  });
  assert.equal(result.status, 0, result.stderr);
  const dir = result.stdout.split("\n")[0].replace("Results: ", "");
  const rows = JSON.parse(readFileSync(join(dir, "results.json"), "utf8"));
  assert.equal(rows.length, 16);
  assert.deepEqual([rows[0].path, rows[4].path, rows[8].path, rows[12].path], ["direct", "dodo", "dodo", "direct"]);
  assert.ok(rows.every(r => r.correct && r.completed && r.usage.cached_input_tokens === 800));
});
