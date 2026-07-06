// Scroll-triggered reveals + animation gating.
// Elements with [data-reveal] get .in-view when they enter the viewport;
// CSS keys entrance animations and loop play-state off that class.
(function () {
  var els = document.querySelectorAll("[data-reveal]");
  if (!("IntersectionObserver" in window)) {
    els.forEach(function (el) { el.classList.add("in-view", "revealed"); });
    return;
  }
  var io = new IntersectionObserver(
    function (entries) {
      entries.forEach(function (entry) {
        // 'revealed' is sticky (entrance styles); 'in-view' toggles so
        // looping scenes pause while off-screen.
        if (entry.isIntersecting) entry.target.classList.add("revealed");
        entry.target.classList.toggle("in-view", entry.isIntersecting);
      });
    },
    { threshold: 0.25 }
  );
  els.forEach(function (el) { io.observe(el); });

  // Count-up tickers: <span data-count-to="12847" data-count-suffix="">
  var tickers = document.querySelectorAll("[data-count-to]");
  var reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var tio = new IntersectionObserver(function (entries) {
    entries.forEach(function (entry) {
      if (!entry.isIntersecting || entry.target.dataset.done) return;
      entry.target.dataset.done = "1";
      var el = entry.target;
      var to = parseFloat(el.dataset.countTo);
      var suffix = el.dataset.countSuffix || "";
      var decimals = (el.dataset.countTo.split(".")[1] || "").length;
      if (reduced) { el.textContent = to.toLocaleString() + suffix; return; }
      var start = null;
      function tick(ts) {
        if (!start) start = ts;
        var p = Math.min((ts - start) / 1600, 1);
        var eased = 1 - Math.pow(1 - p, 3);
        var val = to * eased;
        el.textContent =
          (decimals ? val.toFixed(decimals) : Math.round(val).toLocaleString()) + suffix;
        if (p < 1) requestAnimationFrame(tick);
      }
      requestAnimationFrame(tick);
    });
  }, { threshold: 0.4 });
  tickers.forEach(function (el) { tio.observe(el); });
})();
