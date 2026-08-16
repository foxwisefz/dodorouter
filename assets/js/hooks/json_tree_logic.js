// Pure decision logic extracted from assets/js/json_tree.js so it can be
// tested with Node's built-in test runner, with no DOM and no bundler. The
// hook imports these and stays the only place that touches the DOM — see
// assets/js/test/README.md for how to run the tests.

export const COLLAPSED_STRING = 160
export const EXPAND_ALL_LIMIT = 4000
export const AUTO_OPEN_CHILDREN = 25

// Decides whether a string value needs a "+N chars" toggle, and computes the
// preview/hidden-count pair the toggle button and truncated span are built
// from. A string with an embedded newline is always truncated, even if short,
// because an untruncated multi-line string breaks the one-row-per-node layout.
export function truncateString(text) {
  const str = String(text)
  if (str.length <= COLLAPSED_STRING && !str.includes("\n")) {
    return { truncated: false, shown: str, hiddenCount: 0, label: null }
  }

  const shown = str.slice(0, COLLAPSED_STRING)
  const hiddenCount = str.length - COLLAPSED_STRING
  return { truncated: true, shown, hiddenCount, label: `+${hiddenCount} chars` }
}

// Top level opens by default so the shape of the request is visible without a
// click — unless it is a long array/object, where opening it just renders a
// wall of collapsed rows instead of showing shape.
export function shouldAutoOpen(childCount) {
  return childCount <= AUTO_OPEN_CHILDREN
}

// "{ 4 keys }" / "[ 12 items ]" — a collapsed node still has to say how much
// it is hiding, or collapsing everything just hides the shape of the request.
export function summarizeContainer(isArray, count) {
  const noun = isArray ? (count === 1 ? "item" : "items") : count === 1 ? "key" : "keys"
  const [open, close] = isArray ? ["[", "]"] : ["{", "}"]
  return `${open} ${count} ${noun} ${close}`
}

// toggleAll's cap, kept bit-for-bit equivalent to the original
// `if (visited++ > EXPAND_ALL_LIMIT) return`: the *pre-increment* count is
// compared, so a walk starting at visited=0 processes EXPAND_ALL_LIMIT + 1
// nodes (pre-values 0..4000 inclusive) before skipping the rest. Pulled out
// so the boundary can be asserted without building any DOM.
export function shouldVisit(previousVisitCount) {
  return !(previousVisitCount > EXPAND_ALL_LIMIT)
}

export function nextVisitCount(previousCount) {
  return previousCount + 1
}

// The parse decision: JSON.parse throwing means the source is not JSON at
// all, in which case the server-rendered <pre> fallback stays untouched. A
// value that parses but isn't a container (a bare string/number/etc.) is
// also left as-is — there is no tree to build for a scalar document.
export function parseJsonForTree(source) {
  let value
  try {
    value = JSON.parse(source)
  } catch (_) {
    return { ok: false, value: undefined }
  }

  const isContainer = value !== null && typeof value === "object"
  return { ok: isContainer, value: isContainer ? value : undefined }
}
