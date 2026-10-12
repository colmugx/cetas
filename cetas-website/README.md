# cetas-website

The Cetas documentation site: Astro + [`@cloudflare/nimbus-docs`](https://nimbus-docs.com).

This file records project-owned knowledge — decisions, verified behavior, and known traps found while setting this site up. `AGENT.md` is the upstream starter's guide and stays canonical for *how to edit a Nimbus site*; it is overwritten by `nimbus-docs diff --apply`, so anything specific to Cetas belongs here instead.

The site replaced the previous Astro + Starlight site in `website/` (now removed); its 17 documentation pages were migrated here.

---

## 1. Stack and layout

| Concern | Choice |
| --- | --- |
| Framework | Astro 7.3.1, `output: "static"` |
| Docs engine | `@cloudflare/nimbus-docs` ^0.17.0 (installed 0.17.0) |
| Styles | Tailwind v4 via `@tailwindcss/vite` + `src/styles/{globals,prose}.css` |
| Search | Pagefind, run by the Nimbus integration at build time |
| OG images | `astro-og-canvas` + `canvaskit-wasm` |
| Icons | Iconify Phosphor (`ph:*`) |
| Package manager | pnpm (`pnpm-lock.yaml`, `pnpm-workspace.yaml`) |

```
astro.config.ts        nimbus config + Tailwind + lint rules + markdown plugins
nimbus.json            template ledger: variant, lastReviewedNimbusVersion, components
AGENT.md / CLAUDE.md   upstream starter guidance (CLAUDE.md just points at AGENT.md)
src/
├── components.ts      MDX globals registry — components usable in .mdx without import
├── components/        AgentDirective, Header, Render, WebMCP + ui/<slug>/
├── content/docs/      the documentation, organized in directories (see chapter 4)
├── content/partials/  reusable MDX chunks, included with <Render file="..." />
├── content.config.ts  docsCollection() + partialsCollection()
├── layouts/           BaseLayout (theme, NimbusHead, WebMCP, search), DocsLayout
├── pages/             routes: [...slug], markdown mirrors, llms*, robots, og, 404
└── styles/            globals.css, prose.css
```

The deploy target is **GitHub Pages**, as a project page under `/cetas/` — see chapter 3.

---

## 2. Commands

```bash
pnpm install
pnpm run dev        # dev server
pnpm run verify     # astro check && astro build  ← use this as the local gate
pnpm run lint:docs  # nimbus-docs lint (frontmatter + internal links)
pnpm run build      # astro build alone
pnpm run preview    # serve dist/
pnpm run typecheck  # astro check alone
```

**Run everything through pnpm, not by calling `node_modules/.bin/*` directly.** See chapter 7.

Expected output of a healthy `pnpm run verify`:

- `astro check` → `Result (99 files): 0 errors, 0 warnings, 0 hints`
- `[nimbus-docs] nimbus: output=static · adapter=none · docs prerendered=17/17`
- `[Building search indexes] Indexed 17 pages`
- `[@astrojs/sitemap] sitemap-index.xml created at dist`
- exit code `0`

Expected output of `pnpm run lint:docs`: `✓ 17 file(s) lint clean.`

Both counts are content-dependent: update them when you add or remove pages.

---

## 3. Site configuration and deployment (`astro.config.ts`)

The Nimbus config block drives everything URL-shaped:

| Field | Current value | Drives |
| --- | --- | --- |
| `site` | `"https://www.colmugx.top"` — the **origin**, i.e. the Pages custom domain | canonical URLs, absolute OG URLs, `robots.txt`'s `Sitemap:` line, the sitemap, and every link in `llms.txt` / `llms-full.txt` |
| `title` | `"Cetas"` | `<title>`, the home H1, OG cards, `llms.txt` heading |
| `description` | `"A coding agent for your terminal, editor, and scripts."` | meta description, OG cards, `llms.txt` blurb |
| `locale` | `"en"` | `<html lang>` |
| `github` | `"https://github.com/colmugx/cetas"` | repository link. Must be a **URL string** (validated as `z.string().url()`), not `owner/repo` |
| `socialImageAlt` | `"Cetas documentation preview"` | OG image alt text |

`output: "static"` with the `// nimbus:adapter` marker comment left in place — swap in an adapter if the deploy target ever needs server output.

Authoring rules are opt-in. Two are enabled and mirrored into `.nimbus/lint.json`:

```ts
rules: {
  "nimbus/frontmatter-shape": "error",
  "nimbus/internal-link": "error",
}
```

Add the rest (heading hierarchy, code-fence language, style…) when you want them enforced — see `nimbus-docs lint --help`.

`markdown.hastPlugins: [tableScroll()]` wraps wide tables so they scroll; the wrapper is styled by `.nb-table-scroll` in `src/styles/prose.css`.

### Logo and favicon

Nimbus has **no `logo` config field**. Two separate mechanisms cover branding:

- **Header logo** — `src/components/Header.astro` renders the default `brand` slot as `<img src={withBase("/cetas-logo.svg", …)}>` alongside the `config.title` wordmark. No page overrides that slot, so this is the only place to change it. It must go through `withBase`, or the `/cetas/` project-page prefix goes missing.
- **Favicon** — resolved **at build time by filename**, not by config: Nimbus looks for `public/favicon.svg`, then `favicon.ico`, then `favicon.png`, and the first that exists wins. Exactly one `<link rel="icon">` is emitted for the winner, with its type derived from the name.

The consequence worth remembering: an icon under any other filename is ignored. The artwork has to be named `favicon.svg`.

So `public/cetas-logo.svg` and `public/favicon.svg` are the same artwork under two names — one addressing the header, one the auto-detected favicon. If the mark changes, update both. Collapsing them to one file would mean naming the header image `favicon.svg`; pointing the icon at `cetas-logo.svg` is not an option, because only one icon link is ever emitted and its filename is fixed.

`favicon.ico` was removed for that reason: with `favicon.svg` present it can never be linked, so it was 4.3 KB of dead weight shipped on every deploy. It is recoverable from git, but restoring it would still not get it linked unless `favicon.svg` is deleted first, since SVG outranks ICO.

The mark fill colour is hard-coded (`fill="#256C63"`, the Cetas brand green), so it does **not** adapt to dark mode. A theme-aware mark would need the SVG inlined with `fill="currentColor"` or a CSS `mask` — both trade away the single-file convenience.

### `site` is the origin; the path prefix comes from Astro's `base`

The Nimbus config has **no `base` field** — its schema is strict. The site keeps its `/cetas/` prefix on the custom domain too (a project page is still served under its repository path), so the prefix has to come from Astro's top-level `base`, and the two must be set together:

```ts
const nimbusConfig = defineNimbusConfig({
  site: "https://www.colmugx.top",   // origin only
  …
});

export default defineConfig({
  base: "/cetas/",                     // the /<repo>/ prefix
  …
});
```

Do not put the path in `site`. `site` is resolved against absolute paths: `new URL("/sitemap-index.xml", "https://www.colmugx.top/cetas")` yields `https://www.colmugx.top/sitemap-index.xml` — the prefix silently disappears.

Verified on a build that Nimbus prefixes **everything**, including links authored in MDX:

| Surface | Built value |
| --- | --- |
| canonical | `https://www.colmugx.top/cetas/using-cetas/cli/` |
| `robots.txt` | `Sitemap: https://www.colmugx.top/cetas/sitemap-index.xml` |
| sitemap | `https://www.colmugx.top/cetas/concepts/architecture/` |
| `llms.txt` | `https://www.colmugx.top/cetas/llms-full.txt` |
| `og:image` | `https://www.colmugx.top/cetas/og/using-cetas/cli.png` |
| authored MDX link | `/using-cetas/automation/` in source → `href="/cetas/using-cetas/automation/"` |
| home cards | `/cetas/getting-started/installation/` |

The starter's use of `withBase(entry.url, import.meta.env.BASE_URL)` is what makes this work; hardcoded `href`s in `.astro` files are the one thing Astro will *not* rewrite for you.

`dist/` still contains no nested `cetas/` directory — `base` is a URL prefix, and Pages serves the artifact under that path. Adding a **custom domain** changes `site` only; renaming the repository or moving it to an organisation changes `base`.

### Deployment: GitHub Pages

`.github/workflows/site.yml` builds and publishes the site. On `main` it deploys; on pull requests it only builds, so a broken site fails review instead of shipping.

| Step | Command |
| --- | --- |
| typecheck | `pnpm run typecheck` |
| build | `pnpm run build` |
| doc lint | `pnpm run lint:docs` — **after** the build, so internal links resolve against the real route map |

All steps run with `working-directory: cetas-website`, and the Pages artifact path is `cetas-website/dist`.

**One-time setup** — *Settings → Pages → Build and deployment → Source: **GitHub Actions***. This is now done: the site is live and the workflow has run green (chapter 9). Without it the build job stops at `configure pages` with a "Get Pages site failed" error.

`public/.nojekyll` is committed so the `_astro/` and `_nimbus/` directories survive. The artifact-based deploy does not run Jekyll, but the branch-based alternative does, and it would silently drop every asset directory with a leading underscore.

---

## 4. Content and routing

- Content lives in `src/content/docs/**` with a **required** `title` in frontmatter.
- Route = file path relative to `src/content/docs/`, without the extension, with a **trailing slash**: `using-cetas/cli.mdx` → `/using-cetas/cli/`.
- `src/pages/index.astro` is the home page and is **hand-written**; it is not part of the `docs` collection, so unlike `nimbus-docs.com` it has no Markdown mirror. It composes a hero, an install command, a "Why Cetas" list, and "Where to go next" cards, and reuses the `Code` component so command blocks match the rest of the site.
- Nimbus generates, for free:
  - a Markdown mirror of every page (`/<slug>/index.md`) and the authored source (`/<slug>/index.mdx`)
  - `/llms.txt`, `/llms-full.txt`, `/[section]/llms.txt`
  - `/robots.txt`, `/sitemap-index.xml` + `/sitemap-0.xml`, `/og.png`, `/og/<slug>.png`
  - `/nimbus-api/coordinates.json` (citation manifest), `/404`
- Current structure (17 pages):

```
introduction.mdx
getting-started/{installation,quick-start}.mdx
using-cetas/{cli,acp,automation}.mdx
configuration/{overview,providers,models,cetas-home,mcp}.mdx
concepts/{architecture,surfaces,sessions}.mdx
reference/{overview,configuration,environment-variables}.mdx
```

---

## 5. Sidebar: groups come from **directories**, not frontmatter

This is the single most important thing to know, and it is not obvious from the schema.

A page's `sidebar.group` field only *looks* like it creates a group. It does not — grouping is derived from the **filesystem** (`buildFilesystemTree` in the Nimbus runtime):

- Entries whose id contains a `/` are folded into a group named after the **first path segment**.
- The label is `indexEntry.sidebar.group.label ?? indexEntry.title ?? formatLabel(dirSegment)`.
- With no directory, a page renders as a **flat top-level link**, and a per-page `sidebar.group` is simply ignored.

Written flat with per-page `sidebar.group`, the build still succeeds and every page still appears — but **no group headers render at all**. That failure is silent; only inspecting the HTML reveals it.

Consequences:

| You want | Do this |
| --- | --- |
| A group labelled "Using Cetas" | put those pages in `using-cetas/` — `formatLabel` turns the directory name into the label |
| A different label | add an `index.mdx` in that directory and set `sidebar.group.label` on it |
| Group ordering | the group's order is the **minimum** of its children's `sidebar.order`; with an index page it is that index page's `sidebar.order` |
| No group landing page | `sidebar.group.hideIndex: true` on the directory index |
| A group icon | `sidebar.group.icon` on the directory index |

`introduction.mdx` sits at the root on purpose: it is the lone ungrouped link above the groups.

Ordering is manual — every page carries `sidebar.order` (10, 20, 30, …). Leave gaps so you can insert pages later.

---

## 6. Frontmatter reference

`title` is the only required field. Supported keys (from the generated `.astro/collections/docs.schema.json`):

| Key | Notes |
| --- | --- |
| `title`, `description` | `title` also becomes the page H1 — do not repeat it in the body |
| `slug` | override the route slug |
| `sidebar` | `false` to hide, or `{ order, label, badge, hidden, hideChildren, group: { label, badge, icon, hideIndex } }` |
| `banner` | `{ content, type: note\|tip\|caution\|danger, dismissible: { id, days } }` |
| `tableOfContents` | `false`, or `{ minHeadingLevel, maxHeadingLevel }` (defaults 2..3) |
| `draft`, `noindex`, `searchable` | publish / indexing / search-index controls |
| `prev`, `next` | `false`, a link string, or `{ link, label }` |
| `previousSlug` | redirects from old slugs |
| `socialImage`, `lastUpdated` | per-page OG image and date |
| `external_link` | point the sidebar entry elsewhere |
| `audience: human` | project addition (see `content.config.ts`); flags a page written primarily for human readers |
| `head` | extra `<meta>` / `<link>` / `<script>` tags |
| `nimbusDisableRules` | opt a single file out of specific lint rules |

`lang` comes from `locale`; there is no per-page locale override configured.

---

## 7. Pagefind only works when invoked through the package manager

The search index is built by the Nimbus integration, which spawns the `pagefind` binary. It relies on `node_modules/.bin` being on `PATH` — so:

| Invocation | Result |
| --- | --- |
| `pnpm run build` / `pnpm run verify` | ✅ `Indexed 17 pages, 696 words`, `dist/pagefind/` populated |
| `./node_modules/.bin/astro build` directly | ❌ `'pagefind.cmd' is not recognized … spawn pagefind.cmd ENOENT`, "Pagefind did not run" |

The failure is a **non-fatal warning** — the build still exits `0` and quietly ships a site with no search index. Always drive builds through pnpm.

`data-pagefind-body` is applied by `DocsLayout.astro`; pages marked `searchable: false`, `noindex`, or hidden versions are excluded from indexing.

---

## 8. Known trap: `nimbus-docs check` fails on Windows

`nimbus-docs check` runs four scopes (env, structure, authoring, types). On Windows the **types scope always fails** with 40 errors that do not reflect the project:

```
types  ts/2307  ×39   Cannot find module './X.astro' or its corresponding type declarations.
types  ts/6053  ×1    File '…/__nimbus-astro-shim__.d.ts' not found.
```

All 40 reduce to one cause. The CLI type-checks with a virtual shim that carries `declare module "*.astro"`, injected through a custom compiler host that intercepts by exact string match:

```js
host.getSourceFile = (fileName, …) => fileName === shim ? … : base(fileName, …)
// shim = path.join(cwd, "__nimbus-astro-shim__.d.ts")   → backslashes on Windows
```

TypeScript normalizes root file names to **forward slashes** internally, so the comparison never matches. Reproduced in isolation: the host's intercept path is hit `0` times, and the name it asks for is `E:/Projects/…/__nimbus-astro-shim__.d.ts` while the shim is built as `E:\Projects\…\__nimbus-astro-shim__.d.ts`.

Blast radius: without the shim in the program, `*.astro` imports are unresolvable → 39 × `ts/2307`; the missing root file also yields the `ts/6053`.

Evidence that the project itself is fine: `pnpm run typecheck` reports **0 errors across 99 files**, and the production build passes.

Also verified: this is **not** an artifact of how the CLI is launched — it reproduces under `pnpm exec nimbus-docs check` (correct `PATH`) as well as direct invocation.

Practical consequences:

- Do **not** use `nimbus-docs check` as the convergence gate on Windows. `AGENT.md` tells agents to loop "until `status !== "failed"`" — on Windows that loop cannot terminate, and it points at 40 phantom errors. The loop is only reachable on macOS/Linux.
- Use `pnpm run verify` + `pnpm run lint:docs` as the local gate instead. They actually pass.
- `nimbus-docs lint` is unaffected and works correctly on Windows.
- Worth reporting upstream: compare `path.normalize()`/forward-slash-normalized names, not raw `path.join` output.

The non-types scopes are still useful. Post-build, `check` reports `readiness=buildable` and `authoring` passes (internal-link checking needs the route map a build produces).

---

## 9. Open items

1. **Deployment is live.** The site is served at `https://www.colmugx.top/cetas/`, the Pages custom domain. `https://colmugx.github.io/cetas/` 301s to it — which is exactly why `site` must be the custom-domain origin rather than the `<owner>.github.io` one.
2. **The Pages workflow is confirmed working.** `cetas website` has run green twice: on the pull request, and on the push to `main` three seconds after the merge — the run that published the live site. That covers what could not be verified locally: `pnpm/action-setup@v4`, `actions/configure-pages@v5`, and the `github-pages` environment.
3. **Registry ledger is empty.** `nimbus.json` has `"components": []` even though `src/components/ui/` holds 21 components, so `nimbus-docs outdated` cannot report upstream changes for any of them. Note `AGENT.md`'s rule: add registry components with `nimbus-docs add <slug>`, don't hand-copy them.
4. **One component is unreferenced**: `collapsible` has no reference outside its own directory (`code` is now used by the home page). Drop it or adopt it.
5. **`src/content/partials/` is empty.** `partialsCollection()` is still registered, which is fine — the first `<Render file="…" />` will work — but nothing uses it yet.
6. **The vite `MODULE_LEVEL_DIRECTIVE` warnings are unexplained.** Every `.mdx` content file emits one ("`use astro:head-inject` … may not be preserved when bundling"). Exit code stays `0` and there are no build errors, but nobody has established whether it is benign.

---

## 10. Migration notes (from `website/`)

The previous Astro + Starlight site was replaced, not mirrored. What changed beyond the framework:

- **Automation is `cetas-run`, not `cetas-headless`.** The old docs presented `cetas-headless` as one of three headline surfaces. `cetas-run` is what releases package and what Mooncakes publishes; `cetas-headless` is still in the repository but is not packaged by any release and is not registered by any composition recipe. It now appears only as an explicit caution.
- **Installing Cetas is documented now.** The old installation page asserted that no package-manager install existed; the site now documents the npm package `@posoco/cetas`, the `moonx colmugx/cetas-run` route, and the actual release artifact names (`cetas-bun-*`, `cetas-acp-*`, `cetas-run-*`, plus `SHA256SUMS`).
- **Permission modes corrected.** Five modes (`readonly`, `workspace_write`, `interactive`, `auto`, `yolo`), and the default is `yolo`, not `workspace_write`.
- **`CETAS_HOME` scope corrected.** It overrides the *parent* home for the native, ACP, and runner hosts; the JS terminal host uses the platform home.
- **Zed schema updated** to the current top-level `agent_servers` form.
- **`mcp.json` path fixed** (`~/.cetas/mcp.json`, not a doubled `.cetas/.cetas` path).
- **Added** the transport- and debug-related variables the old reference omitted (`CETAS_MCP_MODE`, `CETAS_DELEGATE_FS`, `CETAS_DEBUG_WIRE`, `CETAS_DEBUG_MCP_CATALOG`, `CETAS_MEMOH_HOME`).
- The old marketing-only pages (hero, download, changelog, architecture diagram components) had no equivalent here and were dropped; their stale `v0.3.2` version pin and `site/` tree entry went with them.

Content is drawn from repository sources — `README.md`, `docs/*.md`, `cetas-run/README.mbt.md`, `composition/recipes.csv`, and the `cetas-core` / `cetas-acp` / `cetas-run` sources — rather than carried over. When the product changes, re-check those first.
