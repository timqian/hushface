#!/usr/bin/env node
// Model hub metadata: ModelScope, Hugging Face, llama.cpp releases.
//
//   node hub.mjs resolve --source modelscope|hf --repo O/R --file PATH [--token T]
//        -> url<TAB>size<TAB>sha256     (on missing file: exit 1, message on stderr)
//   node hub.mjs llama-release
//        -> url of the latest llama.cpp macOS arm64 zip
//   node hub.mjs verify --file PATH --sha256 HEX [--label NAME]

import path from "node:path";

const UA = "hushface/0.1";
const MS_API = (repo) => `https://modelscope.cn/api/v1/models/${repo}/repo/files?Revision=master&Recursive=true`;
const HF_API = (repo) => `https://huggingface.co/api/models/${repo}?blobs=true`;

async function getJson(url, token) {
  const headers = { "user-agent": UA };
  if (token) headers.authorization = `Bearer ${token}`;
  const res = await fetch(url, { headers, redirect: "follow" });
  if (!res.ok) throw new Error(`HTTP ${res.status} for ${url}`);
  return res.json();
}

async function modelscope(repo, file, token) {
  const data = await getJson(MS_API(repo), token);
  const files = data?.Data?.Files ?? [];
  const hit = files.find((f) => f.Path === file || f.Name === file);
  if (!hit) return null;
  return {
    url: `https://modelscope.cn/models/${repo}/resolve/master/${file}`,
    size: hit.Size || 0,
    sha256: (hit.Sha256 || "").trim(),
  };
}

async function hf(repo, file, token) {
  const data = await getJson(HF_API(repo), token);
  const hit = (data.siblings ?? []).find((f) => f.rfilename === file);
  if (!hit) return null;
  const lfs = hit.lfs || {};
  return {
    url: `https://huggingface.co/${repo}/resolve/main/${file}`,
    size: hit.size || lfs.size || 0,
    sha256: (lfs.oid || "").trim(),
  };
}

function parseArgs(argv) {
  const out = { _: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a.startsWith("--")) out[a.slice(2)] = argv[++i];
    else out._.push(a);
  }
  return out;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const cmd = args._[0];

  if (cmd === "resolve") {
    const { source, repo, file, token } = args;
    if (!source || !repo || !file) {
      process.stderr.write("usage: hub.mjs resolve --source modelscope|hf --repo O/R --file PATH\n");
      return 2;
    }
    const hit = source === "modelscope" ? await modelscope(repo, file, token) : await hf(repo, file, token);
    if (!hit) {
      process.stderr.write(`not found: ${repo}/${file} on ${source}\n`);
      return 1;
    }
    process.stdout.write(`${hit.url}\t${hit.size}\t${hit.sha256}\n`);
    return 0;
  }

  if (cmd === "llama-release") {
    // llama.cpp ships one release per build tag (b12xxx); assets are tarballs
    const releases = await getJson("https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=30");
    for (const rel of releases) {
      const asset = (rel.assets ?? []).find(
        (x) => /macos/i.test(x.name) && /arm64/i.test(x.name) && /\.(tar\.gz|zip)$/.test(x.name),
      );
      if (asset) {
        process.stdout.write(`${asset.browser_download_url}\n`);
        return 0;
      }
    }
    process.stderr.write("no macos-arm64 asset in recent llama.cpp releases\n");
    return 1;
  }

  if (cmd === "verify") {
    const { file, sha256, label } = args;
    const { stat } = await import("node:fs/promises");
    try {
      await stat(file);
    } catch {
      process.stderr.write(`${label || path.basename(file)} is missing\n`);
      return 1;
    }
    if (!sha256) return 0;
    const { createHash } = await import("node:crypto");
    const { createReadStream } = await import("node:fs");
    const hash = createHash("sha256");
    for await (const buf of createReadStream(file, { highWaterMark: 8 * 1024 * 1024 })) hash.update(buf);
    const got = hash.digest("hex");
    if (got !== sha256.toLowerCase()) {
      process.stderr.write(`${label || path.basename(file)} is corrupt\n`);
      return 1;
    }
    process.stderr.write(`✓ ${label || path.basename(file)} verified\n`);
    return 0;
  }

  process.stderr.write("usage: hub.mjs resolve|llama-release|verify\n");
  return 2;
}

main()
  .then((c) => process.exit(c ?? 0))
  .catch((e) => {
    process.stderr.write(`${e.message}\n`);
    process.exit(1);
  });
