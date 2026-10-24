#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
造词功能沙盒测试（TouchWB / Submit_text.lua）

用 lupa 在纯 Lua 环境里加载 lua/Submit_text.lua，mock 掉 librime 的
rime_api / log，直接调用造词保存函数，验证：
  1. 造词文件路径解析是否正确
  2. 标准五笔编码能否从字典查到（决定写入的编码是否正确）
  3. 字典查询失败时的降级编码（splitinput）是否正确
  4. 重复写入是否去重
  5. 含字母的「词」是否被拒绝

用法：
    python dev/tools/sandbox_coined_test.py
依赖：lupa（已装在 C:\\Users\\xoaii\\.workbuddy\\binaries\\python\\envs\\default）
"""
import os
import sys
import tempfile
import shutil

from lupa import LuaRuntime

# ── 路径 ────────────────────────────────────────────────────────────
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCHEMA_DIR = os.path.join(ROOT, "space", "schemas", "TouchWB")
LUA_DIR = os.path.join(SCHEMA_DIR, "lua")
SUBMIT_LUA = os.path.join(LUA_DIR, "Submit_text.lua")


def to_lua_path(p):
    """Windows 路径 -> Lua 可安全使用的正斜杠路径"""
    return p.replace("\\", "/")


def build_runtime(user_dir, schema_dir, shared_dir=""):
    """构造一个 mock 了 librime 环境的 LuaRuntime，并加载 Submit_text.lua"""
    L = LuaRuntime(unpack_returned_tuples=True)
    g = L.globals()

    # package.path：让 require('lib/basic') 能找到 lua/lib/basic.lua
    L.execute("package.path = [[%s/?.lua;]] .. package.path" % to_lua_path(LUA_DIR))

    # mock rime_api
    ud, sd, shd = to_lua_path(user_dir), to_lua_path(schema_dir), to_lua_path(shared_dir)
    L.execute(
        "rime_api = {"
        "  get_user_data_dir   = function() return [[%s]] end,"
        "  get_schema_data_dir = function() return [[%s]] end,"
        "  get_shared_data_dir = function() return [[%s]] end,"
        "}" % (ud, sd, shd)
    )

    # mock log（静默，避免刷屏）
    L.execute("log = { info=function() end, error=function(m) print('[lua.error]', m) end,"
              " warning=function() end }")

    # 加载模块；dofile 的返回值就是 Submit_text.lua 末尾 return 的 processor
    processor = L.eval("dofile([[%s]])" % to_lua_path(SUBMIT_LUA))
    return L, g, processor


def read_coined(path):
    if not os.path.exists(path):
        return []
    with open(path, "r", encoding="utf-8") as f:
        return [ln.rstrip("\n") for ln in f if ln.strip() and not ln.startswith("#")]


def main():
    if not os.path.exists(SUBMIT_LUA):
        print("❌ 找不到 %s" % SUBMIT_LUA)
        return 1

    tmp = tempfile.mkdtemp(prefix="touchwb_coined_")
    user_dir = tmp  # 模拟 Rime 用户数据目录
    coined_path = os.path.join(tmp, "user_coined_ext.txt")

    print("=" * 68)
    print("造词功能沙盒测试")
    print("=" * 68)
    print("方案目录 : %s" % SCHEMA_DIR)
    print("用户目录 : %s (mock)" % user_dir)
    print("")

    fail = 0

    try:
        L, g, processor = build_runtime(user_dir, SCHEMA_DIR)
        get_path = g.get_userphrase_path
        fileappendtext = g.fileappendtext
        splitinput = g.splitinput

        # ── 用例 1：路径解析 ────────────────────────────────────
        print("【用例 1】造词文件路径解析")
        p = get_path()
        expect = to_lua_path(coined_path)
        ok = (p == expect)
        print("  解析结果 : %s" % p)
        print("  期望     : %s" % expect)
        print("  %s" % ("✅ 通过" if ok else "❌ 失败：路径不对，造词将写不进去"))
        fail += 0 if ok else 1
        print("")

        # ── 用例 2：字典查询是否可用（关键探测）────────────────
        # 不传 input：若字典能查到编码则写入成功，否则 clean_input 为空 → 不写入
        print("【用例 2】标准五笔编码能否从字典查到（决定写入编码是否正确）")
        print("  方法：调用 fileappendtext 但不给 input，只看字典查询路线")
        fileappendtext(p, "中国", None, None)
        entries = read_coined(coined_path)
        if entries:
            print("  写入内容 : %s" % entries)
            print("  ✅ 字典查询可用，标准编码路线工作正常")
        else:
            print("  未写入任何内容")
            print("  ❌ 字典查询返回空 —— get_char_wubi_code 找不到汉字编码")
            print("     （代码找 wubi.dict.yaml，但主词库实际叫 ly_wubi.dict.yaml）")
            fail += 1
        print("")

        # 清理用例 2 的痕迹，保证后续用例独立
        if os.path.exists(coined_path):
            os.remove(coined_path)

        # ── 用例 3：完整造词流程（编码`编码 → 降级路线）────────
        print("【用例 3】完整造词流程：输入 'kh`lg' 选中「中国」后按空格")
        fileappendtext(p, "中国", "kh`lg", None)
        entries = read_coined(coined_path)
        print("  文件内容 : %s" % entries)
        if entries:
            text, code = entries[0].split("\t") if "\t" in entries[0] else (entries[0], "")
            ok = (text == "中国" and code == "khlg")
            print("  词条=%s 编码=%s" % (text, code))
            print("  %s" % ("✅ 通过：造的词能按 khlg 打出"
                             if ok else "❌ 失败：编码不是 khlg，造的词打不出来"))
            fail += 0 if ok else 1
        else:
            print("  ❌ 失败：文件未写入")
            fail += 1
        print("")

        # ── 用例 4：重复写入去重 ────────────────────────────────
        print("【用例 4】重复造同一个词是否去重")
        fileappendtext(p, "中国", "kh`lg", None)
        entries = read_coined(coined_path)
        ok = len(entries) == 1
        print("  文件词条数 : %d" % len(entries))
        print("  %s" % ("✅ 通过：无重复" if ok else "❌ 失败：出现重复条目"))
        fail += 0 if ok else 1
        print("")

        # ── 用例 5：含字母的输入应被拒绝 ────────────────────────
        print("【用例 5】含字母的「词」应被拒绝（防止把编码当词条写进去）")
        before = len(read_coined(coined_path))
        fileappendtext(p, "abc", "kh`lg", None)
        after = len(read_coined(coined_path))
        ok = (before == after)
        print("  写入前 %d 条 → 写入后 %d 条" % (before, after))
        print("  %s" % ("✅ 通过：已拒绝" if ok else "❌ 失败：含字母的串被写进去了"))
        fail += 0 if ok else 1
        print("")

        # ── 用例 6：splitinput 降级逻辑 ─────────────────────────
        print("【用例 6】splitinput 降级编码生成")
        cases = [("kh`lg", 2, "khlg"), ("w`w`w", 3, "www"), ("a`b`c`d", 4, "abcd")]
        for inp, ln, exp in cases:
            got = splitinput(inp, ln)
            ok = (got == exp)
            print("  splitinput('%s', %d) = '%s'  (期望 '%s')  %s"
                  % (inp, ln, got, exp, "✅" if ok else "❌"))
            fail += 0 if ok else 1
        print("")

        # ── 用例 7：词典文件存在性 ──────────────────────────────
        #   ly_wubi.dict.yaml 是主词库（必需）；wubi.dict.yaml 是改名前的旧名，
        #   代码里仍保留作兼容兜底，缺失不算失败。
        print("【用例 7】造词依赖的字典文件是否存在")
        main_dict = os.path.exists(os.path.join(SCHEMA_DIR, "ly_wubi.dict.yaml"))
        old_dict = os.path.exists(os.path.join(SCHEMA_DIR, "wubi.dict.yaml"))
        ext_dict = os.path.exists(os.path.join(SCHEMA_DIR, "wubi.extended.dict.yaml"))
        print("  %-26s %s  (主词库，必需)" % ("ly_wubi.dict.yaml", "存在" if main_dict else "❌ 不存在"))
        print("  %-26s %s  (旧名，兼容兜底)" % ("wubi.dict.yaml", "存在" if old_dict else "缺失，OK"))
        print("  %-26s %s  (扩展词库)" % ("wubi.extended.dict.yaml", "存在" if ext_dict else "缺失"))
        if not main_dict:
            fail += 1
        print("")

        # ── 用例 8：标准编码应优先于用户输入的编码 ──────────────
        #   故意给一个错误的 input，若仍写入字典里的标准编码 khlg，
        #   说明标准编码路线生效（修复前会写入错误的 xxyy）
        print("【用例 8】标准五笔编码应优先于用户输入（修复前会写入错误编码）")
        if os.path.exists(coined_path):
            os.remove(coined_path)
        fileappendtext(p, "中国", "xx`yy", None)   # 输入故意给错
        entries = read_coined(coined_path)
        got = entries[0].split("\t")[-1] if entries else ""
        ok = (got == "khlg")
        print("  输入 'xx`yy'（错误编码）→ 实际写入编码: '%s'  (期望 'khlg')" % got)
        print("  %s" % ("✅ 通过：走字典标准编码，不受输入影响"
                         if ok else "❌ 失败：仍在用用户输入编码（字典查询未生效）"))
        fail += 0 if ok else 1
        print("")

        # ── 用例 9：2/3/4 字词的编码规则 ───────────────────────
        print("【用例 9】多字词标准编码（2字每字2位 / 3字 1+1+2 / 4字 1+1+1+1）")
        for word, expect in (("中国", "khlg"), ("计算机", "ytsm"), ("中华人民共和国", "kwwl")):
            if os.path.exists(coined_path):
                os.remove(coined_path)
            fileappendtext(p, word, None, None)   # 不给 input，纯靠字典
            es = read_coined(coined_path)
            code = es[0].split("\t")[-1] if es else "(未写入)"
            ok = (code == expect)
            print("  %-8s -> %-6s (期望 %-6s) %s" % (word, code, expect, "✅" if ok else "❌"))
            fail += 0 if ok else 1
        print("")

        print("=" * 68)
        print("结论：%s" % ("全部通过" if fail == 0 else "%d 项失败（见上方 ❌）" % fail))
        print("=" * 68)

    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    return 0 if fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
