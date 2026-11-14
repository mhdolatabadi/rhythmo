// Shows the splash until Flutter's first frame. A file of its own, not an
// inline script, so the Content-Security-Policy needs no 'unsafe-inline' for
// scripts (#218).
(function () {
  var splash = document.getElementById('splash');
  if (!splash) return;
  var slowTimer = setTimeout(function () { splash.classList.add('slow'); }, 20000);
  window.addEventListener('flutter-first-frame', function () {
    clearTimeout(slowTimer);
    splash.classList.add('hidden');
    setTimeout(function () { splash.remove(); }, 300);
  }, { once: true });
})();
