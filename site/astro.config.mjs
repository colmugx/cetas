import { defineConfig } from 'astro/config';
import solid from '@astrojs/solid-js';
import starlight from '@astrojs/starlight';
import tailwindcss from '@tailwindcss/vite';

export default defineConfig({
  output: 'static',
  integrations: [
    solid(),
    starlight({
      title: 'Cetas',
      description: 'One agent. Every surface.',
      social: [
        {
          icon: 'github',
          label: 'GitHub',
          href: 'https://github.com/colmugx/cetas',
        },
      ],
      customCss: ['./src/styles/docs.css'],
      sidebar: [
        {
          label: 'Getting Started',
          items: [
            { label: 'Introduction', link: '/docs/' },
            { label: 'Installation', link: '/docs/installation/' },
            { label: 'Quick Start', link: '/docs/getting-started/' },
          ],
        },
        {
          label: 'Using Cetas',
          items: [
            { label: 'CLI', link: '/docs/cli/' },
            { label: 'ACP / Zed', link: '/docs/acp/' },
            { label: 'Headless', link: '/docs/headless/' },
          ],
        },
        {
          label: 'Configuration',
          items: [
            { label: 'Overview', link: '/docs/configuration/' },
            { label: 'Providers', link: '/docs/configuration/providers/' },
            { label: 'Models', link: '/docs/configuration/models/' },
            { label: 'Cetas Home', link: '/docs/configuration/cetas-home/' },
            { label: 'MCP', link: '/docs/mcp/' },
          ],
        },
        {
          label: 'Concepts',
          items: [
            { label: 'Architecture', link: '/docs/architecture/' },
            { label: 'Surfaces', link: '/docs/surfaces/' },
            { label: 'Sessions', link: '/docs/sessions/' },
          ],
        },
        {
          label: 'Reference',
          items: [
            { label: 'Reference', link: '/docs/reference/' },
            { label: 'Configuration Reference', link: '/docs/reference/configuration/' },
            { label: 'Environment Variables', link: '/docs/reference/environment-variables/' },
          ],
        },
      ],
    }),
  ],
  vite: {
    plugins: [tailwindcss()],
  },
});
