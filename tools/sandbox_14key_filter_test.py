#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
wubi_pinyin_filter 对 user_coined 候选在 14 键模糊输入下的过滤 沙盒测试

复现：14键造词「造词功能」code=tyac，精确输入 tyac 能召回，模糊输入 ttax 打不出来。

验证 wubi_pinyin_filter 主循环 matches_prefix 在 14 键模糊输入下，
对 user_coined 候选（comment=tyac）是否保留。

用法：python dev/tools/sandbox_14key_filter_test.py
"""
import os
import sys

from lupa import LuaRuntime

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LUA_DIR = os.path.join(ROOT, "space", "schemas", "TouchWB", "lua")
FILTER_LUA = os.path.join(LUA_DIR, "wubi_pinyin_filter.lua")

DERIVES = ["derive/w/q/", "derive/r/e/", "derive/y/t/", "derive/i/u/",
           "derive/p/o/", "derive/s/a/", "derive/f/d/", "derive/h/g/",
           "derive/k/j/", "derive/c/x/", "derive/b/v/", "derive/m/n/"]


def to_lua(p):
    return p.replace("\\", "/")


def build_runtime():
    L = LuaRuntime(unpack_returned_tuples=True)
    L.execute("package.path = [[%s/?.lua;]] .. package.path" % to_lua(LUA_DIR))
    return L


def build_env(L, input_str, with_derive=True, use_key_pairs=True):
    """构造 wubi_pinyin_filter 所需 env（14键）。"""
    derive_items = ""
    if with_derive:
        items = ["{ value = [[%s]] }" % d for d in DERIVES]
        derive_items = ", ".join(items)
    L.execute("""
        rime_api = {
            get_user_data_dir = function() return [[/tmp/ns_test]] end,
            get_schema_data_dir = function() return [[/tmp/ns_test]] end,
            get_shared_data_dir = function() return [[/tmp/ns_test]] end,
        }
        Candidate = function(ctype, s, e, text, comment, preedit)
            return { type=ctype, start=s, _end=e, text=text,
                     comment=comment or "", preedit=preedit or "", quality=0 }
        end
        ReverseDb = function(path)
            return { lookup = function(self, ch) return nil end }
        end
        _derive_list = { %s }
        config = {
            get_list = function(self, path)
                if path == 'speller/algebra' then
                    return { size = %d, get_value_at = function(self, i) return _derive_list[i + 1] end }
                end
                return { size = 0, get_value_at = function(self) return nil end }
            end,
            get_list_size = function(self, path) return 0 end,
            get_string = function(self, path)
                if path == 'lua_reverse_db/spelling' then return 'wb_spelling' end
                if path == 'lua_reverse_db/code' then return 'wb_spelling' end
                return nil
            end,
            get_bool = function(self, path)
                if path == 'wubi_pinyin_filter/use_key_pairs' then return %s end
                if path == 'engine/mixed_input' then return true end
                return nil
            end,
            get_int = function(self, path) return nil end,
        }
        ctx = { input = [[%s]] }
        env = { engine = { context = ctx, schema = { config = config } } }
    """ % (derive_items, len(DERIVES) if with_derive else 0,
           "true" if use_key_pairs else "false", input_str))


def run_filter(L, filter_func, cand_expr):
    L.execute("""
        cands = %s
        input_mock = {
            iter = function(self)
                local i, n = 0, #cands
                return function()
                    i = i + 1
                    if i <= n then return cands[i] end
                    return nil
                end
            end,
        }
        results = {}
        function yield(c) results[#results + 1] = c end
    """ % cand_expr)
    filter_func(L.eval("input_mock"), L.eval("env"))
    return L.eval("results")


def texts_of(res):
    out = []
    n = len(res)
    for i in range(1, n + 1):
        out.append(res[i]["text"])
    return ",".join(out)


def main():
    fail = 0
    L = build_runtime()
    wf_mod = L.eval("dofile([[%s]])" % to_lua(FILTER_LUA))
    wf_init = wf_mod["init"]
    wf_func = wf_mod["func"]

    user_coined_cand = "Candidate('user_coined', 0, 4, '造词功能', 'tyac', '')"

    print("=" * 70)
    print("wubi_pinyin_filter 14键模糊输入 过滤测试")
    print("=" * 70)

    # 用例1：14键模糊输入 ttax + use_key_pairs=true → 应保留
    print("\n【用例 1 · 14键 模糊输入 ttax（use_key_pairs=true）】")
    build_env(L, "ttax", with_derive=True, use_key_pairs=True)
    wf_init(L.eval("env"))
    res = run_filter(L, wf_func, "{ %s }" % user_coined_cand)
    texts = texts_of(res)
    ok = ("造词功能" in texts)
    print("  filter 输出：%s" % (texts or "(空)"))
    print("  %s" % ("✅ 通过：模糊输入保留「造词功能」" if ok else "❌ 失败：被过滤（根因在此）"))
    fail += 0 if ok else 1

    # 用例2：14键精确输入 tyac + use_key_pairs=true → 应保留（对照）
    print("\n【用例 2 · 14键 精确输入 tyac（对照）】")
    build_env(L, "tyac", with_derive=True, use_key_pairs=True)
    wf_init(L.eval("env"))
    res = run_filter(L, wf_func, "{ %s }" % user_coined_cand)
    texts = texts_of(res)
    ok = ("造词功能" in texts)
    print("  filter 输出：%s" % (texts or "(空)"))
    print("  %s" % ("✅ 通过：精确输入保留「造词功能」" if ok else "❌ 失败"))
    fail += 0 if ok else 1

    # 用例3：14键模糊输入 ttax，但 use_key_pairs=false → 应过滤（验证开关作用）
    print("\n【用例 3 · 模糊输入 ttax 但 use_key_pairs=false（对照）】")
    build_env(L, "ttax", with_derive=True, use_key_pairs=False)
    wf_init(L.eval("env"))
    res = run_filter(L, wf_func, "{ %s }" % user_coined_cand)
    texts = texts_of(res)
    ok = ("造词功能" not in texts)
    print("  filter 输出：%s" % (texts or "(空)"))
    print("  %s" % ("✅ 通过：关闭模糊后正确过滤（证明 use_key_pairs 是关键开关）" if ok else "❌ 异常"))
    fail += 0 if ok else 1

    # 用例4：14键模糊输入 ttax，但 derive 规则缺失 → 应过滤（验证 left_to_right 作用）
    print("\n【用例 4 · 模糊输入 ttax 但 derive 缺失（对照）】")
    build_env(L, "ttax", with_derive=False, use_key_pairs=True)
    wf_init(L.eval("env"))
    res = run_filter(L, wf_func, "{ %s }" % user_coined_cand)
    texts = texts_of(res)
    ok = ("造词功能" not in texts)
    print("  filter 输出：%s" % (texts or "(空)"))
    print("  %s" % ("✅ 通过：derive 缺失时正确过滤（证明 left_to_right 是关键）" if ok else "❌ 异常"))
    fail += 0 if ok else 1

    print("\n" + "=" * 70)
    print("结论：%s" % ("全部通过" if fail == 0 else "%d 项失败（见上方 ❌）" % fail))
    print("=" * 70)
    return 0 if fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
