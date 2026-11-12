"""Swift 语法自检（tree-sitter，不依赖 Xcode）。用法: py tools/check_swift.py"""
from __future__ import annotations

import sys
from pathlib import Path

from tree_sitter import Language, Parser

import tree_sitter_swift as tss

ROOT = Path(__file__).resolve().parent.parent
lang = Language(tss.language())

try:
    parser = Parser(lang)
except TypeError:  # 旧版 API
    parser = Parser()
    parser.set_language(lang)


def walk(node, out):
    if node.type == "ERROR" or node.is_missing:
        out.append(node)
    for child in node.children:
        walk(child, out)


bad = 0
for path in sorted((ROOT / "ios" / "Sources").glob("*.swift")):
    src = path.read_bytes()
    tree = parser.parse(src)
    errors = []
    walk(tree.root_node, errors)
    if errors:
        bad += 1
        print(f"FAIL {path.name}")
        for node in errors[:5]:
            line = src[: node.start_byte].count(b"\n") + 1
            snippet = src[node.start_byte: node.end_byte][:120].decode("utf-8", "replace")
            print(f"   line {line}: {node.type} -> {snippet!r}")
    else:
        print(f"PASS {path.name}  ({len(src.splitlines())} lines)")

print(f"\n{len(list((ROOT / 'ios' / 'Sources').glob('*.swift')))} files, {bad} with syntax errors")
sys.exit(1 if bad else 0)
