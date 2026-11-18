// hushface.com — serves the release artifacts out of R2.
//
//   /                                   landing page with the one-line command
//   /install.sh                         → latest/install.sh
//   /hushface-macos-arm64.sh            → latest/hushface-macos-arm64.sh
//   /hushface-macos-arm64.sh.sha256     → latest/…
//   /releases/latest/<file>             → latest/<file>
//   /releases/v<version>/<file>         → v<version>/<file>
//
// Range requests are honoured, so rsync/curl -C - and the app's own downloader
// work against it. Deploy: see cloudflare/README.md.

const LATEST_ALIASES = new Set(["install.sh", "hushface-macos-arm64.sh", "hushface-macos-arm64.sh.sha256"]);

function keyFor(pathname) {
  const p = pathname.replace(/\/{2,}/g, "/");
  if (p === "/" || p === "/index.html") return "LANDING";
  const name = p.replace(/^\//, "");
  if (LATEST_ALIASES.has(name)) return `latest/${name}`;
  const m = /^\/releases\/(latest|v[0-9][^/]*)\/([A-Za-z0-9._-]+)$/.exec(p);
  if (m) return `${m[1]}/${m[2]}`;
  return null;
}

function contentType(name) {
  if (name.endsWith(".sha256")) return "text/plain; charset=utf-8";
  if (name.endsWith(".sh")) return "text/x-shellscript; charset=utf-8";
  return "application/octet-stream";
}

function notFound() {
  return new Response("not found\n", {
    status: 404,
    headers: { "content-type": "text/plain; charset=utf-8" },
  });
}

function landing() {
  const html = `<!doctype html>
<meta charset="utf-8">
<title>hushface</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
  :root { color-scheme: light dark }
  body { font: 16px/1.6 ui-monospace, SFMono-Regular, Menlo, monospace; max-width: 44rem; margin: 12vh auto; padding: 0 1.5rem }
  h1 { font-size: 1.6rem; letter-spacing: .02em }
  pre { background: rgba(127,127,127,.14); padding: 1rem; border-radius: .5rem; overflow-x: auto }
  p, li { opacity: .85 }
  code { opacity: 1 }
</style>
<h1>hushface</h1>
<p>A coding agent that runs entirely on your Mac: <b>pi</b> + <b>Qwen3.8-27B</b>
with the pi LoRA adapter, llama.cpp underneath.</p>
<pre>curl -LsSf https://hushface.com/install.sh | sh</pre>
<p>One 73&nbsp;MB file brings its own runtime (Node, pi, llama.cpp). No Homebrew,
no Node, no Xcode tools. The 22&nbsp;GB of weights download on first run, from
ModelScope or Hugging Face — your choice.</p>
<ul>
  <li><a href="/hushface-macos-arm64.sh">hushface-macos-arm64.sh</a></li>
  <li><a href="/hushface-macos-arm64.sh.sha256">checksum</a></li>
  <li><a href="https://github.com/timqian/hushface">source</a></li>
</ul>
<p>Apple Silicon, macOS 13+, 32&nbsp;GB RAM recommended.</p>
`;
  return new Response(html, {
    headers: { "content-type": "text/html; charset=utf-8", "cache-control": "public, max-age=300" },
  });
}

function parseRange(header, size) {
  const m = /^bytes=(\d*)-(\d*)$/.exec((header || "").trim());
  if (!m || (m[1] === "" && m[2] === "")) return null;
  let start;
  let end;
  if (m[1] === "") {
    // suffix range: last N bytes
    const n = Number(m[2]);
    start = Math.max(0, size - n);
    end = size - 1;
  } else {
    start = Number(m[1]);
    end = m[2] === "" ? size - 1 : Math.min(Number(m[2]), size - 1);
  }
  if (start > end || start >= size) return null;
  return { start, end };
}

function misconfigured(what) {
  console.error(`hushface worker: ${what}`);
  return new Response(
    `hushface.com is misconfigured: ${what}\n\n` +
      "The worker is reachable, so DNS and the route are fine. Fix the deployment:\n" +
      "  cd cloudflare && npx wrangler deploy\n" +
      "  npx wrangler r2 bucket create hushface-releases   (if the bucket is missing)\n",
    { status: 503, headers: { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" } },
  );
}

export default {
  async fetch(request, env) {
    // Never let an exception escape: an uncaught throw becomes an opaque
    // "502 / Error 1101" page with no clue about what broke.
    try {
      return await handle(request, env);
    } catch (e) {
      console.error("hushface worker: unhandled", e && e.stack ? e.stack : e);
      return new Response(
        `hushface.com: the worker hit an error.\n\n${e && e.message ? e.message : e}\n\n` +
          "Run `npx wrangler tail` while reloading this URL for the stack trace.\n",
        { status: 500, headers: { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" } },
      );
    }
  },
};

async function handle(request, env) {
  if (!env || !env.RELEASES) {
    return misconfigured("the R2 binding RELEASES is not attached to this worker");
  }

  const url = new URL(request.url);
  if (request.method !== "GET" && request.method !== "HEAD") {
    return new Response("method not allowed\n", { status: 405 });
  }

  const key = keyFor(url.pathname);
  if (key === "LANDING") return landing();
  if (!key) return notFound();

  const headers = new Headers({
    "content-type": contentType(key),
    "accept-ranges": "bytes",
    "cache-control": key.startsWith("latest/")
      ? "public, max-age=300"
      : "public, max-age=31536000, immutable",
  });

  const rangeHeader = request.headers.get("range");
  if (rangeHeader) {
    const head = await env.RELEASES.head(key);
    if (!head) return notFound();
    const range = parseRange(rangeHeader, head.size);
    if (!range) {
      return new Response("range not satisfiable\n", {
        status: 416,
        headers: { "content-range": `bytes */${head.size}` },
      });
    }
    const obj = await env.RELEASES.get(key, {
      range: { offset: range.start, length: range.end - range.start + 1 },
    });
    if (!obj) return notFound();
    headers.set("content-range", `bytes ${range.start}-${range.end}/${head.size}`);
    headers.set("content-length", String(range.end - range.start + 1));
    headers.set("etag", obj.httpEtag);
    return new Response(request.method === "HEAD" ? null : obj.body, { status: 206, headers });
  }

  const obj = await env.RELEASES.get(key);
  if (!obj) return notFound();
  headers.set("content-length", String(obj.size));
  headers.set("etag", obj.httpEtag);
  return new Response(request.method === "HEAD" ? null : obj.body, { status: 200, headers });
}
