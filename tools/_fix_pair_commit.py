#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Remove {function_rime_clear} from the 8 pair-punctuation action definitions.
Full-width pair (上滑) => 顶字上屏 (text: commits composition + {Left} cursor).
Half-width pair (下滑) => 直接上屏 (text: direct insert, no clear; cursor kept).
Only touches lines whose key is one of the 8 pair action names.
Preserves LF line endings.
"""
import io, sys

PAIR_NAMES = [
    "pair_fullquote", "pair_halfquote", "pair_bracket", "pair_booktitle",
    "down_halfbracket", "down_halfquotationmark", "down_halfsemiquotationmark",
    "down_angledbracket",
]

def fix(path):
    with io.open(path, "r", encoding="utf-8", newline="") as f:
        data = f.read()
    lines = data.split("\n")
    changed = []
    for i, line in enumerate(lines):
        stripped = line.lstrip()
        for name in PAIR_NAMES:
            if stripped.startswith(name + ":"):
                if "{function_rime_clear}" in line:
                    new = line.replace("{function_rime_clear}", "", 1)
                    lines[i] = new
                    changed.append((i + 1, name))
                break
    out = "\n".join(lines)
    with io.open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(out)
    # report
    print(f"[{path}] changed {len(changed)} lines:")
    for ln, nm in changed:
        print(f"  L{ln}: {nm}")
    return changed

if __name__ == "__main__":
    for p in sys.argv[1:]:
        fix(p)
