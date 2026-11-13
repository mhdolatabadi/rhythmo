{{flutter_js}}
{{flutter_build_config}}

// Flutter's own service worker only unregisters itself now, so it is not
// registered; rhythmo's offline worker keeps the app openable offline.
//
// CanvasKit, the biggest download, is fetched from a path named after the
// engine build, so browsers and the offline worker may keep it for good
// without ever running a stale one after an upgrade; deploy/nginx.conf maps
// the path back to canvaskit/ (#376).
var rhythmoEngine = (_flutter.buildConfig || {}).engineRevision;
_flutter.loader.load({
  config: {
    canvasKitBaseUrl: rhythmoEngine ? 'canvaskit-' + rhythmoEngine + '/' : 'canvaskit/',
  },
});

(function () {
  if (!('serviceWorker' in navigator)) return;
  // Files fetched before the worker took over: hand their addresses to it
  // so the very first visit is enough to open the app offline later.
  function rememberLoadedFiles(worker) {
    if (!worker) return;
    var urls = performance.getEntriesByType('resource').map(function (entry) {
      return entry.name;
    });
    urls.push(location.href);
    worker.postMessage({ type: 'keep', urls: urls });
  }
  window.addEventListener('load', function () {
    navigator.serviceWorker
      .register('offline_worker.js')
      .then(function () { return navigator.serviceWorker.ready; })
      .then(function (registration) {
        // Again after the first frame, when fonts and CanvasKit are in.
        rememberLoadedFiles(registration.active);
        window.addEventListener('flutter-first-frame', function () {
          setTimeout(function () { rememberLoadedFiles(registration.active); }, 3000);
        }, { once: true });
      })
      .catch(function (error) {
        console.warn('Offline worker not registered:', error);
      });
  });
})();
