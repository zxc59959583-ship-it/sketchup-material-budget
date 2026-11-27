from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED

ROOT = Path(__file__).resolve().parent
SRC = ROOT / "src"
OUT = ROOT / "su_material_budget_v0.9.0_SU2020_compatible.rbz"

FILES = [
    SRC / "su_material_budget.rb",
    SRC / "su_material_budget" / "main.rb",
    SRC / "su_material_budget" / "dialog_v07.html",
    SRC / "su_material_budget" / "materials.json",
    SRC / "su_material_budget" / "toolbar_icon.svg",
    SRC / "su_material_budget" / "toolbar_icon_24.png",
    SRC / "su_material_budget" / "toolbar_icon_64.png",
]

for file_path in FILES:
    if not file_path.is_file():
        raise FileNotFoundError(f"Missing required source file: {file_path}")

with ZipFile(OUT, "w", compression=ZIP_DEFLATED, compresslevel=9) as archive:
    for file_path in FILES:
        arcname = file_path.relative_to(SRC).as_posix()
        archive.write(file_path, arcname)

print(f"Built {OUT.name} ({OUT.stat().st_size} bytes, {len(FILES)} files)")
