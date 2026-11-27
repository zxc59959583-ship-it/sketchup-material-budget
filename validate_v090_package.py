import json
import re
from pathlib import Path
from zipfile import ZipFile

package = Path(__file__).resolve().parent / "su_material_budget_v0.9.0_SU2020_compatible.rbz"
with ZipFile(package) as archive:
    names = sorted(archive.namelist())
    loader = archive.read("su_material_budget.rb").decode("utf-8")
    main = archive.read("su_material_budget/main.rb").decode("utf-8")
    html = archive.read("su_material_budget/dialog_v07.html").decode("utf-8")
    icon = archive.read("su_material_budget/toolbar_icon.svg").decode("utf-8")

    result = {
        "zip_ok": archive.testzip() is None,
        "entries": names,
        "no_legacy_dialog": "su_material_budget/dialog.html" not in names,
        "version_090": "0.9.0" in loader and "v0.9.0" in html and "v0.9.0" in main,
        "sketchup_2020_guard": "MINIMUM_SKETCHUP_VERSION = 20" in loader,
        "ruby_25_compatible": (
            ".filter_map" not in main
            and re.search(r"\.\.\s*[\]\)]", main) is None
        ),
        "cef_64_compatible": (
            "replaceAll(" not in html
            and "?." not in html
            and "??" not in html
        ),
        "pure_ruby_xlsx": "rows_from_xlsx_pure_ruby" in main,
        "lazy_meshing": "projected_triangles_for" in main,
        "progress_throttle": "PROGRESS_THROTTLE_SECONDS" in main,
        "top3_ai_cards": "ai-candidate" in html,
        "highlight_and_revert": (
            "highlight_material_in_model" in main
            and "clear_material_price" in main
            and "remove_material_mapping" in main
        ),
        "toolbar_icon": (
            "<svg" in icon
            and "su_material_budget/toolbar_icon_24.png" in names
            and "su_material_budget/toolbar_icon_64.png" in names
            and "UI::Toolbar.new" in main
            and "@toolbar.show" in main
        ),
        "no_hardcoded_local_path": "E:/建筑材质插件" not in main,
    }
    print(json.dumps(result, indent=2, ensure_ascii=False))
    failed = [k for k, v in result.items() if v is False]
    if failed:
        raise SystemExit(f"Package validation failed: {failed}")
