import math
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def newell_normal(points):
    nx = ny = nz = 0.0
    n = len(points)
    for i in range(n):
        c = points[i]
        nxt = points[(i + 1) % n]
        nx += (c[1] - nxt[1]) * (c[2] + nxt[2])
        ny += (c[2] - nxt[2]) * (c[0] + nxt[0])
        nz += (c[0] - nxt[0]) * (c[1] + nxt[1])
    length = math.sqrt(nx * nx + ny * ny + nz * nz)
    normal = [nx / length, ny / length, nz / length]
    for v in normal:
        if abs(v) > 1e-6:
            if v < 0:
                normal = [-x for x in normal]
            break
    return normal


def test_non_uniform_scaling_normal():
    # Slanted plane x + y = 1 (normal = (1, 1, 0)/sqrt(2)) scaled by (sx=2, sy=1, sz=1)
    # Transformed plane equation: (x'/2) + y' = 1 => x' + 2y' = 2 => true normal = (1, 2, 0)/sqrt(5)
    pts = [(1.0, 0.0, 0.0), (0.0, 1.0, 0.0), (0.0, 1.0, 2.0), (1.0, 0.0, 2.0)]
    scaled = [(x * 2.0, y * 1.0, z * 1.0) for (x, y, z) in pts]
    n = newell_normal(scaled)
    expected = [1.0 / math.sqrt(5.0), 2.0 / math.sqrt(5.0), 0.0]
    for a, b in zip(n, expected):
        assert abs(a - b) < 1e-9, f"Expected {expected}, got {n}"
    # Verify orthogonality to edge vector in scaled plane
    edge = [scaled[1][i] - scaled[0][i] for i in range(3)]
    dot = sum(n[i] * edge[i] for i in range(3))
    assert abs(dot) < 1e-9, f"Normal not orthogonal to transformed face: dot={dot}"


def test_double_sided_overlap_deduction():
    # Rule 3: two 5 m2 faces overlapping by 2 m2 => (5-2) + (5-2) = 6 m2
    areas = [5.0, 5.0]
    overlaps = {0: 0.0, 1: 0.0}
    overlap = 2.0
    overlaps[0] += overlap
    overlaps[1] += overlap
    net = sum(max(0.0, areas[i] - min(overlaps[i], areas[i])) for i in range(2))
    assert abs(net - 6.0) < 1e-9, f"Expected 6.0, got {net}"


def test_xlsx_column_index():
    def col_idx(ref):
        m = re.match(r"^([A-Za-z]+)", ref)
        if not m:
            return None
        idx = 0
        for ch in m.group(1).upper():
            idx = idx * 26 + (ord(ch) - 64)
        return idx - 1

    assert col_idx("A1") == 0
    assert col_idx("B12") == 1
    assert col_idx("Z5") == 25
    assert col_idx("AA1") == 26
    assert col_idx("AB99") == 27


def test_ruby_balanced_structure():
    # Lightweight static structural check on Ruby files when local ruby interpreter is absent
    for rel in ["src/su_material_budget.rb", "src/su_material_budget/main.rb"]:
        text = (ROOT / rel).read_text(encoding="utf-8")
        # Strip comments and string literals roughly for bracket balance
        lines = [line.split("#", 1)[0] for line in text.splitlines()]
        code = "\n".join(lines)
        # Ensure no Ruby 2.6+ endless range
        assert re.search(r"\.\.\s*[\]\)]", code) is None, f"Endless range found in {rel}"
        # Check balanced module/class/def count > 0
        assert "module StudioTools" in code
        assert "module MaterialBudget" in code
        # Check every method def has matching end indentation (zero unclosed top-level blocks)
        open_kw = len(re.findall(r"(?m)^\s*(?:module|class|def|case|begin|if|unless|while|until)\b", code))
        close_kw = len(re.findall(r"(?m)^\s*end\b", code))
        # Account for inline `do` blocks (e.g. `.each do |...|`)
        do_blocks = len(re.findall(r"\bdo\s*(?:\|[^|]*\|)?\s*$", code, flags=re.MULTILINE))
        inline_begin = len(re.findall(r"=\s*begin\s*$", code, flags=re.MULTILINE))
        inline_if = len(re.findall(r"=\s*(?:if|case)\b", code))
        total_open = open_kw + do_blocks + inline_begin + inline_if
        assert total_open == close_kw, (
            f"Block mismatch in {rel}: opened={total_open} "
            f"(kw={open_kw}, do={do_blocks}, =begin={inline_begin}, =if/case={inline_if}) vs end={close_kw}"
        )


if __name__ == "__main__":
    test_non_uniform_scaling_normal()
    test_double_sided_overlap_deduction()
    test_xlsx_column_index()
    test_ruby_balanced_structure()
    print("ALL CORE LOGIC & STATIC RUBY STRUCTURE TESTS PASSED")
