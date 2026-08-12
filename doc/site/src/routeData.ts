// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

import { defineRouteMiddleware } from '@astrojs/starlight/route-data';

// Show a site-wide WIP banner on every page unless a page opts out via its own
// `banner` frontmatter.
export const onRequest = defineRouteMiddleware((context) => {
  const { starlightRoute } = context.locals;
  if (!starlightRoute.entry.data.banner) {
    starlightRoute.entry.data.banner = {
      content:
        'WIP: parts of this documentation are AI-generated and may contain factual errors.',
    };
  }
});
