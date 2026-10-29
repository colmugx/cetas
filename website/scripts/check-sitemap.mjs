#!/usr/bin/env bun
/**
 * Post-build assertion: the generated sitemap must agree with robots.txt and
 * cover exactly the published pages.
 *
 * Why this exists: the sitemap integration is registered inside
 * @cloudflare/nimbus-docs (pinned @astrojs/sitemap), not in astro.config.ts,
 * so nothing in the repo itself guards it. If a future nimbus upgrade or
 * config change silently drops the sitemap, emits the wrong origin, or
 * double-prefixes URLs under the /cetas/ base, this check fails the build
 * instead of letting robots.txt advertise a dead or wrong sitemap.
 *
 * Invariants (all derived from dist/ after `astro build`):
 *
 *  1. dist/robots.txt declares exactly one Sitemap line, pointing at
 *     <origin>/cetas/sitemap-index.xml (the base is pinned to /cetas/ — this
 *     is a GitHub Pages project page; see astro.config.ts).
 *  2. dist/sitemap-index.xml exists, lists at least one shard, and every
 *     shard URL shares the declared prefix and exists as a file in dist.
 *  3. Every <loc> across shards is an absolute URL under that prefix, unique,
 *     with a trailing slash (these are HTML pages, not endpoints), and none
 *     is robots.txt / llms.txt / a sitemap file itself.
 *  4. The sitemap's URL set equals the set of built HTML pages, minus the
 *     404 page and minus pages carrying `<meta name="robots" content="noindex">`
 *     (both are excluded from the sitemap by design: draft pages are not
 *     rendered at all, noindex pages render but are skipped here).
 *
 * Any violation exits non-zero with a plain-language failure list.
 */
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const websiteRoot = fileURLToPath(new URL("..", import.meta.url));
const dist = join(websiteRoot, "dist");

const failures = [];
const check = (condition, message) => {
  if (!condition) failures.push(message);
  return condition;
};

if (!existsSync(dist)) {
  console.error("dist/ not found — run `bun run build` before check:sitemap");
  process.exit(1);
}

// 1. robots.txt declares the sitemap the site actually ships.
const robotsPath = join(dist, "robots.txt");
const robots = existsSync(robotsPath) ? readFileSync(robotsPath, "utf8") : "";
const sitemapLines = robots
  .split("\n")
  .map((line) => line.trim())
  .filter((line) => /^sitemap:/i.test(line));
if (!check(sitemapLines.length === 1, `dist/robots.txt must declare exactly one Sitemap line, found ${sitemapLines.length}`)) {
  report();
}
const declared = new URL(sitemapLines[0].slice("Sitemap:".length).trim());
const basePrefix = declared.href.replace(/sitemap-index\.xml$/, "");
check(basePrefix.startsWith("https://") && basePrefix.endsWith("/cetas/"), `Sitemap URL must be an https URL under the /cetas/ base, got ${declared.href}`);
check(declared.href === `${basePrefix}sitemap-index.xml`, `Sitemap line must point at sitemap-index.xml, got ${declared.href}`);

// 2. The index exists and its shards are real files under the same prefix.
const indexPath = join(dist, "sitemap-index.xml");
check(existsSync(indexPath), "dist/sitemap-index.xml is missing (sitemap not generated)");
const shardUrls = existsSync(indexPath)
  ? [...readFileSync(indexPath, "utf8").matchAll(/<loc>([^<]+)<\/loc>/g)].map((match) => match[1])
  : [];
check(shardUrls.length >= 1, "sitemap-index.xml lists no shard file");
// Without a structurally valid robots/index pair every coverage message below
// would repeat the same root cause — stop here and surface it directly.
if (failures.length > 0) report();

const urls = [];
for (const shardUrl of shardUrls) {
  let parsed;
  try {
    parsed = new URL(shardUrl);
  } catch {
    failures.push(`sitemap-index.xml shard is not an absolute URL: ${shardUrl}`);
    continue;
  }
  if (!check(parsed.href.startsWith(basePrefix), `shard URL outside the declared prefix: ${shardUrl}`)) continue;
  const shardFile = join(dist, decodeURIComponent(parsed.href.slice(basePrefix.length)));
  if (!check(existsSync(shardFile), `shard listed in sitemap-index.xml is missing from dist: ${parsed.href}`)) continue;
  for (const match of readFileSync(shardFile, "utf8").matchAll(/<loc>([^<]+)<\/loc>/g)) urls.push(match[1]);
}

// 3. Per-URL invariants.
const sitemapUrls = new Set();
for (const raw of urls) {
  let parsed;
  try {
    parsed = new URL(raw);
  } catch {
    failures.push(`sitemap entry is not an absolute URL: ${raw}`);
    continue;
  }
  check(parsed.href.startsWith(basePrefix), `sitemap entry without the ${basePrefix} prefix: ${raw}`);
  check(!parsed.href.includes("/cetas/cetas/"), `sitemap entry double-prefixes the base: ${raw}`);
  check(parsed.pathname.endsWith("/"), `sitemap entry is not an HTML page (no trailing slash): ${raw}`);
  check(
    !/\/(robots\.txt|llms\.txt|llms-full\.txt|sitemap-index\.xml|sitemap-\d+\.xml)$/i.test(parsed.pathname),
    `sitemap must not list generated endpoints: ${raw}`,
  );
  if (sitemapUrls.has(parsed.href)) failures.push(`duplicate sitemap entry: ${raw}`);
  sitemapUrls.add(parsed.href);
}

// 4. The sitemap covers exactly the published pages.
function* htmlFiles(dir) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) {
      if (entry.name === "pagefind") continue; // search index, not site pages
      yield* htmlFiles(path);
    } else if (entry.name.endsWith(".html")) {
      yield path;
    }
  }
}

const expectedUrls = new Map();
for (const file of htmlFiles(dist)) {
  const rel = relative(dist, file);
  if (rel === "404.html" || rel.endsWith("/404.html")) continue; // never in a sitemap
  if (/<meta\s+name="robots"\s+content="noindex/i.test(readFileSync(file, "utf8"))) continue; // published, but deliberately unlisted
  const path = rel === "index.html" ? "" : rel.replace(/index\.html$/, "");
  expectedUrls.set(`${basePrefix}${path}`, rel);
}

for (const url of sitemapUrls) {
  check(expectedUrls.has(url), `sitemap lists a URL with no published page: ${url}`);
}
for (const [url, file] of expectedUrls) {
  check(sitemapUrls.has(url), `published page missing from the sitemap: ${file} (${url})`);
}

function report() {
  if (failures.length > 0) {
    console.error(`check:sitemap — ${failures.length} problem(s):`);
    for (const failure of failures) console.error(`  - ${failure}`);
    process.exit(1);
  }
  console.log(`check:sitemap — ok: ${declared.href} → ${shardUrls.length} shard(s), ${urls.length} unique URLs, ${expectedUrls.size} published pages covered`);
  process.exit(0);
}

report();
