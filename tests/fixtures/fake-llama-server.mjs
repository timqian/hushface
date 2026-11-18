#!/usr/bin/env node
// Tiny llama-server stand-in for tests: /health, /v1/models, tool calls.
import { writeFileSync } from "node:fs";
import http from "node:http";

const argv = process.argv.slice(2);
if (argv.includes("--version")) {
  process.stdout.write("version: 9999 (fake)\n");
  process.exit(0);
}

const arg = (name, fallback) => {
  const i = argv.indexOf(name);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : fallback;
};

const port = Number(arg("--port", 9931));
const alias = arg("--alias", "qwen3.8-pi");

if (process.env.FAKE_ARGS_FILE) writeFileSync(process.env.FAKE_ARGS_FILE, argv.join(" "));

const json = (res, code, body) => {
  const buf = Buffer.from(JSON.stringify(body));
  res.writeHead(code, { "content-type": "application/json", "content-length": buf.length });
  res.end(buf);
};

http
  .createServer((req, res) => {
    if (req.method === "GET" && req.url === "/health") return json(res, 200, { status: "ok" });
    if (req.method === "GET" && req.url === "/v1/models") return json(res, 200, { data: [{ id: alias }] });
    if (req.method === "POST") {
      req.resume();
      return json(res, 200, {
        choices: [
          {
            message: {
              role: "assistant",
              content: null,
              tool_calls: [
                { id: "c1", type: "function", function: { name: "bash", arguments: '{"command":"ls"}' } },
              ],
            },
          },
        ],
      });
    }
    return json(res, 404, { error: "not found" });
  })
  .listen(port, "127.0.0.1");
