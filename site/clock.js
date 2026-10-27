// The only script on the page: keeps the demo menu bar's clock on the visitor's
// local time, the way macOS shows it (weekday and time, in their own locale's
// 12- or 24-hour format). Nothing is sent anywhere.
(function () {
  var el = document.querySelector(".clock");
  if (!el) return;
  var fmt = new Intl.DateTimeFormat(undefined, { weekday: "short", hour: "numeric", minute: "2-digit" });
  var timer;

  function tick() {
    var now = new Date();
    el.textContent = fmt.format(now).replace(",", "");
    el.setAttribute("datetime", now.toISOString());
    el.hidden = false;
    clearTimeout(timer);
    // wake on the next minute boundary rather than polling
    timer = setTimeout(tick, 60000 - (now.getSeconds() * 1000 + now.getMilliseconds()) + 50);
  }

  tick();
  // timers are throttled in background tabs; catch up when the tab returns
  document.addEventListener("visibilitychange", function () {
    if (!document.hidden) tick();
  });
})();
