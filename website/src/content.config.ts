import { defineCollection } from "astro:content";
// `z` re-exported from `astro:content` is deprecated; import it from
// `astro/zod` (the pattern nimbus-docs' own schema helpers document).
import { z } from "astro/zod";
import { docsCollection, partialsCollection } from "@cloudflare/nimbus-docs/content";

/**
 * Two page collections, one per locale:
 *
 * - `docs` is the primary collection and owns the root paths. It carries the
 *   Chinese site, which is the default (`/introduction/`).
 * - `en` mounts under `/en` (Nimbus derives the mount from the collection
 *   name) and carries the English site (`/en/introduction/`).
 *
 * Both use the same schema, so a page can be translated by copying its
 * frontmatter keys. Slugs are identical across the two collections, which is
 * what lets the header language switch map a page to its translation by
 * swapping the leading `/en`.
 */
const schemaFields = {
  // Nimbus docs are agent-friendly by default. Set `audience: human`
  // to flag a page that's written primarily for human readers.
  audience: z.literal("human").optional(),
};

export const collections = {
  docs: defineCollection(docsCollection({ schemaFields })),
  en: defineCollection(docsCollection({ base: "en", schemaFields })),
  partials: defineCollection(partialsCollection()),
};
