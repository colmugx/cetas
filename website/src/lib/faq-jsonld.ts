/**
 * FAQPage JSON-LD — extracted at render time from the page's own MDX body.
 *
 * Single source of truth: the question text and the answer markup are never
 * copied anywhere — not into a component, not into frontmatter. The route
 * hands us the page's already-compiled `<Content />` component plus its
 * heading list (both from `getDocsPage`/`getCollectionPageProps`), and we
 * render that same component through Astro's own container API and slice
 * the result between H2 boundaries:
 *
 *   - Question = the visible text of an H2 section heading;
 *   - Answer   = the section's rendered HTML up to the next H2 — the same
 *     markup the page displays, so inline links ship as the equivalent
 *     HTML links and lists stay lists. Because the slice is taken from the
 *     page's own rendered output, the JSON-LD cannot drift from what a
 *     visitor (or Google) sees on the page.
 *
 * Everything that would endanger that guarantee fails closed to "no
 * injection" — the ticket's rule: better no FAQPage than one that disagrees
 * with the page. Fails closed on: pages outside the scoped set, zero
 * extractable Q&A pairs, or any structural mismatch between the heading
 * list and the rendered H2s. (`scripts/check-faq.mjs` audits the built dist
 * and fails loudly if extraction ever silently yields nothing for a scoped
 * page.)
 *
 * Scope: exactly the two FAQ articles and their /en/ mirrors — FAQPage must
 * not leak onto any other docs page. `faqJsonLdHead` additionally gates on
 * crawlability (noindex / draft / hidden version) with the same predicate
 * as DocsLayout's BreadcrumbList block: rich-result markup never ships on
 * non-crawlable pages. The block rides the same `head` channel, so it
 * coexists with the breadcrumb and NimbusHead nodes as its own
 * `<script type="application/ld+json">` tag in <head>.
 */
import mdxRenderer from "@astrojs/mdx/server.js";
import { experimental_AstroContainer as AstroContainer } from "astro/container";
import { getVersionStatus } from "@cloudflare/nimbus-docs/runtime";
import type { HeadElement } from "@cloudflare/nimbus-docs/types";

/** The compiled MDX `<Content />` component, as the container accepts it. */
type AstroContentComponent = Parameters<typeof AstroContainer.renderToString>[0];

/** `${collection}:${entryId}` of every page that may carry FAQPage JSON-LD. */
const FAQ_JSONLD_PAGES: ReadonlySet<string> = new Set([
  "docs:faq/is-cetas-for-me",
  "docs:faq/how-different",
  "en:faq/is-cetas-for-me",
  "en:faq/how-different",
]);

interface FaqHeading {
  depth: number;
  text: string;
}

/** The slice of a docs entry the FAQ extraction needs. */
interface FaqEntryRef {
  collection: string;
  id: string;
  data: {
    noindex?: boolean;
    draft?: boolean;
  };
}

export interface FaqJsonLdPageInput {
  entry: FaqEntryRef;
  /** Headings of the rendered MDX body, from the page props. */
  headings: readonly FaqHeading[];
  /** The page's compiled MDX component, from the page props. */
  Content: AstroComponentFactory;
  /** The MDX component mapping the page renders with (`src/components.ts`). */
  components: Record<string, unknown>;
}

/**
 * The `head` extras carrying this page's FAQPage JSON-LD — `[]` when the
 * page must not carry the block (out of scope, non-crawlable, or nothing
 * extractable). Both docs routes spread it onto the layout's `head` prop:
 *
 *     const headExtras = [...entry.data.head, ...await faqJsonLdHead({ entry, headings, Content, components })];
 */
export async function faqJsonLdHead(input: FaqJsonLdPageInput): Promise<HeadElement[]> {
  const { entry } = input;
  const versionStatus = await getVersionStatus(entry.collection);
  const isCrawlable = !entry.data.noindex && !entry.data.draft && !versionStatus?.isHidden;
  if (!isCrawlable) return [];

  const faqJsonLd = await buildFaqPageJsonLd({
    collection: entry.collection,
    entryId: entry.id,
    headings: input.headings,
    Content: input.Content,
    components: input.components,
  });
  if (!faqJsonLd) return [];

  // Escape `<` so no answer markup can close the script tag early
  // (`</script>` break-out); `\u003c` is a legal JSON escape that decodes
  // back to `<` on parse. Same one-liner DocsLayout applies to its
  // BreadcrumbList block.
  return [
    {
      tag: "script",
      attrs: { type: "application/ld+json" },
      content: faqJsonLd.replace(/</g, "\\u003c"),
    },
  ];
}

export interface FaqEntry {
  question: string;
  answer: string;
}

async function buildFaqPageJsonLd(input: {
  collection: string;
  entryId: string;
  headings: readonly FaqHeading[];
  Content: AstroComponentFactory;
  components: Record<string, unknown>;
}): Promise<string | null> {
  if (!FAQ_JSONLD_PAGES.has(`${input.collection}:${input.entryId}`)) return null;

  const html = await renderContentHtml(input.Content, input.components);
  const entries = extractFaqEntries(html, input.headings);
  if (entries.length === 0) return null;

  return JSON.stringify({
    "@context": "https://schema.org",
    "@type": "FAQPage",
    mainEntity: entries.map(({ question, answer }) => ({
      "@type": "Question",
      name: question,
      acceptedAnswer: { "@type": "Answer", text: answer },
    })),
  });
}

async function renderContentHtml(
  Content: AstroComponentFactory,
  components: Record<string, unknown>,
): Promise<string> {
  // MDX content renders through Astro's JSX runtime, which an on-demand
  // container only knows about once handed the renderer (the container
  // docs' "adding a renderer manually" recipe — the `astro:container`
  // virtual module is not available inside a build).
  const container = await AstroContainer.create();
  container.addServerRenderer({ renderer: mdxRenderer });
  // The components prop is the same mapping the routes pass to
  // `<Content />`, so this is the page's own rendering, byte for byte.
  return container.renderToString(Content, { props: { components } });
}

function extractFaqEntries(html: string, headings: readonly FaqHeading[]): FaqEntry[] {
  const questions = headings.filter((heading) => heading.depth === 2).map((h) => h.text);
  const renderedH2s = [...html.matchAll(/<h2\b[^>]*>[\s\S]*?<\/h2>/g)];
  // Both lists describe the same rendered document; if they ever disagree,
  // the markup and the page could too — inject nothing instead.
  if (renderedH2s.length !== questions.length) return [];

  const entries: FaqEntry[] = [];
  renderedH2s.forEach((match, index) => {
    const start = (match.index ?? 0) + match[0].length;
    const nextStart = renderedH2s[index + 1]?.index;
    const answer = html.slice(start, nextStart ?? html.length).trim();
    // An H2 with no body is not a visible question-and-answer pair.
    if (!answer) return;
    entries.push({ question: questions[index], answer });
  });
  return entries;
}
