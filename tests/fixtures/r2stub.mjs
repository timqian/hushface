#!/usr/bin/env node
// Serves cloudflare/worker.js against a local directory that mimics the R2
// bucket layout, so the routing/range logic can be tested without Cloudflare.
//
//   node r2stub.mjs WORKER_DIR BUCKET_DIR PORT
//
// Bucket layout: BUCKET_DIR/latest/<file>, BUCKET_DIR/v<ver>/<file>
import { createReadStream, existsSync, readFileSync, statSync } from "node:fs";
import http from "node:http";
import path from "node:path";
import { Readable } from "node:stream";
import { pathToFileURL } from "node:url";

const [workerDir, bucketDir, portArg] = process.argv.slice(2);
const port = Number(portArg);
const worker = (await import(pathToFileURL(path.join(workerDir, "worker.js")).href)).default;

const resolveKey = (key) => {
  const file = path.join(bucketDir, key);
  if (!file.startsWith(path.resolve(bucketDir))) return null;
  return existsSync(file) && statSync(file).isFile() ? file : null;
};

const bucket = {
  async head(key) {
    const file = resolveKey(key);
    if (!file) return null;
    return { size: statSync(file).size };
  },
  async get(key, opts = {}) {
    const file = resolveKey(key);
    if (!file) return null;
    const size = statSync(file).size;
    const range = opts.range;
    const start = range ? range.offset : 0;
    const length = range ? range.length : size;
    const stream = createReadStream(file, { start, end: start + length - 1 });
    return {
      size: length,
      httpEtag: `"stub-${size}"`,
      httpMetadata: { contentType: "application/octet-stream" },
      body: Readable.toWeb(stream),
    };
  },
};

http
  .createServer(async (req, res) => {
    const url = new URL(req.url, `http://127.0.0.1:${port}`);
    const headers = {};
    for (const [k, v] of Object.entries(req.headers)) headers[k] = v;
    try {
      const response = await worker.fetch(new Request(url, { method: req.method, headers }), {
        RELEASES: bucket,
      });
      res.writeHead(response.status, Object.fromEntries(response.headers));
      if (!response.body) return res.end();
      for await (const piece of response.body) res.write(Buffer.from(piece));
      res.end();
    } catch (e) {
      res.writeHead(500, { "content-type": "text/plain" });
      res.end(`stub error: ${e.message}\n`);
    }
  })
  .listen(port, "127.0.0.1");
