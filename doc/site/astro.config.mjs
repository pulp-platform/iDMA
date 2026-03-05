import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

export default defineConfig({
  integrations: [
    starlight({
      title: 'iDMA Documentation',
      social: {
        github: 'https://github.com/pulp-platform/iDMA',
      },
      sidebar: [
        {
          label: 'Overview',
          slug: '',
        },
        {
          label: 'Architecture',
          items: [
            { label: 'Programming Model', slug: 'architecture/programming-model' },
            { label: 'Interfaces and Types', slug: 'architecture/interfaces' },
            {
              label: 'Frontend',
              items: [
                { label: 'Overview', slug: 'architecture/frontend' },
                { label: 'Register Frontend', slug: 'architecture/frontend/register' },
                { label: 'Snitch Frontend', slug: 'architecture/frontend/snitch' },
                { label: 'Descriptor Frontend', slug: 'architecture/frontend/descriptor' },
              ],
            },
            { label: 'Midend', slug: 'architecture/midend' },
            { label: 'Backend', slug: 'architecture/backend' },
          ],
        },
        {
          label: 'Guides',
          items: [
            { label: 'Quickstart', slug: 'guides/quickstart' },
            { label: 'System Integration', slug: 'guides/system-integration' },
            { label: 'Error Handling', slug: 'guides/error-handling' },
            { label: 'Verification', slug: 'guides/verification' },
            { label: 'Performance and Limitations', slug: 'guides/performance-limitations' },
            { label: 'Docs Verification Plan', slug: 'guides/docs-verification' },
          ],
        },
      ],
    }),
  ],
});
