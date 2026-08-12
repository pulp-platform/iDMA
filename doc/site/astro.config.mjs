// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

export default defineConfig({
  site: 'https://pulp-platform.github.io',
  base: '/iDMA',
  integrations: [
    starlight({
      title: 'iDMA Documentation',
      // Site-wide WIP banner, injected into every page's route data.
      routeMiddleware: './src/routeData.ts',
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
            { label: 'Compute', slug: 'architecture/compute' },
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
