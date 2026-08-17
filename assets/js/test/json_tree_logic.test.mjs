// Run with: node --test assets/js/test/
// See assets/js/test/README.md.

import { test } from "node:test"
import assert from "node:assert/strict"

import {
  COLLAPSED_STRING,
  EXPAND_ALL_LIMIT,
  AUTO_OPEN_CHILDREN,
  truncateString,
  shouldAutoOpen,
  summarizeContainer,
  shouldVisit,
  nextVisitCount,
  parseJsonForTree
} from "../hooks/json_tree_logic.js"

test("truncateString: at the boundary, 159 chars is not truncated", () => {
  const result = truncateString("a".repeat(COLLAPSED_STRING - 1))
  assert.equal(result.truncated, false)
  assert.equal(result.hiddenCount, 0)
  assert.equal(result.label, null)
})

test("truncateString: exactly 160 chars is not truncated", () => {
  const result = truncateString("a".repeat(COLLAPSED_STRING))
  assert.equal(result.truncated, false)
  assert.equal(result.shown, "a".repeat(COLLAPSED_STRING))
})

test("truncateString: 161 chars is truncated with a +1 chars label", () => {
  const text = "a".repeat(COLLAPSED_STRING + 1)
  const result = truncateString(text)
  assert.equal(result.truncated, true)
  assert.equal(result.shown, "a".repeat(COLLAPSED_STRING))
  assert.equal(result.hiddenCount, 1)
  assert.equal(result.label, "+1 chars")
})

test("truncateString: any embedded newline forces truncation even if short", () => {
  const result = truncateString("short\nstring")
  assert.equal(result.truncated, true)
  assert.equal(result.label, `+${"short\nstring".length - COLLAPSED_STRING} chars`)
})

test("truncateString: label reflects large hidden counts", () => {
  const text = "x".repeat(COLLAPSED_STRING + 5000)
  const result = truncateString(text)
  assert.equal(result.hiddenCount, 5000)
  assert.equal(result.label, "+5000 chars")
})

test("shouldAutoOpen: 24 children auto-opens", () => {
  assert.equal(shouldAutoOpen(24), true)
})

test("shouldAutoOpen: exactly 25 children (the threshold) auto-opens", () => {
  assert.equal(AUTO_OPEN_CHILDREN, 25)
  assert.equal(shouldAutoOpen(25), true)
})

test("shouldAutoOpen: 26 children does not auto-open", () => {
  assert.equal(shouldAutoOpen(26), false)
})

test("summarizeContainer: singular vs plural nouns for arrays and objects", () => {
  assert.equal(summarizeContainer(true, 1), "[ 1 item ]")
  assert.equal(summarizeContainer(true, 2), "[ 2 items ]")
  assert.equal(summarizeContainer(false, 1), "{ 1 key }")
  assert.equal(summarizeContainer(false, 2), "{ 2 keys }")
})

test("expand-all cap: processes exactly EXPAND_ALL_LIMIT + 1 nodes then stops", () => {
  assert.equal(EXPAND_ALL_LIMIT, 4000)

  let visited = 0
  let processed = 0

  for (let i = 0; i < EXPAND_ALL_LIMIT + 10; i++) {
    const proceed = shouldVisit(visited)
    visited = nextVisitCount(visited)
    if (!proceed) continue
    processed++
  }

  // Pre-increment compare against a 0-based counter processes one more node
  // than the raw limit — this is the existing behavior, preserved exactly.
  assert.equal(processed, EXPAND_ALL_LIMIT + 1)
})

test("expand-all cap: the node at the boundary is still visited, the next is not", () => {
  // After EXPAND_ALL_LIMIT prior visits (pre-increment value == LIMIT),
  // the walk still processes this node...
  assert.equal(shouldVisit(EXPAND_ALL_LIMIT), true)
  // ...but the one after that (pre-increment value == LIMIT + 1) is skipped.
  assert.equal(shouldVisit(EXPAND_ALL_LIMIT + 1), false)
})

test("parseJsonForTree: valid JSON object is a container", () => {
  const result = parseJsonForTree('{"a": 1}')
  assert.equal(result.ok, true)
  assert.deepEqual(result.value, { a: 1 })
})

test("parseJsonForTree: valid JSON array is a container", () => {
  const result = parseJsonForTree("[1, 2, 3]")
  assert.equal(result.ok, true)
  assert.deepEqual(result.value, [1, 2, 3])
})

test("parseJsonForTree: invalid JSON falls back", () => {
  const result = parseJsonForTree("not json at all")
  assert.equal(result.ok, false)
  assert.equal(result.value, undefined)
})

test("parseJsonForTree: valid JSON scalar (not a container) also falls back", () => {
  const result = parseJsonForTree('"just a string"')
  assert.equal(result.ok, false)
})

test("parseJsonForTree: null parses but is not a container", () => {
  const result = parseJsonForTree("null")
  assert.equal(result.ok, false)
})
