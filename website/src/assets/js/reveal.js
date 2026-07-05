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
})();
