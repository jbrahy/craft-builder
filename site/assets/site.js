// Show the visitor's own platform first, and stagger the proof strip tiles.
(function () {
  var ua = navigator.userAgent;
  var os = /Windows/.test(ua) ? "windows" : /Mac OS X|Macintosh/.test(ua) ? "macos" : /Linux|X11/.test(ua) && !/Android/.test(ua) ? "linux" : null;
  var names = { windows: "Windows", macos: "macOS", linux: "Linux" };

  document.querySelectorAll(".tile").forEach(function (t, i) { t.style.setProperty("--i", i); });

  if (!os) return;
  var lists = document.querySelectorAll(".dls");
  var any = false;
  lists.forEach(function (l) {
    var mine = l.querySelector('.dl[data-platform="' + os + '"]');
    if (mine && mine.querySelector(".file")) { mine.classList.add("yours"); l.classList.add("mine"); any = true; }
  });
  var note = document.querySelector(".platform-note");
  if (!any || !note) return;
  note.querySelector("[data-os-name]").textContent = names[os];
  note.hidden = false;
  note.querySelector("[data-show-all]").addEventListener("click", function () {
    lists.forEach(function (l) { l.classList.remove("mine"); });
    note.hidden = true;
  });
})();
