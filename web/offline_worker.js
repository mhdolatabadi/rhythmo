'use strict';

// Keeps the rhythmo web app openable without a connection. Only the app's
// own files under its scope (/app/) are kept: the API, audio and covers
// live outside it and are never touched here. Every request tries the
// network first, so an online visit always gets the latest deploy; the
// kept copy is used only when the network fails or takes too long.

const CACHE = 'rhythmo-app-v1';
const NETWORK_TIMEOUT_MS = 4000;
const SCOPE = new URL(self.registration.scope);

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE).then((cache) => cache.add(SCOPE.href)).catch(() => {}),
  );
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    (async () => {
      for (const name of await caches.keys()) {
        if (name !== CACHE && name.startsWith('rhythmo-app-')) {
          await caches.delete(name);
        }
      }
      await self.clients.claim();
    })(),
  );
});

function isAppFile(url) {
  return (
    url.origin === SCOPE.origin &&
    url.pathname.startsWith(SCOPE.pathname) &&
    !url.pathname.endsWith('/offline_worker.js') &&
    !url.pathname.endsWith('/flutter_service_worker.js')
  );
}

// Pages of the app share one entry: its start page, with any query.
function keyFor(request) {
  return request.mode === 'navigate' ? SCOPE.href : request.url;
}

async function keep(key, response) {
  if (!response || !response.ok || response.type !== 'basic') return;
  const cache = await caches.open(CACHE);
  await cache.put(key, response);
}

// CanvasKit under its engine build's path never changes (#376): served from
// the kept copy, a repeat visit skips the app's biggest download entirely.
const IMMUTABLE = /\/canvaskit-[0-9a-f]+\//;

function isImmutable(url) {
  return IMMUTABLE.test(url.pathname.slice(SCOPE.pathname.length - 1));
}

async function cacheFirst(event) {
  const request = event.request;
  const kept = await caches.match(request.url);
  if (kept) return kept;
  const response = await fetch(request);
  event.waitUntil(
    (async () => {
      await keep(request.url, response.clone());
      // A new engine build replaces the old CanvasKit, about 7 MB.
      const engine = /\/canvaskit-([0-9a-f]+)\//.exec(request.url);
      if (!engine) return;
      const cache = await caches.open(CACHE);
      for (const old of await cache.keys()) {
        const other = /\/canvaskit-([0-9a-f]+)\//.exec(old.url);
        if (other && other[1] !== engine[1]) await cache.delete(old);
      }
    })().catch(() => {}),
  );
  return response;
}

async function networkFirst(event) {
  const request = event.request;
  const key = keyFor(request);
  const network = fetch(request).then((response) => {
    event.waitUntil(keep(key, response.clone()).catch(() => {}));
    return response;
  });
  const kept = caches.match(key);
  // A slow network loses to the kept copy, but still refreshes it.
  const timeout = new Promise((resolve) =>
    setTimeout(resolve, NETWORK_TIMEOUT_MS),
  ).then(() => kept);
  try {
    const first = await Promise.race([network, timeout]);
    if (first) return first;
    return await network;
  } catch (error) {
    const fallback = await kept;
    if (fallback) return fallback;
    throw error;
  }
}

self.addEventListener('fetch', (event) => {
  const request = event.request;
  if (request.method !== 'GET' || request.headers.has('range')) return;
  const url = new URL(request.url);
  if (!isAppFile(url)) return;
  event.respondWith(isImmutable(url) ? cacheFirst(event) : networkFirst(event));
});

// The page lists files it loaded before this worker controlled it.
self.addEventListener('message', (event) => {
  const data = event.data;
  if (!data || data.type !== 'keep' || !Array.isArray(data.urls)) return;
  event.waitUntil(
    (async () => {
      const cache = await caches.open(CACHE);
      for (const href of data.urls) {
        let url;
        try {
          url = new URL(href);
        } catch (_) {
          continue;
        }
        if (!isAppFile(url)) continue;
        const key = url.pathname === SCOPE.pathname ? SCOPE.href : url.href;
        if (await cache.match(key)) continue;
        try {
          await keep(key, await fetch(url.href, { credentials: 'same-origin' }));
        } catch (_) {
          // Offline right now; the next visit keeps it.
        }
      }
    })(),
  );
});
