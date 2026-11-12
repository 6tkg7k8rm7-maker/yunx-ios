"""打包 iOS 工程 zip（条目正斜杠，跨平台解压正常）。用法: py tools/build_zip.py"""
from __future__ import annotations

import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT.parent / "YunX-iOS.zip"
SKIP_DIRS = {"__pycache__", ".git", "build", "DerivedData", "Payload"}
SKIP_SUFFIX = {".pyc", ".log", ".ipa"}

files = []
for path in sorted(ROOT.rglob("*")):
    if path.is_dir():
        continue
    rel = path.relative_to(ROOT)
    if any(part in SKIP_DIRS for part in rel.parts):
        continue
    if path.suffix in SKIP_SUFFIX:
        continue
    files.append(rel)

with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
    for rel in files:
        zf.write(ROOT / rel, f"YunX-iOS/{rel.as_posix()}")

print(f"{OUT}  {OUT.stat().st_size / 1024:.0f} KB  {len(files)} files")
for rel in files:
    print("  ", rel.as_posix())
