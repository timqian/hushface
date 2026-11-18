# hushface

A local coding agent in one command: **pi + Qwen3.8-27B with the
[`harness-hub/Qwen3.8-27B-pi-adapted`](https://huggingface.co/harness-hub/Qwen3.8-27B-pi-adapted) LoRA**,
running on your own Mac.

```bash
curl -LsSf https://hushface.com/install.sh | sh
```

That is the whole installation. It downloads a single 73 MB file that contains
the app **and its entire runtime** — Node, pi, llama.cpp — verifies its checksum,
installs it into `~/.local/share/hushface`, links `~/.local/bin/hushface`, and
then hands over to `hushface` itself, which checks your machine, downloads the
model, and opens the agent. No Homebrew, no Node, no npm, no Xcode CLT, no Python.

```bash
hushface                                  # start (or continue) chatting
hushface -p "fix the failing test"        # anything unrecognised goes to pi
hushface stop                             # free ~22 GB of RAM
```

## Intallation

```bash
curl -LsSf https://hushface.com/install.sh | sh
```

## Updating

```bash
hushface update      # downloads the latest build and installs it in place
```

For a bundled install the versions are pinned per artifact, so updating means
fetching a new payload; `hushface update` does exactly that and reports the
version change. A source checkout uses `git pull`.

## Why a 73 MB file and not 22 GB

The weights are 22 GB of GGUF; no packaging trick puts them in the binary, and
zipping GGUF saves nothing. So the split is:

| what | when | size |
|---|---|---|
| app + runtime (this file) | once, at install | 73 MB |
| Qwen3.8-27B `UD-Q6_K` + adapter | once, first run | ~22 GB, resumable |
| RAM while running | while the server is up | ~22 GB (`stop` frees it) |

Everything after the model download is local and offline. What bundling buys is
that the *install* has no prerequisites: no Homebrew, no Node, no Xcode CLT, no
npm, no Python.

## What happens on the first run

```
Checking this machine
✓ Apple Silicon (arm64), 16 cores
✓ macOS 26.6.2
✓ 48 GB RAM, quant Q6_K (22 GB in memory)
✓ 151 GB free (need 32 GB)
✓ curl 8.7.1
✓ node 26.7.0 (bundled)
✓ pi 1.5.2 (bundled)
✓ llama.cpp 1.0.0-dev (build 12503) (bundled)

  quant      Q6_K · 22 GB in memory
  download   22 GB + adapter into ~/.hushface
  source     huggingface.co, falling back to modelscope.cn
  port       9931

Where should the model come from?
  1) Hugging Face huggingface.co  · the original repo       · reachable
  2) ModelScope   modelscope.cn   · fast in mainland China · reachable
choose [1-2] (default 1): 2

Download ~22 GB and continue? [Y/n]
```

Then: weights → `~/.hushface/config.env` → the `hushface` provider in
`~/.pi/agent/models.json` → server → pi. Every step is idempotent and resumable;
`Ctrl-C` mid-download is fine, the next run continues.

### Machine support (checked, not assumed)

| check | requirement | why |
|---|---|---|
| CPU | Apple Silicon (arm64) | 27B on an Intel Mac's GPU is unusably slow |
| macOS | ≥ 13 | Metal features llama.cpp relies on |
| memory | ≥ 22 GB free, 32 GB+ comfortable | weights must stay resident |
| disk | weights + 10 GB | preallocated file + working room |

Memory picks the quant automatically: ≥ 60 GB → `Q8_0`, ≥ 40 → `Q6_K`,
≥ 30 → `Q5_K_M`, ≥ 22 → `Q4_K_XL` (with a warning), below that it refuses with
the reason instead of thrashing. Override with `--quant`.

### Downloads: parallel, resumable, verified

```
Qwen3.8-27B-UD-Q6_K.gguf [##########>-----------]  46.2%  10.1 GB/20.5 GB  53.9 MB/s  ETA 3m11s
```

- each 32 MB chunk is a separate ranged request, 8 at a time, recording progress
  in a sidecar so an interrupted run resumes per chunk;
- transport is `curl` (2–4× faster than Node's fetch on slow CDNs, and present on
  every macOS; Node's fetch is the fallback);
- an existing sequential prefix (an interrupted `modelscope download`, say) is
  adopted instead of thrown away;
- the SHA-256 published by ModelScope (`Sha256`) or Hugging Face (`lfs.oid`) is
  verified after download, and pre-existing files are verified once;
- **the hub you picked** is tried first (Hugging Face is the default), the
  other one is the fallback
  (`--source hf|modelscope` to force one, `hushface source` to change the default).

## Commands

| command | what it does |
|---|---|
| `hushface [pi args…]` | ensure install + server, then pi |
| `start` / `stop` / `restart` / `status` | model server lifecycle |
| `serve` | run the server in the foreground |
| `logs [n]` | tail the server log |
| `info` | versions, paths, sizes, port, what is running |
| `doctor [--report]` | full check: preflight, reachability, health, real tool-call round trip |
| `source [auto\|modelscope\|hf]` | show or change where the weights come from |
| `pull` | re-download / re-verify weights |
| `update` | update (bundled: run a newer installer; source checkout: `git pull`) |
| `clean` | drop partial downloads, caches, rotated logs |
| `uninstall` | remove weights, config, pi provider, and (bundled) the app itself |

Flags: `--yes`, `--dry-run`, `--quant`, `--ctx`, `--port`, `--source`,
`--jobs`, `--ephemeral`, `--no-verify`, `--verbose`, `--force`.

## Why this shape

The adapter is served three ways upstream: vLLM, `transformers serve`, or
llama.cpp with a GGUF LoRA. Without CUDA only the last works locally, so:

```
hushface ─┬─ llama-server -m base.gguf --lora adapter.gguf   (:9931)
          └─ pi --provider hushface --model qwen3.8-pi
```

pi talks to it through a plain `openai-completions` provider. That is deliberate:
the adapter was trained on the chat-completions API, and pi's built-in
`llama.cpp` provider expects router mode, which cannot attach a LoRA.

The launch line matters as much as the weights:

- `--chat-template-kwargs '{"enable_thinking": false}'` — the adapter is trained
  with thinking **off**; turning it on adds ~4× tokens for the same accuracy;
- `--jinja` — tool calling; `hushface doctor` fails loudly if the model stops
  emitting `tool_calls`;
- `--parallel 1`, `-c 65536` — one slot, full context, prefix caching intact;
- sampling at the training values (`temperature 0.8`, `top_p 1.0`) in
  `models.json`.

## Config

`~/.hushface/config.env`, plain shell, all optional:

```sh
PORT=9931              # server port (auto-moves if taken)
HOST=127.0.0.1
CTX=65536              # kept in sync with contextWindow in models.json
QUANT=Q6_K             # Q8_0 | Q6_K | Q5_K_M | Q4_K_XL
SOURCE=auto            # auto | modelscope | hf
EPHEMERAL=0            # 1 = stop the server when pi exits
MS_TOKEN= HF_TOKEN=    # only for gated repos
```

## Layout

```
dist/release/                   (what gets uploaded to a GitHub release)
  install.sh                    the bootstrap users pipe into sh
  hushface-macos-arm64.sh       73 MB: app + runtime, stable name
  hushface-macos-arm64.sh.sha256
  hushface-<ver>-macos-arm64.sh versioned copy

~/.local/share/hushface/        (after install)
  bin/hushface                  entry point
  lib/*.sh lib/*.mjs            implementation
  runtime/node/bin/node         bundled Node
  runtime/pi/                   bundled pi (dist/bundle/cli.js, no node_modules)
  runtime/llama/bin/            bundled llama-server + dylibs
  runtime/manifest.json         versions baked in at build time

~/.hushface/                    (data)
  models/  config.env  server.log  install.log  verified/  .downloads/
```

## Development

Source install (uses your own node/pi/llama.cpp, no bundled runtime):

```bash
tools/install-from-source.sh    # links bin/hushface into ~/.local/bin
hushface
```

Tests and lint (offline, no weights needed):

```bash
tests/run.sh            # 93 tests
shellcheck -S warning -e SC2016,SC1090,SC1091 bin/hushface lib/*.sh install.sh tests/run.sh tools/*.sh
```

Build the artifacts:

```bash
tools/release.sh                      # build + stable names + checksums → dist/release/
tools/release.sh --version 0.1.1      # bump, build
tools/release.sh --from-local         # take pi from the local npm install
tools/build-payload.sh                # just the artifact, tests use this
NODE_VERSION=26.7.0 PI_VERSION=1.5.2 LLAMA_URL=... tools/build-payload.sh
```

Then publish to the CDN that serves `hushface.com`:

```bash
npx wrangler r2 bucket create hushface-releases   # once
(cd cloudflare && npx wrangler deploy)            # once: worker + custom domain
tools/publish-cf.sh                               # v<ver>/ and latest/ in R2
tools/check-site.sh                               # DNS → TLS → worker → bucket
```

`cloudflare/` holds the worker (routes `/install.sh`, `/hushface-macos-arm64.sh`,
`/releases/latest/<file>` and `/releases/v<ver>/<file>` at an R2 bucket, with
range support and an immutable cache policy for versioned paths). The custom
domain is declared with `custom_domain = true`, which is what creates the DNS
record and certificate — and those keys have to sit *above* `[[r2_buckets]]` in
`wrangler.toml`, or wrangler reads them as bucket settings and attaches nothing
(`tests/run.sh` guards it). `cloudflare/README.md` has the troubleshooting list. Any other
static host works too — keep the layout and point `HUSHFACE_RELEASES` at it.
GitHub releases are a working fallback (both the stable `hushface-macos-arm64.sh`
and the versioned asset are uploaded there):

```bash
HUSHFACE_RELEASES=https://github.com/timqian/hushface/releases/latest/download sh install.sh
```

### Layout of the source

```
bin/hushface      entry point, flag parsing, dispatch, install orchestration
lib/ui.sh         colours, ✓/!/✗ lines, spinner, prompts, formatting
lib/runtime.sh    bundled-vs-system resolution for node / pi / llama-server
lib/platform.sh   machine checks, quant choice, port picking
lib/dl.mjs        parallel resumable downloader (curl transport, speed/ETA, sha256)
lib/hub.mjs       ModelScope / Hugging Face / llama.cpp release metadata
lib/modelsjson.mjs the provider block in ~/.pi/agent/models.json
lib/install.sh    llama.cpp + pi + weights + config
lib/server.sh     llama-server lifecycle, health wait, log rotation
lib/pi.sh         provider wiring and removal
tests/            bash suite + fake llama-server, file server, R2/worker stub
cloudflare/       worker.js + wrangler.toml: serves hushface.com from R2
tools/            build-payload.sh, installer-header.sh, release.sh,
                  publish-cf.sh, check-site.sh, install-from-source.sh
```

bash 3.2 (macOS `/bin/bash`) throughout: no associatives, no `mapfile`, no
`${var,,}`, no `set -u` empty-array traps. Node is only used where it is clearly
better (downloads, JSON, HTTP).

## Limits worth knowing

- macOS on Apple Silicon only, one model, one quant at a time.
- ~22 GB stays in RAM while the server runs; `hushface stop`, `--ephemeral` or
  `EPHEMERAL=1` give it back.
- Only Qwen3.8-27B + this adapter; the LoRA is tied to that base.
- `update` for a bundled install means running a newer installer (that is the
  price of shipping a runtime: versions are pinned per artifact).
- v1 is terminal-only by design: `curl … | sh`, then `hushface`. A double-clickable
  `.app`/DMG needs Apple notarization (Developer ID) to be usable by people who
  never open Terminal; that is the next step, not this release.
- The 73 MB payload is served from `hushface.com` (Cloudflare R2 behind a Worker).
  If that is slow or blocked, `HUSHFACE_RELEASES` points the installer at any
  mirror with the same layout. The 22 GB of weights come from the hub you pick
  at first run — Hugging Face by default, ModelScope if you are in mainland
  China and want the faster one.
- `install.sh`/the git path is the developer workflow; the artifact is what
  users should get.
