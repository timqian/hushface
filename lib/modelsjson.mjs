#!/usr/bin/env node
// The `hushface` provider block inside ~/.pi/agent/models.json.
//
//   node modelsjson.mjs merge  FILE PROVIDER URL MODEL_ID CTX
//   node modelsjson.mjs remove FILE PROVIDER
//   node modelsjson.mjs has    FILE PROVIDER     -> exit 0/1
//
// Never rewrites the file unless something changed, and keeps a .bak of the
// previous version. Other providers (and their keys) are left alone.

import { copyFile, readFile, writeFile } from "node:fs/promises";

async function load(file) {
  try {
    const raw = await readFile(file, "utf8");
    if (!raw.trim()) return {};
    return JSON.parse(raw);
  } catch (e) {
    if (e.code === "ENOENT") return {};
    throw e;
  }
}

async function save(file, data) {
  await copyFile(file, `${file}.bak`).catch(() => {});
  await writeFile(file, `${JSON.stringify(data, null, 2)}\n`);
}

const [cmd, file, ...rest] = process.argv.slice(2);

if (cmd === "has") {
  const [provider] = rest;
  try {
    const data = await load(file);
    const p = data.providers?.[provider];
    process.exit(p?.models?.length ? 0 : 1);
  } catch {
    process.exit(1);
  }
} else if (cmd === "remove") {
  const [provider] = rest;
  const data = await load(file);
  if (!data.providers?.[provider]) process.exit(0);
  delete data.providers[provider];
  if (!Object.keys(data.providers).length) delete data.providers;
  await save(file, data);
  process.stdout.write(`removed provider '${provider}' from ${file}\n`);
} else if (cmd === "merge") {
  const [provider, url, modelId, ctx] = rest;
  const data = await load(file);
  const before = JSON.stringify(data);
  data.providers = data.providers ?? {};
  const p = (data.providers[provider] = data.providers[provider] ?? {});

  // api must be openai-completions: the adapter was trained on chat
  // completions, and pi would otherwise use the Responses API.
  p.baseUrl = url;
  p.api = "openai-completions";
  p.apiKey = "local";

  p.models = p.models ?? [];
  let model = p.models.find((m) => m.id === modelId);
  if (!model) {
    model = { id: modelId };
    p.models.push(model);
  }
  model.name = model.name ?? "Qwen3.8 27B · pi adapter (local)";
  model.contextWindow = Number(ctx);
  model.maxTokens = model.maxTokens ?? Math.min(16384, Math.floor(Number(ctx) / 4));
  model.input = model.input ?? ["text"];
  model.samplingParams = model.samplingParams ?? { temperature: 0.8, top_p: 1.0 };
  model.promptCache = model.promptCache ?? { short: 300, long: 3600 };

  const after = JSON.stringify(data);
  if (after === before) process.exit(0);
  await save(file, data);
  process.stdout.write(`updated ${file}\n`);
} else {
  process.stderr.write("usage: modelsjson.mjs merge|remove|has ...\n");
  process.exit(2);
}
