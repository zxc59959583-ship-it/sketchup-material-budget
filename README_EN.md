# Material Budget for SketchUp

[中文](./README.md) | English

Material Budget is a SketchUp extension for early-stage architectural and interior design. Pick the materials you want to price, and the extension calculates exposed surface area, resolves coplanar overlaps, matches a studio price library, and updates the project budget.

Current version: **v0.8.0 · SketchUp 2020+**

[Download RBZ](./su_material_budget_v0.8.0_SU2020_compatible.rbz) · [Source](./src) · [Chinese documentation](./README.md)

![Budget dashboard](./assets/budget-dashboard-v0.8.0.png)

## Highlights

- Pick materials with the native SketchUp eyedropper; only picked materials are priced.
- Traverse groups, components, nested instances, and scaled transformations.
- Count a face once when its front and back use the same material.
- Subtract coplanar overlap from both contacting surfaces.
- Link an Excel/CSV price library with codes, names, aliases, cost components, dates, and sources.
- Show current cost, baseline delta, total project budget, and remaining budget.
- Use DeepSeek only to recommend candidates from the current price library.
- Require human confirmation before an AI-assisted mapping affects pricing.
- Persist confirmed mappings to both the active model and the studio dictionary.
- Export complete UTF-8 CSV results and mapping audit history.

## Installation

1. Download the RBZ package.
2. Open SketchUp Extension Manager and choose **Install Extension**.
3. Restart SketchUp and open **Material Budget**.
4. Link a studio Excel/CSV price library.
5. Keep the dialog open and pick the materials to include.

## Compatibility and validation

The source targets SketchUp 2020 and newer. SketchUp 2020 uses Ruby 2.5 and an older CEF-based HtmlDialog, so Ruby 2.7-only `filter_map`, JavaScript `replaceAll`, and optional chaining are not used.

Static compatibility and package checks pass. A real SketchUp 2020 end-to-end run is still recommended before production deployment.

## AI and data boundaries

- The API key remains in memory for the current SketchUp session.
- Geometry, project budget, SKP files, and personal data are not sent to DeepSeek.
- AI recommends candidates but does not calculate geometry or create prices.
- Final mappings require a human decision and are recorded for review.

See the [Chinese README](./README.md) for the full eight-generation development history, workflow, screenshots, tests, FAQ, and known limitations.
