/* -------------------------------------------------------------
   dairy note - PWA Service Worker
   App shell caching for instant loading and installability.
   CRITICAL: Supabase API calls are strictly network-only
   to ensure real-time database synchronization with zero stale
   data or offline caching.
------------------------------------------------------------- */

const CACHE_NAME = "dairy-note-v12";
const APP_SHELL = [
  "./",
  "./index.html",
  "./manifest.json",
  "./icons/icon-192.png",
  "./icons/icon-512.png",
  "./icons/apple-touch-icon.png",
  "./icons/favicon-32.png",
  "./icons/icon.svg"
];

// Install event - Cache static application shell
self.addEventListener("install", event => {
  event.waitUntil(
    caches.open(CACHE_NAME).then(cache => {
      return cache.addAll(APP_SHELL);
    }).then(() => {
      return self.skipWaiting();
    })
  );
});

// Activate event - Clean up old cache versions
self.addEventListener("activate", event => {
  event.waitUntil(
    caches.keys().then(cacheNames => {
      return Promise.all(
        cacheNames.map(name => {
          if (name !== CACHE_NAME) {
            return caches.delete(name);
          }
        })
      );
    }).then(() => {
      return self.clients.claim();
    })
  );
});

// Fetch event - Network-only for Supabase API, Network-First for HTML/navigation, Stale-While-Revalidate for static assets
self.addEventListener("fetch", event => {
  const reqUrl = new URL(event.request.url);

  // 1. Supabase database & auth endpoints: STRICTLY NETWORK ONLY (No cache)
  if (
    reqUrl.hostname.includes("supabase.co") ||
    reqUrl.hostname.includes("supabase.in") ||
    reqUrl.pathname.includes("/rest/v1/") ||
    reqUrl.pathname.includes("/auth/v1/") ||
    event.request.method !== "GET"
  ) {
    event.respondWith(
      fetch(event.request).catch(err => {
        return new Response(
          JSON.stringify({
            error: "Network unavailable. Please check your internet connection to sync with the database."
          }),
          {
            headers: { "Content-Type": "application/json; charset=utf-8" },
            status: 503
          }
        );
      })
    );
    return;
  }

  // 2. HTML navigation requests: Network-First so updates take effect immediately on reload
  const isHtmlReq = event.request.mode === "navigate" ||
    (event.request.headers.get("accept") && event.request.headers.get("accept").includes("text/html")) ||
    reqUrl.pathname.endsWith("/index.html") ||
    reqUrl.pathname.endsWith("/");

  if (isHtmlReq) {
    event.respondWith(
      fetch(event.request).then(networkResponse => {
        if (networkResponse && networkResponse.status === 200) {
          const resClone = networkResponse.clone();
          caches.open(CACHE_NAME).then(cache => cache.put(event.request, resClone));
        }
        return networkResponse;
      }).catch(() => {
        return caches.match(event.request).then(cached => cached || caches.match("./index.html"));
      })
    );
    return;
  }

  // 3. Static Assets: Cache-First with background revalidation
  event.respondWith(
    caches.match(event.request).then(cachedResponse => {
      const fetchPromise = fetch(event.request).then(networkResponse => {
        if (networkResponse && networkResponse.status === 200) {
          const responseToCache = networkResponse.clone();
          caches.open(CACHE_NAME).then(cache => {
            cache.put(event.request, responseToCache);
          });
        }
        return networkResponse;
      }).catch(() => cachedResponse);

      return cachedResponse || fetchPromise;
    })
  );
});
