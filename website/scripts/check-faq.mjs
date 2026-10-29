#!/usr/bin/env bun
/**
 * Post-build assertion: FAQPage JSON-LD exists exactly where the ticket
 * scopes it, parses, and never says anything the page doesn't visibly say.
 *
 * Why this exists: the FAQPage markup is generated from each page's own MDX
 * (src/lib/faq-jsonld.ts) and fails closed — any structural surprise yields
 * "no injection" rather than wrong markup. That is the right product
 * behavior, but it means the feature could silently vanish. This script is
 * the loud half: it audits dist/ after `astro build` and fails the check
 * when a scoped page lost its FAQPage, when the markup drifts from the
 * visible page, or when FAQPage leaks onto any other page.
 *
 * Invariants (all derived from dist/):
 *
 *  1. Exactly the four scoped pages (zh + /en/ mirrors of the two FAQ
 *     articles) each carry exactly one FAQPage script, it JSON.parses, and
 *     it satisfies Google's FAQ required fields (@context, @type,
 *     mainEntity[].name, mainEntity[].acceptedAnswer.text).
 *  2. No other built HTML page carries any FAQPage script, and no page
 *     marked `<meta name="robots" content="noindex">` carries one either.
 *  3. On each scoped page, the marked Q&A pairs equal the page's visible
 *     H2 sections: question text == the <h2 id> text; answer markup == the
 *     HTML between that H2 and the next (compared whitespace-insensitively,
 *     since the markup is generated from the same rendered output).
 *
 * Any violation exits non-zero with a plain-language failure list.
 */
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const websiteRoot = fileURLToPath(new URL("..", import.meta.url));
const dist = join(websiteRoot, "dist");

// Mirrors FAQ_JSONLD_PAGES in src/lib/faq-jsonld.ts (dist-relative page
// paths). Duplicated on purpose: this script audits the built artifacts
// from the outside and must not import app code, so the ticket's scope is
// restated here — any drift between the two lists is a loud failure below,
// not a silent pass.
const FAQ_PAGES = [
  "faq/is-cetas-for-me",
  "faq/how-different",
  "en/faq/is-cetas-for-me",
  "en/faq/how-different",
];

const failures = [];
const check = (condition, message) => {
  if (!condition) failures.push(message);
  return condition;
};

if (!existsSync(dist)) {
  console.error("dist/ not found — run `bun run build` before check:faq");
  process.exit(1);
}

const collapseWhitespace = (s) => s.replace(/\s+/g, "");
const stripTags = (s) => s.replace(/<[^>]*>/g, "");
const LD_SCRIPT_RE = /<script type="application\/ld\+json">([\s\S]*?)<\/script>/g;

function* walkHtmlFiles(dir) {
  for (const name of readdirSync(dir)) {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) yield* walkHtmlFiles(path);
    else if (name.endsWith(".html")) yield path;
  }
}

/** All JSON-LD nodes on the page that parse and declare @type FAQPage. */
function faqScripts(html, rel) {
  const nodes = [];
  for (const match of html.matchAll(LD_SCRIPT_RE)) {
    let parsed;
    try {
      parsed = JSON.parse(match[1].replace(/\\u003c/g, "<"));
    } catch (error) {
      failures.push(`${rel}: a JSON-LD script does not parse: ${error.message}`);
      continue;
    }
    if (parsed?.["@type"] === "FAQPage") nodes.push(parsed);
  }
  return nodes;
}

/** Google Rich Results required fields for FAQPage, as plain-language problems. */
function faqStructureProblems(faq, rel) {
  const problems = [];
  if (faq["@context"] !== "https://schema.org") {
    problems.push(`${rel}: @context must be "https://schema.org"`);
  }
  if (!Array.isArray(faq.mainEntity) || faq.mainEntity.length === 0) {
    return [...problems, `${rel}: mainEntity must be a non-empty array of questions`];
  }
  faq.mainEntity.forEach((question, i) => {
    if (question?.["@type"] !== "Question") {
      problems.push(`${rel}: mainEntity[${i}] @type must be "Question"`);
    }
    if (typeof question?.name !== "string" || question.name.trim() === "") {
      problems.push(`${rel}: mainEntity[${i}] is missing a non-empty question "name"`);
    }
    const answer = question?.acceptedAnswer;
    if (answer?.["@type"] !== "Answer" || typeof answer?.text !== "string" || answer.text.trim() === "") {
      problems.push(`${rel}: mainEntity[${i}] is missing an acceptedAnswer with non-empty text`);
    }
  });
  return problems;
}

/**
 * The Q&A pairs a reader actually sees: H2 sections (content headings carry
 * an id; layout chrome like the TOC label doesn't), each with the markup
 * between it and the next H2 inside the page's <article>. Sections whose
 * body is empty are not a visible question-and-answer pair, matching the
 * extractor's skip rule.
 */
function visibleFaqSections(html, rel) {
  const article = html.match(/<article\b[^>]*>([\s\S]*?)<\/article>/);
  if (!check(article, `${rel}: no <article> content block found`)) return null;
  const content = article[1];
  const h2s = [...content.matchAll(/<h2\b[^>]*\bid="[^"]*"[^>]*>([\s\S]*?)<\/h2>/g)];
  if (!check(h2s.length > 0, `${rel}: no <h2 id="…"> sections found inside <article>`)) return null;
  const sections = [];
  h2s.forEach((match, i) => {
    const start = match.index + match[0].length;
    const next = h2s[i + 1]?.index ?? content.length;
    const answer = content.slice(start, next).trim();
    if (answer) sections.push({ question: stripTags(match[1]), answer });
  });
  return sections;
}

const builtPages = [...walkHtmlFiles(dist)].map((path) => ({
  rel: path.slice(dist.length + 1),
  path,
}));

let totalMarkedPairs = 0;

for (const page of builtPages) {
  const html = readFileSync(page.path, "utf8");
  const slug = page.rel.replace(/(^|\/)index\.html$/, "").replace(/\/$/, "");
  const isScoped = FAQ_PAGES.includes(slug);
  const isNoindex = /<meta name="robots" content="noindex"/.test(html);
  const faqs = faqScripts(html, page.rel);

  // Invariant 2 first: FAQPage is for the four FAQ articles and nothing else,
  // and never for a noindex page.
  if (!isScoped || isNoindex) {
    check(faqs.length === 0, `${page.rel}: must not carry FAQPage JSON-LD (scoped=${isScoped}, noindex=${isNoindex})`);
    continue;
  }

  // Invariant 1: exactly one well-formed FAQPage per scoped page.
  if (!check(faqs.length === 1, `${page.rel}: expected exactly 1 FAQPage script, found ${faqs.length} — did the extractor fail closed?`)) {
    continue;
  }
  const [faq] = faqs;
  failures.push(...faqStructureProblems(faq, page.rel));

  // Invariant 3: the marked pairs are the page's visible H2 sections.
  const sections = visibleFaqSections(html, page.rel);
  if (!sections) continue;
  totalMarkedPairs += faq.mainEntity?.length ?? 0;
  if (!check(Array.isArray(faq.mainEntity) && faq.mainEntity.length === sections.length,
    `${page.rel}: FAQPage marks ${faq.mainEntity?.length ?? 0} Q&A pair(s) but the page visibly shows ${sections.length}`)) {
    continue;
  }
  faq.mainEntity.forEach((question, i) => {
    const section = sections[i];
    if (collapseWhitespace(question?.name ?? "") !== collapseWhitespace(section.question)) {
      failures.push(`${page.rel}: Q&A ${i + 1} question is "${question?.name}" but the page shows "${section.question}"`);
    }
    if (collapseWhitespace(question?.acceptedAnswer?.text ?? "") !== collapseWhitespace(section.answer)) {
      failures.push(`${page.rel}: Q&A ${i + 1} ("${question?.name}") answer markup does not match the page's section body`);
    }
  });
}

for (const slug of FAQ_PAGES) {
  const path = join(dist, slug, "index.html");
  check(existsSync(path), `dist/${slug}/index.html is not built — the scoped FAQ page is missing from dist`);
}

if (failures.length > 0) {
  console.error(`check:faq — ${failures.length} problem(s):`);
  for (const failure of failures) console.error(`  - ${failure}`);
  process.exit(1);
}

console.log(`check:faq — OK: FAQPage JSON-LD on ${FAQ_PAGES.length} pages, ${totalMarkedPairs} Q&A pairs, all matching the visible page content.`);
