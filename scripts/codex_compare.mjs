// Small, opt-in live transport/cache probe. No dependencies or config-file edits.
import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { parseArgs } from "node:util";

const { values } = parseArgs({ options: {
  model: { type: "string" },
  "base-url": { type: "string" },
  "key-env": { type: "string", default: "DODO_API_KEY_CODEX" },
  pairs: { type: "string", default: "2" },
  "dry-run": { type: "boolean", default: false },
  help: { type: "boolean", default: false },
} });
if (values.help) {
  console.log("node scripts/codex_compare.mjs --model MODEL --base-url https://api.dodorouter.com/r/ROUTER/v1 [--key-env DODO_API_KEY_CODEX] [--pairs 2] [--dry-run]\nRequires the named proxy-key environment variable and an existing Codex ChatGPT login. Uses subscription quota. Four turns per session, two sessions per pair.");
  process.exit(0);
}
const pairs = Number(values.pairs);
if (!values.model || !values["base-url"] || !Number.isInteger(pairs) || pairs < 1 || pairs > 5) {
  throw new Error("Supply --model, --base-url and --pairs between 1 and 5. See --help.");
}
const base = new URL(values["base-url"]);
if (base.protocol !== "https:" || base.username || base.password || base.search || base.hash || !/^\/r\/[^/]+\/v1\/?$/.test(base.pathname)) {
  throw new Error("Use an HTTPS router base URL ending /r/ROUTER/v1, without credentials or query parameters.");
}
if (!/^[A-Z_][A-Z0-9_]*$/.test(values["key-env"])) throw new Error("Invalid --key-env name.");
const proxyKey = process.env[values["key-env"]];
if (!values["dry-run"] && !proxyKey) {
  throw new Error(`${values["key-env"]} is missing; no requests were sent.`);
}
const rows = Array.from({ length: 256 }, (_, i) => `record-${String(i).padStart(3, "0")}: code=CODE${String(i * 37 + 101).padStart(6, "0")}; units=${i + 3}; region=synthetic; status=active`);
const turns = [
  ["Use this synthetic catalog for this turn and subsequent questions. Do not call tools, browse, or read files. Return only the requested code, no explanation.\n" + rows.join("\n") + "\nWhat is the code of record-017?", "CODE000730"],
  ["What is the code of record-201? Return only the code; do not use tools.", "CODE007538"],
  ["What is the code of record-083? Return only the code; do not use tools.", "CODE003172"],
  ["What is the code of record-254? Return only the code; do not use tools.", "CODE009499"],
];
const plan = {
  model: values.model, dodo_base_url: base.href, pairs,
  planned_cli_turns: pairs * 2 * turns.length,
  note: "Same synthetic workload; no explicit CLI reasoning-effort override; resumed sessions; alternate pair order. Codex may supply its own model default. Initial turns are not guaranteed cold. Elapsed time includes CLI startup. Usage is CLI-reported, not a count of upstream attempts. Confirm Dodo's served model, reasoning settings and provider account through logs before drawing conclusions.",
};
if (values["dry-run"]) {
  console.log(JSON.stringify(plan, null, 2));
  process.exit(0);
}
const runDir = mkdtempSync(join(tmpdir(), "dodo-codex-compare-"));
const results = [];
writeFileSync(join(runDir, "plan.json"), JSON.stringify(plan, null, 2));
console.log(`Results: ${runDir}`);

function runTurn(path, pair, turn, session) {
  const args = ["exec", ...(session ? ["resume"] : []),
    "--ignore-user-config", "--skip-git-repo-check", "--json", "-m", values.model,
    "-c", 'sandbox_mode="read-only"', "-c", 'approval_policy="never"',
    "-c", 'web_search="disabled"',
    "-c", `shell_environment_policy.exclude=[${JSON.stringify(values["key-env"])}]`,
  ];
  if (path === "dodo") {
    args.push("-c", 'model_provider="dodorouter"',
      "-c", 'model_providers.dodorouter.name="DodoRouter"',
      "-c", `model_providers.dodorouter.base_url=${JSON.stringify(base.href.replace(/\/$/, ""))}`,
      "-c", `model_providers.dodorouter.env_key=${JSON.stringify(values["key-env"])}`,
      "-c", 'model_providers.dodorouter.wire_api="responses"',
      "-c", 'model_providers.dodorouter.supports_websockets=false');
  } else {
    args.push("-c", 'model_provider="openai"');
  }
  if (session) args.push(session);
  args.push("-");
  const env = { ...process.env };
  // Prevent endpoint/API-key overrides from silently changing the direct baseline.
  delete env.OPENAI_BASE_URL;
  delete env.OPENAI_API_KEY;
  if (path === "direct") {
    delete env[values["key-env"]];
    // The localhost CA is for the proxy only. Applying it to OpenAI's public
    // WebSocket endpoint causes UnknownIssuer retries and corrupts timings.
    delete env.SSL_CERT_FILE;
  }
  const started = Date.now();
  const child = spawnSync("codex", args, {
    cwd: runDir, env, input: turns[turn][0], encoding: "utf8",
    timeout: 120_000, killSignal: "SIGKILL", maxBuffer: 10 * 1024 * 1024,
  });
  const elapsed = Date.now() - started;
  const redact = (s) => (s ?? "").split(proxyKey).join("[REDACTED]");
  const prefix = `${pair}-${path}-${turn + 1}`;
  writeFileSync(join(runDir, `${prefix}.jsonl`), redact(child.stdout), { mode: 0o600 });
  writeFileSync(join(runDir, `${prefix}.stderr`), redact(child.stderr), { mode: 0o600 });
  const events = (child.stdout ?? "").split("\n").flatMap(line => {
    try { return [JSON.parse(line)]; } catch { return []; }
  });
  const thread = events.find(e => e.type === "thread.started")?.thread_id ?? session;
  const completed = events.filter(e => e.type === "turn.completed");
  const answer = events.filter(e => e.type === "item.completed" && e.item?.type === "agent_message").at(-1)?.item.text?.trim();
  const usage = completed.at(-1)?.usage ?? null;
  const result = {
    path, pair, turn: turn + 1, session_id: thread ?? null,
    started_at: new Date(started).toISOString(), elapsed_ms: elapsed,
    exit_code: child.status, error: child.error?.code ?? null,
    correct: answer === turns[turn][1], completed: completed.length === 1,
    usage, usage_scope: "raw_codex_counter_may_be_session_cumulative", answer: redact(answer),
  };
  results.push(result);
  writeFileSync(join(runDir, "results.json"), JSON.stringify(results, null, 2));
  console.log(JSON.stringify(result));
  if (child.status !== 0 || !result.completed || !thread || !result.correct) {
    throw new Error(`Probe stopped at ${prefix}; inspect ${runDir}. Failures are retained, not discarded.`);
  }
  return thread;
}

for (let pair = 1; pair <= pairs; pair++) {
  for (const path of pair % 2 ? ["direct", "dodo"] : ["dodo", "direct"]) {
    let session;
    for (let turn = 0; turn < turns.length; turn++) session = runTurn(path, pair, turn, session);
  }
}
console.log("Probe complete. Compare follow-up turns separately from initial turns. This small test is not a coding benchmark or proof of cache equivalence; inspect served model, fallback and account identity in Dodo MCP logs.");
