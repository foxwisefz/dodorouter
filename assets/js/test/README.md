# JS logic tests

Pure decision logic extracted from LiveView hooks (no DOM, no bundler) is
tested here with Node's built-in test runner — no jest/vitest/jsdom
dependency for what is currently a single hook's worth of logic.

Run:

```bash
node --test assets/js/test/*.test.mjs
```

Requires Node with `node:test` built in (Node 18+; this repo has been
verified against Node 26). DOM-touching glue in the hooks themselves stays
covered by the existing LiveView wiring tests under `test/`.
