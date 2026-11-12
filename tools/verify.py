"""静态自检：Swift 语法 + plist + YAML + JSON 资源。用法: py tools/verify.py"""
from __future__ import annotations

import json
import plistlib
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
failures = []


def ok(name: str, detail: str = "") -> None:
    print(f"PASS  {name} {detail}")


def bad(name: str, detail: str) -> None:
    failures.append(f"{name}: {detail}")
    print(f"FAIL  {name} {detail}")


# 1) Swift 语法
try:
    from tree_sitter import Language, Parser
    import tree_sitter_swift as tss

    lang = Language(tss.language())
    try:
        parser = Parser(lang)
    except TypeError:
        parser = Parser()
        parser.set_language(lang)

    def walk(node, out):
        if node.type == "ERROR" or node.is_missing:
            out.append(node)
        for child in node.children:
            walk(child, out)

    for path in sorted((ROOT / "ios" / "Sources").glob("*.swift")):
        src = path.read_bytes()
        tree = parser.parse(src)
        errors = []
        walk(tree.root_node, errors)
        if errors:
            line = src[: errors[0].start_byte].count(b"\n") + 1
            bad(f"swift {path.name}", f"line {line}: {errors[0].type}")
        else:
            ok(f"swift {path.name}", f"{len(src.splitlines())} lines")
except ImportError:
    print("SKIP  swift 语法（缺 tree-sitter，可 py -m pip install tree-sitter tree-sitter-swift）")

# 2) Info.plist
plist_path = ROOT / "ios" / "Support" / "Info.plist"
try:
    with plist_path.open("rb") as fh:
        plist = plistlib.load(fh)
    required = ["CFBundleIdentifier", "CFBundleExecutable", "UIFileSharingEnabled",
                "LSSupportsOpeningDocumentsInPlace", "UILaunchScreen"]
    missing = [k for k in required if k not in plist]
    if missing:
        bad("Info.plist", f"缺少 {missing}")
    else:
        ok("Info.plist", f"{len(plist)} keys")
except Exception as exc:  # noqa: BLE001
    bad("Info.plist", str(exc))

# 3) YAML
try:
    import yaml

    for path in [ROOT / "ios" / "project.yml", ROOT / ".github" / "workflows" / "ios.yml"]:
        try:
            data = yaml.safe_load(path.read_text(encoding="utf-8"))
            if not isinstance(data, dict) or not data:
                raise ValueError("空文档")
            ok(f"yaml {path.name}", f"{len(data)} 顶层键")
        except Exception as exc:  # noqa: BLE001
            bad(f"yaml {path.name}", str(exc))
except ImportError:
    print("SKIP  yaml（缺 PyYAML）")

# 4) JSON 资源
for path in (ROOT / "ios" / "Sources").rglob("Contents.json"):
    try:
        json.loads(path.read_text(encoding="utf-8"))
        ok(f"json {path.parent.name}/Contents.json")
    except Exception as exc:  # noqa: BLE001
        bad(f"json {path}", str(exc))

# 5) 图标
icon = ROOT / "ios" / "Sources" / "Assets.xcassets" / "AppIcon.appiconset" / "icon-1024.png"
if icon.exists() and icon.stat().st_size > 2000:
    ok("AppIcon 1024", f"{icon.stat().st_size} bytes")
else:
    bad("AppIcon 1024", "缺失或过小")

print()
if failures:
    print(f"{len(failures)} 项失败：")
    for item in failures:
        print("  -", item)
    sys.exit(1)
print("全部自检通过")
