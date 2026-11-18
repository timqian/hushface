# hushface.com

Serves the release artifacts from an R2 bucket behind a Worker, so

```bash
curl -LsSf https://hushface.com/install.sh | sh
```

works, and the 73 MB payload comes off Cloudflare's CDN instead of GitHub.

## One-time setup

```bash
# npx works fine; no global install needed
npx wrangler login                                   # or: export CLOUDFLARE_API_TOKEN=...

# if the account has more than one membership, pin the one that owns the zone
npx wrangler whoami
export CLOUDFLARE_ACCOUNT_ID=<account id of hushface.com>

npx wrangler r2 bucket create hushface-releases
cd cloudflare && npx wrangler deploy
```

`wrangler.toml` uses `custom_domain = true` for `hushface.com` and
`www.hushface.com`. That is what makes the apex resolve: Cloudflare creates the
proxied DNS record and issues the certificate.

Two ways this silently fails, both worth knowing:

1. **A pattern/zone_name route creates no DNS.** `routes = [{ pattern =
   "hushface.com/*", zone_name = ... }]` only *matches* traffic that already
   reaches Cloudflare, so the worker answers on `…workers.dev` while the apex
   looks dead.
2. **TOML order.** Everything after a `[[table]]` header belongs to that table,
   so `routes` / `workers_dev` must be declared **above** `[[r2_buckets]]`. Put
   them below and wrangler warns `Unexpected fields found in r2_buckets[0]:
   "routes"`, deploys anyway, and attaches no domain at all. `tests/run.sh`
   (`t_wrangler_config`) now guards this.

### 502 on hushface.com

A 502 (or 520/521/525) on a worker hostname is almost always **the request never
reaching the worker** — Cloudflare proxied it to some origin instead. Tell the two
cases apart:

| symptom | meaning | fix |
|---|---|---|
| 502, page says "Bad gateway", no worker text | proxied to an origin: old A record, Pages project, tunnel, Page Rule | see the list below |
| 502 with "Error 1101 / Worker threw exception" | the worker threw | redeploy; `npx wrangler tail` |
| 503 "hushface.com is misconfigured" | worker runs, R2 binding missing | `wrangler.toml` `[[r2_buckets]]` + redeploy |
| 500 "the worker hit an error" | worker ran, something threw inside | `npx wrangler tail` |

The worker now catches every exception and reports the reason as text, so a plain
502 with no worker text is proof the request is not reaching it.

If the apex still fails after deploying:

1. **DNS tab** — delete any pre-existing `hushface.com` A/AAAA/CNAME record
   (a parking page or placeholder wins over the worker otherwise).
2. `npx wrangler deployments list` — the last deploy should be the current one.
3. **SSL/TLS → Overview** — set the mode to *Full (strict)*.
4. `npx wrangler tail` while hitting the URL; if no request shows up, the route
   is not attached.
5. **Workers & Pages → hushface → Settings → Domains & Routes** — `hushface.com`
   must be listed as an *active* custom domain. If a *Pages* project also claims
   it, Pages wins and its origin answers (usually 502 when there is no deployment).
6. Remove any **Redirect Rule / Page Rule** matching `hushface.com/*`.
7. `tools/check-site.sh https://hushface.com` walks DNS → TLS → worker → bucket
   and says which one is broken; on a 502 it prints the evidence (cf-ray, body)
   and the two possible causes.

Until the apex is sorted, everything works against the workers.dev host — the
paths are identical:

```bash
HUSHFACE_RELEASES=https://hushface.timqian.workers.dev/releases/latest sh install.sh
```

## Publishing a release

```bash
tools/release.sh              # build → dist/release/
tools/publish-cf.sh           # upload to R2 under v<ver>/ and latest/
tools/check-site.sh           # then prove it works end to end
```

`publish-cf.sh` uses `wrangler` if it is on `PATH` and `npx --yes wrangler`
otherwise; override with `WRANGLER="npx wrangler"`. `--dry-run` prints the
commands without touching Cloudflare.

The upload sets content types and immutable caching for versioned paths,
5-minute caching for `latest/`, so a new release is visible almost immediately
while old URLs stay cacheable forever.

## URL layout in the bucket

```
latest/install.sh                       → https://hushface.com/install.sh
latest/hushface-macos-arm64.sh          → https://hushface.com/hushface-macos-arm64.sh
latest/hushface-macos-arm64.sh.sha256
v0.1.0/install.sh                       → https://hushface.com/releases/v0.1.0/install.sh
v0.1.0/hushface-macos-arm64.sh
v0.1.0/hushface-macos-arm64.sh.sha256
```

`https://hushface.com/releases/latest/<file>` also works — that is the base URL
`install.sh` and `hushface update` use by default.

## If you would rather not run a Worker

Any static host works; keep the same layout and point the client at it:

```bash
HUSHFACE_RELEASES=https://your-host/releases/latest sh install.sh
```

GitHub releases are a working fallback — `tools/release.sh` output is uploaded
under both `hushface-macos-arm64.sh` (the name the installer asks for) and the
versioned name:

```bash
HUSHFACE_RELEASES=https://github.com/timqian/hushface/releases/latest/download sh install.sh
```

If a stable-named asset ever 404s right after `gh release upload --clobber`
(while `gh release download` still works), delete that asset and re-upload it;
GitHub occasionally keeps a stale entry for a clobbered name.
