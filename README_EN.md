# Material Budget for SketchUp (材算智联)

[中文](./README.md) | English

Material Budget is a SketchUp extension for early-stage architectural and interior design. Pick the materials you want to price with the native eyedropper, and the extension calculates exposed surface area, resolves coplanar overlaps, matches a studio price library, and updates the project budget in real time.

Current version: **v0.9.0 · SketchUp 2020+**

[Download RBZ (v0.9.0)](./su_material_budget_v0.9.0_SU2020_compatible.rbz) · [Source](./src) · [Chinese documentation](./README.md) · [MIT License](./LICENSE)

![Budget dashboard](./assets/budget-dashboard-v0.8.0.png)

## Highlights

- **Eyedropper-driven pricing**: Only materials picked with the native SketchUp eyedropper are priced; selections persist inside the `.skp` model.
- **Accurate transformed geometry**: Recursively traverses groups, components, nested instances, and non-uniformly scaled transformations (using Newell vertex normals).
- **Single-side face accounting**: Counts a face once even when both front and back use the same material.
- **Coplanar overlap deduction**: Subtracts coplanar contact overlap from both contacting surfaces (e.g., two 5 ㎡ faces overlapping by 2 ㎡ yield `(5-2)+(5-2)=6 ㎡`).
- **Excel-free `.xlsx` & CSV price library**: Built-in pure-Ruby `.xlsx` parser works on Windows (including WPS) and macOS without Microsoft Excel installed.
- **Full 5-part cost breakdown**: Displays Material, Labor, Machinery, Management, and Profit totals alongside a live budget usage progress bar.
- **Trustworthy AI mapping (Top-3 cards)**: Recommends Top-3 candidates from the active price library (supports `deepseek-chat` and OpenAI-compatible endpoints) and requires human confirmation before affecting pricing.
- **Model highlight & reversible actions**: Includes material color swatches, one-click **Locate** to highlight faces in SketchUp, plus **Restore Library Price** and **Unlink Mapping** buttons.
- **Toolbar shortcut & large-model performance**: Dedicated SketchUp toolbar button, lazy triangle meshing, 2D projection caching, and throttled progress updates.

## Installation

1. Download [`su_material_budget_v0.9.0_SU2020_compatible.rbz`](./su_material_budget_v0.9.0_SU2020_compatible.rbz).
2. Open SketchUp **Extension Manager** and choose **Install Extension**.
3. Restart SketchUp and click the **Material Budget (材质实时预算)** toolbar icon (or open it from the **Extensions** menu).
4. Link a studio `.xlsx` or `.csv` price library.
5. Keep the dialog open and pick the materials to include with the SketchUp eyedropper.

## Compatibility and Validation

- Targets **SketchUp 2020 and newer** (Ruby 2.5+ and CEF 64 `HtmlDialog` baseline).
- Automated checks pass: `python test_core_logic.py`, `node validate_su2020_compat.mjs`, `node validate_v090.mjs`, and `python validate_v090_package.py`.
- A real SketchUp 2020+ end-to-end run is still recommended before production deployment.

## AI and Data Boundaries

- The API key remains in session memory only and is never written to `.skp`, price files, or exports.
- Geometry, project budgets, `.skp` files, and personal data are never sent to the AI model.
- AI recommends candidates strictly from the active price library; it never invents prices or bypasses human confirmation.

See the [Chinese README](./README.md) for the full nine-generation development history, architecture, FAQ, and known limitations.
