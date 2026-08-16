// Collapsible JSON viewer for the log page's payloads.
//
// A proxied request body is a tree — a messages array of content-part arrays,
// a tools array of JSON-Schema objects — and pretty-printed text made you scroll
// several hundred lines to answer "which model, and did the tools survive?".
//
// Children are built on first expand rather than up front: a coding agent's
// request is routinely megabytes, and rendering every node of one to find the
// four top-level keys is the same waste in DOM that it was in scrollback.
import {
  truncateString,
  shouldAutoOpen,
  summarizeContainer,
  nextVisitCount,
  shouldVisit,
  parseJsonForTree
} from "./hooks/json_tree_logic"

const CLASSES = {
  row: "flex items-start gap-1 rounded px-1 -mx-1 leading-5",
  head: "cursor-pointer hover:bg-base-300/40",
  caret: "shrink-0 select-none text-base-content/40 transition-transform",
  key: "shrink-0 text-base-content/80",
  punct: "text-base-content/30",
  summary: "text-base-content/40",
  string: "text-success break-all whitespace-pre-wrap",
  number: "text-warning",
  boolean: "text-info",
  null: "text-base-content/40",
  more: "ml-1 cursor-pointer rounded bg-base-300/60 px-1 text-[10px] text-base-content/50 hover:text-base-content",
  children: "border-l border-base-300/60 pl-3 ml-[7px]"
}

function el(tag, className, text) {
  const node = document.createElement(tag)
  if (className) node.className = className
  if (text !== undefined) node.textContent = text
  return node
}

function container(value) {
  return value !== null && typeof value === "object"
}

function entries(value) {
  return Array.isArray(value)
    ? value.map((item, index) => [index, item])
    : Object.keys(value).map((key) => [key, value[key]])
}

// "{ 4 keys }" / "[ 12 items ]" — a collapsed node still has to say how much it
// is hiding, or collapsing everything just hides the shape of the request.
function summarize(value) {
  const isArray = Array.isArray(value)
  const count = isArray ? value.length : Object.keys(value).length
  return summarizeContainer(isArray, count)
}

function renderPrimitive(value) {
  if (value === null) return el("span", CLASSES.null, "null")
  if (typeof value === "boolean") return el("span", CLASSES.boolean, String(value))
  if (typeof value === "number") return el("span", CLASSES.number, String(value))

  // Quoted, because this is a fidelity tool: "true" and true are different
  // answers to "did the client send a boolean?", and colour alone is not proof.
  const text = String(value)
  const { truncated, shown, label } = truncateString(text)
  if (!truncated) {
    return el("span", CLASSES.string, `"${text}"`)
  }

  // A system prompt is one of these. It gets a preview and its real length,
  // so a long value never silently costs you the rest of the object.
  const preview = `"${shown}…`
  const wrap = el("span", "min-w-0")
  const body = el("span", CLASSES.string, preview)
  const toggle = el("button", CLASSES.more, label)
  let expanded = false

  toggle.addEventListener("click", (event) => {
    event.stopPropagation()
    expanded = !expanded
    body.textContent = expanded ? `"${text}"` : preview
    toggle.textContent = expanded ? "less" : label
  })

  wrap.appendChild(body)
  wrap.appendChild(toggle)
  return wrap
}

function renderNode(key, value, depth) {
  const node = el("div", "jt-node min-w-0")
  const row = el("div", CLASSES.row)
  node.appendChild(row)

  const label = key === null ? null : el("span", CLASSES.key, typeof key === "number" ? `${key}:` : `${key}:`)

  if (!container(value)) {
    row.appendChild(el("span", CLASSES.punct + " shrink-0 w-3"))
    if (label) row.appendChild(label)
    row.appendChild(renderPrimitive(value))
    return node
  }

  const caret = el("span", CLASSES.caret, "▸")
  const summary = el("span", CLASSES.summary, summarize(value))
  row.classList.add(...CLASSES.head.split(" "))
  row.appendChild(caret)
  if (label) row.appendChild(label)
  row.appendChild(summary)

  const children = el("div", "jt-children " + CLASSES.children)
  children.hidden = true
  node.appendChild(children)

  let built = false
  const setOpen = (open) => {
    if (open && !built) {
      built = true
      for (const [childKey, childValue] of entries(value)) {
        children.appendChild(renderNode(childKey, childValue, depth + 1))
      }
    }
    children.hidden = !open
    caret.style.transform = open ? "rotate(90deg)" : ""
    node.dataset.open = open ? "true" : "false"
  }

  node.__setOpen = setOpen
  row.addEventListener("click", () => setOpen(children.hidden))
  // Top level opens so the shape of the request is visible without a click,
  // unless it is a long array — 300 collapsed message rows is not a shape.
  setOpen(depth === 0 && shouldAutoOpen(entries(value).length))
  return node
}

// Builds as it walks, capped: an "expand all" that unfolds a megabyte of tool
// schemas locks the tab. Each node is opened before its children are queried,
// so newly built subtrees are picked up in the same pass.
function toggleAll(root, open) {
  let visited = 0

  const walk = (node) => {
    const proceed = shouldVisit(visited)
    visited = nextVisitCount(visited)
    if (!proceed) return
    if (node.__setOpen) node.__setOpen(open)
    node.querySelectorAll(":scope > .jt-children > .jt-node").forEach(walk)
  }

  root.querySelectorAll(":scope > .jt-node").forEach(walk)
}

export const JsonTree = {
  mounted() {
    this.render()
  },

  render() {
    // Read from the rendered <pre> rather than a data- attribute: these
    // payloads run to megabytes and there is no reason to ship each one twice.
    const source = this.el.textContent
    const { ok, value: parsed } = parseJsonForTree(source)
    if (!ok) return // not JSON, or not a container: the server-rendered <pre> stays as-is

    // The panel is the root object, so it gets no row of its own: a lone
    // "{ 2 keys }" above the two keys is a line that says nothing.
    const tree = el("div", "font-mono text-[11px]")
    for (const [key, value] of entries(parsed)) {
      tree.appendChild(renderNode(key, value, 0))
    }

    const fallback = this.el.querySelector("[data-json-fallback]")
    if (fallback) fallback.hidden = true
    this.el.appendChild(tree)
    this.tree = tree

    const controls = document.getElementById(this.el.dataset.controls)
    if (!controls) return
    controls.hidden = false

    controls.querySelectorAll("[data-json-action]").forEach((button) => {
      button.addEventListener("click", (event) => {
        event.preventDefault()
        const action = button.dataset.jsonAction
        if (action === "raw") {
          const showingRaw = tree.hidden
          tree.hidden = !showingRaw
          if (fallback) fallback.hidden = showingRaw
          button.textContent = showingRaw ? "raw" : "tree"
        } else {
          toggleAll(tree, action === "expand")
        }
      })
    })
  }
}
