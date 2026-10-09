# incyght-harness plugin (maintainer notes)

How the harness ships as a Claude Code plugin. This file is **internal** — it is
stripped during `assemble-plugin` and never reaches end users.

## The idea in one picture

```
thin plugin (git, tiny)                artifact host (on demand, hash-pinned)
  .mcp.json  ── command ─▶ bin/incyght-harness-launch ──┐
  manifest.json (pins version + sha256)                 │ first run only:
  bin/incyght-harness-launch(.cmd)                       ▼ download+verify TWO artifacts
  .claude-plugin/                           harness-<plat>-<ver>.jar   (per-platform)
                                            harness-runtime-<plat>.*   (jlink JRE)
                                                          │
                                    every run:  exec <runtime>/bin/java -jar <jar>
                                                          │  (cached, offline-ok)
```

The distribution is **two artifacts**, not one:
- the **jlink JRE** built by `.gitlab/runtime/build-runtime.sh` (`harness-runtime/bin/java`) — reusable, JAR-independent.
- the **harness fat JAR** — one per platform (`harness-<platform>-<ver>.jar`), each embedding
  only its own Playwright driver. The launcher fetches the jar for the detected
  platform; a platform with no jar in the manifest fails loudly. Combined at launch
  as `java -jar`.

## Two plugin layouts in one directory

Every client reads its own manifest, so the plugin ships both layouts side by side:

| Layout | Files | Clients |
|---|---|---|
| Claude format | `.claude-plugin/plugin.json`, `.mcp.json` | Claude Code, Devin |
| Agent Plugins 1.0 | `plugin.json`, `mcp.json` | Codex, Copilot (CLI, VS Code, app), Cursor |

Rules that keep the two from clashing:
- Claude Code and Devin never read the root `plugin.json`/`mcp.json`; Agent Plugins clients
  prefer the root manifest over `.claude-plugin/`. Cursor is the exception: it loads
  `.mcp.json` before `mcp.json` when both exist, so `.cursor-plugin/plugin.json` pins
  `mcpServers` to `./mcp.json`.
- `mcp.json` is placeholder-free: `command` is `./bin/incyght-harness-launch` (resolved
  against the plugin root by every client) and there is **no `env` block**. The spec expands
  `${PLUGIN_ROOT}`/`${PLUGIN_DATA}` only in `args`/`env`/`cwd`, Cursor expands neither, and
  `${user_config.*}` exists only in Claude Code. The launcher needs none of them: it finds the
  manifest next to itself and reads the cache dir from `PLUGIN_DATA` (Agent Plugins) or
  `CLAUDE_PLUGIN_DATA` (Claude Code), falling back to a HOME path.
- The access token therefore comes from the **inherited process environment**
  (`INCYGHT_TOKEN`) on Agent Plugins clients; only Claude Code injects it from `userConfig`.
- Known open point: the spec starts a stdio server in the **plugin root** when `cwd` is
  omitted, and `cwd` may not leave the plugin. The harness takes the repo root from its
  working directory, so on those clients it needs another source (MCP roots). Tracked in #185.

## Why it is shaped this way
- Plugin dirs are git-cloned to every user → **no binaries in the plugin**. JRE + JAR live on a host.
- Provisioning lives **inside the launcher** (the MCP command), not in a hook: hook-vs-MCP
  start order is undocumented, so a `SessionStart` prefetch can't reliably beat the server
  spawn. So there is **no hook** — the launcher provisions on first run.
- No Node/Python guaranteed → launcher is plain `sh` (+ `.cmd` for Windows-native).
- sha256 is pinned in the **git-delivered** manifest → the host cannot swap an artifact.
- If no bundled runtime exists for the platform, the launcher falls back to system `java`.

## First run (one-time download)
The launcher downloads + verifies the JAR and runtime **during MCP server startup**. MCP
startup is non-blocking, so the session starts normally and the harness tools appear once
the fetch finishes. If the initial connection times out on a slow link (the artifacts are
~hundreds of MB), raise the MCP **startup** timeout — `MCP_TIMEOUT=300000 claude`, or set
it in `~/.claude/settings.json` `env`. Every later session is served from cache (no
download), so this cost is paid once per version.

## Two swappable decisions, and where they live (nowhere in the launcher)
- **Where artifacts are hosted** → `manifest.baseUrl` + `scripts/upload-bundles.sh`.
  Today: a **private Cloudflare R2 bucket** fronted by a token-gating Worker
  (`distribution/r2-worker`), served on a `*.workers.dev` URL. Swapping hosts touches
  only those two spots.
- **How access is gated** → two independent gates:
  - *artifact side*: the `auth` header/env in the manifest. The user's access token
    (plugin `userConfig` → `X-Incyght-Token`) is validated by the Worker; anonymous
    requests get `401`/`403`.
  - *marketplace side*: the public GitHub marketplace repo is world-readable (safe —
    it holds no artifacts); CI pushes to it with a repo-scoped **deploy key**.

## Cache layout (${CLAUDE_PLUGIN_DATA} / ${PLUGIN_DATA})
```
harness/<ver>/harness-<platform>-<ver>.jar
harness/<ver>/<platform>/harness-runtime/bin/java
```

## Dev loop

The launcher is **production-only** — it always provisions from the manifest, with no
local-JAR shortcut (no dev code ships in it). Two ways to develop:

- **Iterate on the harness itself** — the repo's own `.mcp.json` runs the freshly built
  JAR under the `incyght_harness-dev` server (`java -jar harness/target/harness-*.jar`).
  Rebuild, then `/mcp` reconnect.
- **Exercise the launcher / provisioning path** — `sh scripts/demo-local.sh` renders a
  manifest pointing at a fake JRE + JAR over `file://` and runs the launcher end to end
  (download → sha256 verify → exec), no host or token needed.

> **Disable the marketplace plugin's MCP server while developing** (or don't install the
> plugin locally). The published plugin exposes an `incyght_harness` server; the dev
> `.mcp.json` exposes `incyght_harness-dev`. The `-dev` suffix keeps the server names from
> colliding, but running both at once still surfaces the same harness tools twice — disable
> the marketplace one to avoid the duplication.

## Versioning

The harness follows **semantic versioning** (`MAJOR.MINOR.PATCH`). The **git tag is
the version, with no `v` prefix** — tag `<version>`, not `v<version>`. That exact string
flows through unchanged: the Maven build (`-Drevision=$CI_COMMIT_TAG`, renamed per
platform to `harness-<platform>-<version>.jar`), the published artifact names
(`harness-runtime-<platform>-<version>.<ext>`), the manifest (`harnessVersion` +
versioned `baseUrl`), and the cache path (`${CLAUDE_PLUGIN_DATA}/harness/<version>/`).
Non-tag builds (MR/master) keep the pom default `0.0.1-SNAPSHOT`.

## Build/publish (CI, tag-gated)
`.gitlab-ci.yml` `runtime-images` builds the jlink archives + the three per-platform fat
JARs (one `-Pplatform-*` build each, renamed into `build/jars/`, each asserted to embed only
its own driver) from the tag. The plugin pipeline (`.gitlab-ci.yml`) then:
- **`assemble-plugin`** — render `manifest.json` from the `.tmpl` (version + R2 baseUrl
  + sha256 of the archives and each per-platform JAR); strip the `.tmpl` and this README.
- **`publish`**:
  - `scripts/upload-bundles.sh` — version-stamp the runtime archives and upload the three
    per-platform JARs + runtimes to R2 via `rclone` (S3 multipart; the fat JARs exceed
    wrangler's 300 MiB single-PUT limit), keyed `<version>/<file>`.
  - `scripts/publish-plugin.sh` — build the marketplace tree fresh (copy
    `marketplace.json` from `distribution/marketplace/` to the Claude Code, Copilot and
    Cursor marketplace locations, copy the assembled plugin into
    `plugins/incyght-harness/`, stamp the version into every manifest) and publish it
    over SSH (deploy key)
    as a **single orphan commit, force-pushed** to the default branch — the repo is a
    generated mirror kept at one clean commit — committed as *Incyght Release Bot*, with
    a force-updated `<version>` tag.

See `distribution/r2-worker/README.md` and `distribution/marketplace/README.md` for the
host and marketplace details and the required CI/CD variables.
