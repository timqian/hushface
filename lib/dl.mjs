#!/usr/bin/env node
// Resumable parallel downloader with speed/ETA, checksum verification and
// adoption of sequentially-written partial files.
//
//   node dl.mjs URL DEST [--label NAME] [--jobs N] [--sha256 HEX] [--quiet] [--force]
//   node dl.mjs --verify-only PATH [--sha256 HEX] [--label NAME]
//
// Exit: 0 ok, 1 failed, 2 usage, 130 interrupted.
// State lives in DEST.part.state so an interrupted run resumes per 32 MB chunk.

import { createHash } from "node:crypto";
import { createReadStream } from "node:fs";
import { open, rename, rm, stat, writeFile, appendFile, readFile } from "node:fs/promises";
import { spawn, execFileSync } from "node:child_process";
import path from "node:path";

const CHUNK = Number(process.env.HUSHFACE_DL_CHUNK || 32 * 1024 * 1024);
const UA = "hushface/0.1 (+https://github.com/timqian/hushface)";
const RETRIES = 4;
const CURL = process.env.HUSHFACE_CURL || "curl";
const HAS_CURL = (() => {
  if (process.env.HUSHFACE_NO_CURL === "1") return false;
  try {
    execFileSync(CURL, ["--version"], { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
})();
const TTY = process.stderr.isTTY === true;
const COLOR = TTY && !process.env.NO_COLOR;
const DIM = COLOR ? "\u001b[2m" : "";
const CYN = COLOR ? "\u001b[36m" : "";
const GRN = COLOR ? "\u001b[32m" : "";
const RED = COLOR ? "\u001b[31m" : "";
const OFF = COLOR ? "\u001b[0m" : "";

const err = (m) => {
  process.stderr.write(`${RED}!${OFF} ${m}\n`);
};

function human(n) {
  const units = ["B", "KB", "MB", "GB", "TB"];
  let i = 0;
  let b = Number(n) || 0;
  while (b >= 1024 && i < 4) {
    b /= 1024;
    i += 1;
  }
  return i === 0 ? `${b.toFixed(0)} ${units[i]}` : `${b.toFixed(1)} ${units[i]}`;
}

function humanEta(secs) {
  if (!Number.isFinite(secs) || secs < 0 || secs > 86400 * 3) return "--";
  const s = Math.round(secs);
  if (s < 60) return `${s}s`;
  if (s < 3600) return `${Math.floor(s / 60)}m${String(s % 60).padStart(2, "0")}s`;
  return `${Math.floor(s / 3600)}h${String(Math.floor((s % 3600) / 60)).padStart(2, "0")}m`;
}

function parseArgs(argv) {
  const out = { jobs: 8, quiet: false, force: false, sha256: null, label: null, verifyOnly: null };
  const rest = [];
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === "--quiet") out.quiet = true;
    else if (a === "--force") out.force = true;
    else if (a === "--label") out.label = argv[++i];
    else if (a === "--jobs") out.jobs = Number(argv[++i]);
    else if (a === "--sha256") out.sha256 = argv[++i];
    else if (a === "--verify-only") out.verifyOnly = argv[++i];
    else if (a.startsWith("-")) {
      process.stderr.write(`unknown option ${a}\n`);
      process.exit(2);
    } else rest.push(a);
  }
  if (out.verifyOnly) return out;
  [out.url, out.dest] = rest;
  if (!out.url || !out.dest) {
    process.stderr.write("usage: dl.mjs URL DEST [options]\n");
    process.exit(2);
  }
  return out;
}

class Progress {
  constructor(label, total, quiet) {
    this.label = label;
    this.total = total;
    this.quiet = quiet;
    this.done = 0;
    this.samples = [];
    this.start = Date.now();
    this.lastPct = -1;
    this.timer = null;
  }

  add(n) {
    this.done += n;
  }

  speed() {
    const now = Date.now();
    this.samples.push([now, this.done]);
    while (this.samples.length > 2 && now - this.samples[0][0] > 4000) this.samples.shift();
    if (this.samples.length < 2) return 0;
    const [t0, b0] = this.samples[0];
    const dt = (now - t0) / 1000;
    return dt > 0 ? (this.done - b0) / dt : 0;
  }

  line() {
    const pct = this.total ? (100 * this.done) / this.total : 0;
    const sp = this.speed();
    const eta = sp > 1024 && this.total ? (this.total - this.done) / sp : null;
    const width = 22;
    const filled = Math.floor((width * pct) / 100);
    const bar = "#".repeat(filled) + "-".repeat(width - filled);
    const size = this.total ? `${human(this.done)}/${human(this.total)}` : human(this.done);
    return `${CYN}[${bar}]${OFF} ${pct.toFixed(1).padStart(5)}%  ${size}  ${human(sp)}/s  ETA ${humanEta(eta)}`;
  }

  startRender() {
    if (this.quiet) return;
    this.timer = setInterval(() => {
      if (TTY) process.stderr.write(`\r${(this.label + " " + this.line()).slice(0, 100).padEnd(100)}`);
      else {
        const pct = this.total ? Math.floor((100 * this.done) / this.total) : 0;
        if (pct >= this.lastPct + 5) {
          this.lastPct = pct;
          process.stderr.write(`${this.label} ${this.line().trim()}\n`);
        }
      }
    }, 250);
  }

  finish() {
    if (this.timer) clearInterval(this.timer);
    if (this.quiet) return;
    if (TTY) process.stderr.write(`\r${"".padEnd(100)}\r`);
    const el = (Date.now() - this.start) / 1000;
    const avg = el > 0 ? this.done / el : 0;
    process.stderr.write(
      `${GRN}✓${OFF} ${this.label}  ${human(this.done)} in ${humanEta(el)} (${human(avg)}/s)\n`,
    );
  }
}

async function sha256File(file, label, quiet) {
  const total = (await stat(file)).size;
  const hash = createHash("sha256");
  let done = 0;
  let last = 0;
  for await (const buf of createReadStream(file, { highWaterMark: 8 * 1024 * 1024 })) {
    hash.update(buf);
    done += buf.length;
    const now = Date.now();
    if (TTY && !quiet && now - last > 400) {
      last = now;
      const pct = total ? (100 * done) / total : 0;
      process.stderr.write(`\r${`${label} verifying  ${pct.toFixed(1)}%`.padEnd(100)}`);
    }
  }
  if (TTY && !quiet) process.stderr.write(`\r${"".padEnd(100)}\r`);
  return hash.digest("hex");
}

async function probe(url) {
  const res = await fetch(url, {
    headers: { "user-agent": UA, range: "bytes=0-0" },
    redirect: "follow",
  });
  if (!res.ok && res.status !== 206) throw new Error(`HTTP ${res.status}`);
  const cr = res.headers.get("content-range") || "";
  const finalUrl = res.url || url;
  await res.arrayBuffer().catch(() => {});
  const m = /bytes \d+-\d+\/(\d+)/.exec(cr);
  if (m) return { url: finalUrl, total: Number(m[1]), ranges: true };
  const cl = res.headers.get("content-length");
  return { url: finalUrl, total: cl ? Number(cl) : null, ranges: false };
}

async function readState(statePath, total) {
  let raw;
  try {
    raw = await readFile(statePath, "utf8");
  } catch {
    return { done: new Set(), ok: true };
  }
  const lines = raw.split("\n").map((l) => l.trim()).filter(Boolean);
  if (!lines.length) return { done: new Set(), ok: true };
  try {
    const head = JSON.parse(lines[0]);
    if (head.size !== total || (head.chunk ?? CHUNK) !== CHUNK) return { done: new Set(), ok: false };
    return { done: new Set(lines.slice(1).map(Number)), ok: true };
  } catch {
    return { done: new Set(), ok: false };
  }
}

async function writeAt(fh, buf, position) {
  let off = 0;
  while (off < buf.length) {
    const { bytesWritten } = await fh.write(buf, off, buf.length - off, position + off);
    off += bytesWritten;
  }
}

async function fetchRange(fh, url, start, end, prog, cid, statePath) {
  const want = end - start + 1;
  for (let attempt = 0; attempt < RETRIES; attempt += 1) {
    try {
      let got = 0;
      if (HAS_CURL) {
        // curl is 2-4x faster than undici on slow CDNs and ships with macOS
        got = await new Promise((resolve, reject) => {
          const child = spawn(
            CURL,
            ["-sS", "-L", "--fail", "--connect-timeout", "20", "-A", UA,
             "-r", `${start}-${end}`, url],
            { stdio: ["ignore", "pipe", "pipe"] },
          );
          let stderr = "";
          child.stderr.on("data", (d) => { stderr += d; });
          let n = 0;
          child.stdout.on("data", (piece) => {
            child.stdout.pause();
            writeAt(fh, piece, start + n)
              .then(() => { n += piece.length; prog.add(piece.length); child.stdout.resume(); })
              .catch((e) => { child.kill(); reject(e); });
          });
          child.on("error", reject);
          child.on("close", (code) => {
            if (code === 0) resolve(n);
            else reject(new Error(`curl exit ${code}${stderr ? `: ${stderr.trim().slice(0, 200)}` : ""}`));
          });
        });
      } else {
        const res = await fetch(url, {
          headers: { "user-agent": UA, range: `bytes=${start}-${end}` },
          redirect: "follow",
        });
        if (!res.ok && res.status !== 206) throw new Error(`HTTP ${res.status}`);
        for await (const piece of res.body) {
          await writeAt(fh, piece, start + got);
          got += piece.length;
          prog.add(piece.length);
        }
      }
      if (got !== want) throw new Error(`short read ${got}/${want}`);
      await appendFile(statePath, `${cid}\n`);
      return true;
    } catch (e) {
      if (attempt === RETRIES - 1) {
        err(`chunk ${cid} failed: ${e.message}`);
        return false;
      }
      await new Promise((r) => setTimeout(r, 1500 * (attempt + 1)));
    }
  }
  return false;
}

async function singleStream(url, destPart, prog) {
  const res = await fetch(url, { headers: { "user-agent": UA }, redirect: "follow" });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const fh = await open(destPart, "w");
  try {
    let pos = 0;
    for await (const piece of res.body) {
      await writeAt(fh, piece, pos);
      pos += piece.length;
      prog.add(piece.length);
    }
  } finally {
    await fh.close();
  }
}

async function main() {
  const a = parseArgs(process.argv.slice(2));

  if (a.verifyOnly) {
    const label = a.label || path.basename(a.verifyOnly);
    try {
      await stat(a.verifyOnly);
    } catch {
      err(`${label} is missing`);
      return 1;
    }
    if (!a.sha256) return 0;
    const got = await sha256File(a.verifyOnly, label, a.quiet);
    if (got.toLowerCase() !== a.sha256.toLowerCase()) {
      err(`${label} is corrupt`);
      process.stderr.write(`  expected ${a.sha256}\n  got      ${got}\n`);
      return 1;
    }
    if (!a.quiet) process.stderr.write(`${GRN}✓${OFF} ${label} verified\n`);
    return 0;
  }

  const label = a.label || path.basename(a.dest);
  const destPart = `${a.dest}.part`;
  const statePath = `${a.dest}.part.state`;
  await (await import("node:fs/promises")).mkdir(path.dirname(path.resolve(a.dest)), { recursive: true });

  if (!a.force) {
    try {
      const st = await stat(a.dest);
      if (st.size > 0) {
        if (!a.quiet) process.stdout.write(`have ${label}\n`);
        return 0;
      }
    } catch {
      /* not there yet */
    }
  }

  const { url, total, ranges } = await probe(a.url);
  if (!total) {
    err(`server did not report a size for ${a.url}`);
    return 1;
  }
  try {
    const st = await stat(a.dest);
    if (st.size === total && !a.force) {
      if (!a.quiet) process.stdout.write(`have ${label}\n`);
      return 0;
    }
  } catch {
    /* fine */
  }

  const jobs = Math.max(1, Math.min(a.jobs || 8, 16));
  const prog = new Progress(label, total, a.quiet);
  prog.startRender();

  let interrupted = false;
  process.on("SIGINT", () => {
    interrupted = true;
    prog.finish();
    err("interrupted — partial data kept, re-run to resume");
    process.exit(130);
  });

  if (!ranges || total < 8 * 1024 * 1024) {
    try {
      await rm(destPart, { force: true });
      await singleStream(url, destPart, prog);
    } catch (e) {
      prog.finish();
      err(`download failed: ${e.message}`);
      return 1;
    }
  } else {
    let { done, ok } = await readState(statePath, total);
    let sizeOnDisk = 0;
    try {
      sizeOnDisk = (await stat(destPart)).size;
    } catch {
      /* none */
    }
    if (!ok || sizeOnDisk !== total) {
      // adopt a sequential prefix: CLI downloaders write front to back
      const adopt = [];
      if (sizeOnDisk > 0 && sizeOnDisk < total) {
        for (let c = 0; c < Math.floor(sizeOnDisk / CHUNK); c += 1) adopt.push(c);
      }
      done = new Set(adopt);
      const fh = await open(destPart, sizeOnDisk > 0 ? "r+" : "w+");
      await fh.truncate(total);
      await fh.close();
      await writeFile(statePath, `${JSON.stringify({ size: total, chunk: CHUNK })}\n`);
      for (const c of adopt) await appendFile(statePath, `${c}\n`);
      if (adopt.length && !a.quiet) {
        process.stderr.write(`${label} adopting ${human(adopt.length * CHUNK)} already on disk\n`);
      }
    } else {
      for (const c of done) prog.add(Math.min(CHUNK, total - c * CHUNK));
    }

    const nchunks = Math.ceil(total / CHUNK);
    const todo = [];
    for (let c = 0; c < nchunks; c += 1) if (!done.has(c)) todo.push(c);
    if (done.size && todo.length && !a.quiet) {
      let have = 0;
      for (const c of done) have += Math.min(CHUNK, total - c * CHUNK);
      process.stderr.write(`${label} resuming at ${human(have)} of ${human(total)}\n`);
    }

    if (todo.length) {
      const fh = await open(destPart, "r+");
      const failed = [];
      let next = 0;
      const worker = async () => {
        for (;;) {
          if (interrupted) return;
          const i = next;
          next += 1;
          if (i >= todo.length) return;
          const cid = todo[i];
          const start = cid * CHUNK;
          const end = Math.min(start + CHUNK, total) - 1;
          const okChunk = await fetchRange(fh, url, start, end, prog, cid, statePath);
          if (!okChunk) failed.push(cid);
        }
      };
      await Promise.all(Array.from({ length: Math.min(jobs, todo.length) }, worker));
      await fh.close();
      prog.finish();
      if (failed.length) {
        err(`${failed.length} chunk(s) failed; re-run to resume`);
        return 1;
      }
    } else {
      prog.finish();
    }
  }

  const size = (await stat(destPart)).size;
  if (size !== total) {
    err(`size mismatch: got ${size}, expected ${total}`);
    return 1;
  }

  if (a.sha256) {
    const got = await sha256File(destPart, label, a.quiet);
    if (got.toLowerCase() !== a.sha256.toLowerCase()) {
      err(`checksum mismatch for ${label}`);
      process.stderr.write(`  expected ${a.sha256}\n  got      ${got}\n`);
      await rm(destPart, { force: true });
      return 1;
    }
    if (!a.quiet) process.stderr.write(`${GRN}✓${OFF} ${label} verified\n`);
  } else if (!a.quiet) {
    process.stderr.write(`${DIM}·${OFF} ${label} checksum unavailable, size ok\n`);
  }

  await rename(destPart, a.dest);
  await rm(statePath, { force: true });
  return 0;
}

main()
  .then((code) => process.exit(code ?? 0))
  .catch((e) => {
    err(e?.stack || String(e));
    process.exit(1);
  });
