const timeOptions = {
  hour: "2-digit",
  minute: "2-digit",
  second: "2-digit",
  hourCycle: "h23",
}

const dateOptions = {year: "numeric", month: "short", day: "numeric"}

function renderLocalTime(el) {
  const utc = el.dataset.utc
  const date = new Date(utc)

  if (!utc || Number.isNaN(date.getTime())) {
    el.textContent = el.dataset.fallback ?? el.textContent
    el.dateTime = ""
    el.title = ""
    el.removeAttribute("aria-label")
    return
  }

  // Omitting timeZone uses the browser's timezone, including the date's DST offset.
  const formatter = new Intl.DateTimeFormat(undefined, {
    ...(el.dataset.format === "datetime" ? dateOptions : {}),
    ...timeOptions,
  })
  const fullFormatter = new Intl.DateTimeFormat(undefined, {
    ...dateOptions,
    ...timeOptions,
    timeZoneName: "short",
  })
  const timezone = fullFormatter.resolvedOptions().timeZone
  const label = `${fullFormatter.format(date)} (${timezone})`

  el.textContent = formatter.format(date)
  // LiveView merges only data attributes on phx-update="ignore" elements.
  el.dateTime = utc
  el.title = label
  el.setAttribute("aria-label", label)
}

export const LocalTime = {
  mounted() {
    renderLocalTime(this.el)
  },
  updated() {
    renderLocalTime(this.el)
  },
}
