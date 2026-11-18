#!/usr/bin/env node
// Static file server with HTTP Range support, for downloader tests.
//   node fileserver.mjs DIR PORT [--no-range]
import { createReadStream, statSync } from "node:fs";
import http from "node:http";
import path from "node:path";

const [dir, portArg, ...flags] = process.argv.slice(2);
const root = path.resolve(dir);
const port = Number(portArg);
const noRange = flags.includes("--no-range");

http
  .createServer((req, res) => {
    const name = path.basename(decodeURIComponent(req.url.split("?")[0]));
    const file = path.join(root, name);
    let size;
    try {
      const st = statSync(file);
      if (!st.isFile()) throw new Error("not a file");
      size = st.size;
    } catch {
      res.writeHead(404, { "content-length": 0 });
      return res.end();
    }

    const m = noRange ? null : /bytes=(\d+)-(\d*)$/.exec(req.headers.range || "");
    if (m) {
      const start = Number(m[1]);
      const end = m[2] ? Math.min(Number(m[2]), size - 1) : size - 1;
      if (start >= size) {
        res.writeHead(416, { "content-range": `bytes */${size}`, "content-length": 0 });
        return res.end();
      }
      res.writeHead(206, {
        "content-range": `bytes ${start}-${end}/${size}`,
        "content-length": end - start + 1,
      });
      return createReadStream(file, { start, end }).pipe(res);
    }

    res.writeHead(200, { "content-length": size });
    return createReadStream(file).pipe(res);
  })
  .listen(port, "127.0.0.1");
