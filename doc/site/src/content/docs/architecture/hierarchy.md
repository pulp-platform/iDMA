---
title: Module Hierarchy
description: Generated module-hierarchy graphs for the synthesizable iDMA tops.
---

These graphs are generated from the bender-pickle syntax tree (`util/ast2dot.py`)
for each synthesizable top, so they always reflect the current RTL. Regenerate
them with `make idma_doc_all`, then `make idma_doc_site` copies them into this
site under `public/fig/graph/`.

:::note[Draft]
This page is a starting point for aligning the site with the regenerated
hierarchy graphs - the figures and prose are still being brought up to date with
the latest repository state.
:::

## Backend - `rw_axi`

![idma_backend_synth_rw_axi](/fig/graph/idma_backend_synth_rw_axi.png)

## ND Midend

![idma_nd_midend_synth](/fig/graph/idma_nd_midend_synth.png)

## Descriptor Frontend

![idma_desc64_synth](/fig/graph/idma_desc64_synth.png)
