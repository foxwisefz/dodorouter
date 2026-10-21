import { test } from "node:test"
import assert from "node:assert/strict"

import { LocalTime } from "../local_time.js"

function timeElement(utc, format = "time") {
  const attributes = new Map()
  return {
    dataset: {utc, format, fallback: "2026-10-21 20:15:30 UTC"},
    textContent: "2026-10-21 20:15:30 UTC",
    dateTime: utc,
    title: "",
    setAttribute(name, value) { attributes.set(name, value) },
    getAttribute(name) { return attributes.get(name) ?? null },
    removeAttribute(name) { attributes.delete(name) },
  }
}

function inTimezone(t, timezone, run) {
  const originalTimezone = process.env.TZ
  process.env.TZ = timezone

  // Keep the browser locale deterministic while exercising real Intl timezone rules.
  const DateTimeFormat = Intl.DateTimeFormat
  t.mock.method(Intl, "DateTimeFormat", function(_locale, options) {
    return new DateTimeFormat("en-GB", options)
  })

  try {
    run()
  } finally {
    t.mock.restoreAll()
    if (originalTimezone === undefined) delete process.env.TZ
    else process.env.TZ = originalTimezone
  }
}

test("mounted uses the browser timezone and handles Dubai midnight rollover", t => {
  inTimezone(t, "Asia/Dubai", () => {
    const el = timeElement("2026-10-21T20:15:30Z")
    LocalTime.mounted.call({el})

    assert.equal(el.textContent, "00:15:30")
    assert.match(el.title, /22 Oct 2026/)
    assert.match(el.title, /00:15:30/)
    assert.match(el.title, /Asia\/Dubai/)
    assert.equal(el.getAttribute("aria-label"), el.title)
    assert.equal(el.dateTime, "2026-10-21T20:15:30Z")
  })
})

test("negative offsets show the previous local date", t => {
  inTimezone(t, "America/Los_Angeles", () => {
    const el = timeElement("2026-10-21T02:15:30Z", "datetime")
    LocalTime.mounted.call({el})

    assert.match(el.textContent, /20 Oct 2026/)
    assert.match(el.textContent, /19:15:30/)
    assert.match(el.title, /America\/Los_Angeles/)
  })
})

test("DST changes use each timestamp's offset", t => {
  inTimezone(t, "America/New_York", () => {
    const el = timeElement("2026-03-08T06:59:59Z")
    const hook = {el}
    LocalTime.mounted.call(hook)
    assert.equal(el.textContent, "01:59:59")

    el.dataset.utc = "2026-03-08T07:00:00Z"
    LocalTime.updated.call(hook)
    assert.equal(el.textContent, "03:00:00")
    assert.equal(el.dateTime, "2026-03-08T07:00:00Z")
  })
})

test("updated reads the latest data attributes on an ignored LiveView element", t => {
  inTimezone(t, "Asia/Dubai", () => {
    const el = timeElement("2026-10-21T20:15:30Z")
    const hook = {el}
    LocalTime.mounted.call(hook)

    // phx-update=ignore merges data attributes but preserves ordinary attributes.
    el.dataset.utc = "2026-10-22T03:45:59.123456Z"
    el.dataset.format = "datetime"
    LocalTime.updated.call(hook)

    assert.match(el.textContent, /22 Oct 2026/)
    assert.match(el.textContent, /07:45:59/)
    assert.equal(el.dateTime, "2026-10-22T03:45:59.123456Z")
    assert.match(el.title, /07:45:59/)
    assert.equal(el.getAttribute("aria-label"), el.title)
  })
})

test("invalid or missing timestamps retain the server fallback", () => {
  for (const utc of ["invalid", "", undefined]) {
    const el = timeElement(utc)
    assert.doesNotThrow(() => LocalTime.mounted.call({el}))
    assert.equal(el.textContent, el.dataset.fallback)
  }
})

test("an invalid update restores fallback text and clears stale local metadata", t => {
  inTimezone(t, "Asia/Dubai", () => {
    const el = timeElement("2026-10-21T20:15:30Z")
    const hook = {el}
    LocalTime.mounted.call(hook)

    el.dataset.utc = "invalid"
    el.dataset.fallback = "Unavailable"
    LocalTime.updated.call(hook)

    assert.equal(el.textContent, "Unavailable")
    assert.equal(el.title, "")
    assert.equal(el.dateTime, "")
    assert.equal(el.getAttribute("aria-label"), null)
  })
})
