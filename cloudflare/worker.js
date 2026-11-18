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
  const repo = "https://github.com/timqian/hushface";
  const html = `<!doctype html>
<html lang="en">
<meta charset="utf-8">
<title>hushface — a coding agent that runs on your Mac</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="description" content="hushface: pi + Qwen3.8-27B with the pi LoRA adapter, local, one command.">
<style>
  :root { color-scheme: light dark; --fg:#111; --bg:#fff; --dim:#666; --line:#e5e5e5; --code:rgba(127,127,127,.13) }
  @media (prefers-color-scheme: dark) { :root { --fg:#e8e8e8; --bg:#111; --dim:#9a9a9a; --line:#2a2a2a } }
  * { box-sizing: border-box }
  body { margin:0; background:var(--bg); color:var(--fg);
         font:16px/1.65 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace }
  main { max-width: 46rem; margin: 0 auto; padding: 9vh 1.5rem 4rem }
  header { display:flex; align-items:baseline; justify-content:space-between; gap:1rem;
           padding-bottom:.9rem; border-bottom:1px solid var(--line); margin-bottom:2.2rem }
  .brand { font-weight:600; letter-spacing:.04em }
  .brand span { color:var(--dim) }
  a { color:inherit; text-underline-offset:.18em; text-decoration-color:var(--dim) }
  a:hover { text-decoration-color:currentColor }
  header a { font-size:.85rem; color:var(--dim); text-decoration:none }
  header a:hover { color:var(--fg) }
  h1 { font-size:1.35rem; line-height:1.4; margin:0 0 1rem; font-weight:600 }
  p { margin:.6rem 0; color:var(--dim) }
  p strong { color:var(--fg); font-weight:600 }
  pre { background:var(--code); padding:.9rem 1rem; border-radius:.4rem; overflow-x:auto;
        margin:1.6rem 0; color:var(--fg) }
  pre .d { color:var(--dim) }
  ul { padding-left:1.1rem; color:var(--dim); margin:1.6rem 0 0 }
  li { margin:.35rem 0 }
  footer { margin-top:2.6rem; padding-top:1rem; border-top:1px solid var(--line);
           font-size:.85rem; color:var(--dim); display:flex; gap:1.1rem; flex-wrap:wrap }
</style>
<main>
  <header>
    <div class="brand">hushface <span>/ local coding agent</span></div>
    <a href="${repo}">GitHub ↗</a>
  </header>

  <h1>An agent that runs entirely on your Mac.</h1>
  <p><strong>pi</strong> driving <strong>Qwen3.8-27B</strong> with the pi LoRA
     adapter, on llama.cpp. 27B parameters, no API key, no cloud, works offline
     once installed.</p>

  <pre>curl -LsSf https://hushface.com/install.sh | sh</pre>

  <p>That single command is the whole install. It pulls a 73&nbsp;MB file that
     carries its own runtime — Node, pi, llama.cpp — so there is no Homebrew, no
     npm, no Xcode tools to install first. The 22&nbsp;GB of weights come down on
     first run, resumably and checksum-verified, from
     <strong>ModelScope</strong> or <strong>Hugging Face</strong> — your pick.</p>

  <ul>
    <li>Apple Silicon (M1 or newer), macOS 13+</li>
    <li>32&nbsp;GB RAM recommended, 18&nbsp;GB free disk for the model</li>
    <li>runs offline after the first download</li>
  </ul>

  <footer>
    <a href="${repo}">github.com/timqian/hushface</a>
    <a href="/hushface-macos-arm64.sh">download the file</a>
    <a href="/hushface-macos-arm64.sh.sha256">checksum</a>
  </footer>
</main>
</html>
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
