// Serves switch.mandalsuraj.com from the Railway container. The custom domain
// gives the Worker its DNS record and certificate; the Railway service stays
// the only place the site lives.
const ORIGIN = 'https://switch-site-production-1191.up.railway.app';

// The zone's browser cache TTL would stretch the page to 4 hours, so the
// Worker sets the same lifetimes as sws.toml.
function lifetime(path) {
  if (path.startsWith('/vendor/')) return 'public, max-age=31536000, immutable';
  if (path.startsWith('/assets/')) return 'public, max-age=604800';
  return 'public, max-age=300, must-revalidate';
}

export default {
  async fetch(request) {
    const url = new URL(request.url);
    const cache = lifetime(url.pathname);
    const ttl = Number(cache.match(/max-age=(\d+)/)[1]);
    const upstream = await fetch(new Request(ORIGIN + url.pathname + url.search, request), {
      cf: { cacheEverything: true, cacheTtl: ttl },
    });
    const response = new Response(upstream.body, upstream);
    if (upstream.ok) response.headers.set('Cache-Control', cache);
    return response;
  },
};
