# JS logic tests

Decision logic from LiveView hooks is tested here with Node's built-in test
runner — no jest/vitest/jsdom or bundler dependency. Local-time tests exercise
the mounted/updated callbacks with a minimal element fixture and real Intl
timezone rules, including date rollover and daylight saving changes.

Run:

```bash
node --test assets/js/test/*.test.mjs
```

Requires Node with `node:test` built in (Node 18.8+; this repo has been
verified against Node 26). Server-rendered hook wiring stays covered by
the existing LiveView tests under `test/`.
