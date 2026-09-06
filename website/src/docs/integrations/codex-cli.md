---
title: Codex CLI
description: Add DodoRouter as a custom model_providers entry in ~/.codex/config.toml.
order: 16
---

# Codex CLI

OpenAI's Codex CLI supports custom model providers in `~/.codex/config.toml`:

```toml
model = "default"
model_provider = "dodorouter"

[model_providers.dodorouter]
name = "DodoRouter"
base_url = "{base_url}/r/{router}/v1"
env_key = "DODO_API_KEY"
wire_api = "responses"
```

`env_key` names an environment variable Codex reads the API key from, so the key itself never has to live in the config file:

```bash
export DODO_API_KEY="sk-dodo-YOUR_KEY"
codex exec "Reply with exactly the single word: pong"
```

Earlier smoke tests verified streamed `pong` responses and usage recording. An earlier version of DodoRouter's streamed [Responses API](/docs/api/responses/) didn't emit the item-lifecycle events Codex CLI requires before a text delta, causing `OutputTextDelta without active item` and a stall; that lifecycle issue was fixed. Compatibility still depends on the configured upstream model and current client version. Run a smoke test for your configuration before relying on it.

## Compare DodoRouter with direct Codex

Current Codex versions can send `additional_tools` and other non-message input
items. Responses-format upstream routes preserve these items instead of turning
them into developer messages with null content. See [typed input items](/docs/api/responses/#typed-input-items)
and [the null-content troubleshooting note](/docs/troubleshooting/#codex-input-0-content-is-null).

The repository includes an opt-in transport and prompt-cache probe. It uses an
existing Codex ChatGPT login for the direct path and a router key from an
environment variable for DodoRouter. It does not edit your Codex configuration
or router settings. Live runs consume provider quota and may incur charges on
metered router keys.

First configure the router to serve the **same model** as the direct path.
The model named by the client does not override the router's configured steps.
Also check the provider account and reasoning settings: different accounts,
fallbacks or model overrides prevent a controlled proxy-only comparison.

From the repository root, preview the test without sending requests:

```bash
node scripts/codex_compare.mjs --model YOUR_MODEL \
  --base-url https://api.dodorouter.com/r/YOUR_ROUTER/v1 --dry-run
```

Set `DODO_API_KEY_CODEX` securely in your environment, then omit `--dry-run` to
run. Use `--key-env DODO_API_KEY` for a different variable name. If your key is
loaded by direnv, prefix the command with `direnv exec .`.

The default is two pairs of four-turn sessions (16 CLI turns), with alternating
path order and the same synthetic catalog questions. Sessions are resumed to
exercise growing prefixes. The runner does not override Codex's reasoning
effort; Codex may still send its own model default, which provider-default
routing preserves. Check outbound reasoning settings when comparing runs.
Each answer has an exact correctness check. Results
and raw CLI events are saved in a printed temporary directory; synthetic session
history is also stored by Codex so it can resume. Each CLI turn has a two-minute
timeout, and the probe stops on a failed or incorrect turn. Codex may internally
retry requests, so 16 CLI turns is not an upstream-request or spending cap.

Codex's JSONL `turn.completed.usage` can represent cumulative session totals
on resumed custom-provider sessions. Do not sum those totals as per-turn usage.
For per-turn comparisons, use `last_token_usage` from the corresponding saved
Codex session's `token_count` events, and cross-check Dodo's request logs.
Compare `cached_input_tokens / input_tokens`, correctness and
`elapsed_ms`, separating initial turns from follow-ups. Initial turns are not
guaranteed cache-cold; elapsed time includes CLI startup and is not time to first
token or isolated proxy overhead. The direct default transport may differ from
the proxy's Responses SSE transport. Check Dodo MCP `list_logs` / `get_log` for
the actual model, failures, cache evidence and available account identity.
This small probe tests transport and caching, not general coding quality or
statistically established performance parity.

If Codex reports `stream closed before response.completed`, inspect the Dodo
log before retrying: an upstream request rejection can appear as a stream
failure. For example, a configured provider that rejects the `developer` role
cannot serve that Codex request. A successful historical smoke test does not
guarantee compatibility with every current client/provider combination.
