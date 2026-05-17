---
title: Docs Verification Plan
description: Quality checks to ensure iDMA docs are accurate, complete, and usable.
---

## Docs QA Overview

This plan defines how we verify documentation quality. It complements the RTL verification guide and focuses on correctness, clarity, and navigability of the docs.

## Build Checks

Run the docs build and fail on warnings:

```bash
cd doc/site
npm run build
```

## Consistency Checklist

- All parameter tables include descriptions.
- All interface fields are defined and explained.
- No unresolved TODOs or “TBD” remain without a clear status.
- All links and image references resolve.

## Snippet Rule

Every code block must be preceded by a paragraph explaining the intent, context, and expected outcome. This prevents code dumps without guidance.

## Diagram Coverage

Each major section should include a diagram or a visible placeholder box describing the intended figure and its educational purpose.

## Accuracy Review

Review key claims against the top-level interface definitions and integration examples. Avoid copying RTL structure into documentation; describe behavior and constraints instead.

## Final Readability Pass

Check for terminology consistency and avoid ambiguities in terms like “decouple,” “couple,” and “legalize.”
