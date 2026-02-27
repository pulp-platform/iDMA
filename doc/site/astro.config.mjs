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
            { label: 'Backend', slug: 'architecture/backend' },
            { label: 'Midend', slug: 'architecture/midend' },
            {
              label: 'Frontend',
              items: [
                { label: 'Overview', slug: 'architecture/frontend' },
                { label: 'Register Frontend', slug: 'architecture/frontend/register' },
                { label: 'Snitch Frontend', slug: 'architecture/frontend/snitch' },
                { label: 'Descriptor Frontend', slug: 'architecture/frontend/descriptor' },
              ],
            },
          ],
        },
        {
          label: 'Guides',
          items: [
            { label: 'System Integration', slug: 'guides/system-integration' },
            { label: 'Error Handling', slug: 'guides/error-handling' },
            { label: 'Verification', slug: 'guides/verification' },
          ],
        },
      ],
    }),
  ],
});
