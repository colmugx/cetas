import { defineConfig } from "astro/config";
import tailwindcss from "@tailwindcss/vite";
import nimbus, {
  defineConfig as defineNimbusConfig,
} from "@cloudflare/nimbus-docs";
import { tableScroll } from "@cloudflare/nimbus-docs/markdown";

const nimbusConfig = defineNimbusConfig({
  // Canonical origin, no trailing slash. Drives canonical URLs, absolute OG
  // image URLs, robots.txt, the sitemap, and the links in /llms.txt.
  //
  // Origin only — not the full site URL. The path prefix comes from Astro's
  // `base` below, and Nimbus prefixes its own routes with BASE_URL, so the two
  // together produce `https://www.colmugx.top/cetas/...`.
  //
  // This is the custom domain configured on the Pages site. The
  // `<owner>.github.io` URL 301s here, so it must not be used as the origin:
  // pointed at it, every canonical, sitemap entry and llms.txt link would
  // advertise a redirect.
  site: "https://www.colmugx.top",
  // Used for <title>, the home H1, and OG.
  title: "Cetas",
  // Used for meta + OG.
  description: "A coding agent for your terminal, editor, and scripts.",
  locale: "en",
  github: "https://github.com/colmugx/cetas",
  socialImageAlt: "Cetas documentation preview",
});

export default defineConfig({
  // The site is served under `/cetas/` - the project page keeps its repository
  // path even behind the custom domain - so every generated and authored link
  // needs that prefix. Only `site` (the origin) changes if the domain does.
  base: "/cetas/",
  // nimbus:adapter
  output: "static",
  // Tailwind v4 via its Vite plugin (the integration Astro recommends for
  // Tailwind v4 — replaces the PostCSS plugin, which doesn't build under
  // Astro 7's Vite 8 bundler).
  vite: {
    plugins: [tailwindcss()],
  },
  // Hover-prefetch link targets so full-page navigations feel instant without
  // a client-side router.
  prefetch: {
    prefetchAll: true,
    defaultStrategy: "hover",
  },
  integrations: [
    nimbus(nimbusConfig, {
      // Authoring rules are opt-in by design — your repo, your taste. The
      // two below are the load-bearing pair: frontmatter has to validate
      // against the content schema for the page to render properly, and
      // broken internal links are 404s for your readers. Add the others
      // (heading hierarchy, code-block language, style, etc.) when you're
      // ready to enforce them — see `nimbus-docs lint --help`.
      rules: {
        "nimbus/frontmatter-shape": "error",
        "nimbus/internal-link": "error",
      },
      // Wrap wide tables so they scroll instead of overflowing the page
      // (styled by `.nb-table-scroll` in src/styles/prose.css).
      markdown: {
        hastPlugins: [tableScroll()],
      },
    }),
  ],
});
