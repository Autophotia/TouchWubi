#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
14键模糊输入召回 沙盒测试（2026-11-01 诊断）

复现问题：14键造词成功、左右滑动精确输入能召回，但直接点击（模糊输入）打不出来。

验证 user_coined_translator 在 14 键布局下的匹配逻辑：
  - 造词「造词功能」保存 code=tyac（t/y 同键、x/c 同键）
  - 精确输入（右滑）：input=tyac → exact_match → 召回
  - 模糊输入（点击）：input=ttax（全左字母）→ dual_exact_match → 应召回

用法：python dev/tools/sandbox_14key_fuzzy_test.py
"""
import os
import sys
import tempfile
import shutil

from lupa import LuaRuntime

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCHEMA_DIR = os.path.join(ROOT, "space", "schemas", "TouchWB")
LUA_DIR = os.path.join(SCHEMA_DIR, "lua")
SUBMIT_LUA = os.path.join(LUA_DIR, "Submit_text.lua")

# 沙盒 mock：librime 的 C++ LevelDb（方案 B 后自造词存储迁到 UserDb），用 Lua table 模拟。
MOCK_LEVELDB = r"""
_MockDB = {}
function LevelDb(name)
    return {
        open = function(self) return true end,
        loaded = function(self) return true end,
        close = function(self) end,
        fetch = function(self, key) return _MockDB[key] end,
        update = function(self, key, value) _MockDB[key] = value; return true end,
        erase = function(self, key)
            if _MockDB[key] ~= nil then _MockDB[key] = nil; return true end
            return false
        end,
        query = function(self, prefix)
            local keys = {}
            for k in pairs(_MockDB) do
                if string.sub(k, 1, #prefix) == prefix then keys[#keys + 1] = k end
            end
            table.sort(keys)
            local i = 0
            return { iter = function()
                return function()
                    i = i + 1
                    if i <= #keys then return keys[i], _MockDB[keys[i]] end
                    return nil
                end
            end }
        end,
    }
end
function mock_db_put(key, value) _MockDB[key] = value end
function mock_db_get(key) return _MockDB[key] end
function mock_db_count() local n = 0; for _ in pairs(_MockDB) do n = n + 1 end; return n end
function mock_db_keys()
    local out = {}
    for k in pairs(_MockDB) do out[#out + 1] = k end
    table.sort(out)
    return out
end
"""


def to_lua(p):
    return p.replace("\\", "/")


def build_runtime(user_dir, schema_dir):
    L = LuaRuntime(unpack_returned_tuples=True)
    L.execute("package.path = [[%s/?.lua;]] .. package.path" % to_lua(LUA_DIR))
    ud, sd = to_lua(user_dir), to_lua(schema_dir)
    L.execute(
        "rime_api = {"
        "  get_user_data_dir   = function() return [[%s]] end,"
        "  get_schema_data_dir = function() return [[%s]] end,"
        "  get_shared_data_dir = function() return [[%s]] end,"
        "}" % (ud, sd, sd)
    )
    L.execute("log = { info=function() end, error=function(m) print('[lua.error]', m) end,"
              " warning=function() end }")
    L.execute("Candidate = function(ctype, s, e, text, comment, preedit)"
              " return { type=ctype, start=s, _end=e, text=text,"
              "          comment=comment or '', preedit=preedit or '', quality=0 } end")
    L.execute(MOCK_LEVELDB)
    return L


def run_translator(L, schema_id, input_str):
    """以指定 schema + 输入串调用 user_coined_translator，返回 yield 出的 'text|comment' 列表。"""
    texts = []

    def _yield(cand):
        texts.append(cand["text"] + "|" + cand["comment"])

    L.globals()["yield"] = _yield
    L.execute("""
        ctx = { input = [[%s]] }
        env = { engine = { context = ctx, schema = { schema_id = '%s' } } }
        seg = { start = 0, _end = #ctx.input }
    """ % (input_str, schema_id))
    L.execute("user_coined_translator(%s, seg, env)" % repr(input_str))
    return ",".join(texts)


def main():
    fail = 0
    tmp = tempfile.mkdtemp(prefix="touchwb_14fz_")

    print("=" * 70)
    print("14键模糊输入召回 沙盒测试")
    print("=" * 70)

    # ---- 手动词（UserDb 永久词 e\t...）----
    L1 = build_runtime(tmp, SCHEMA_DIR)
    L1.execute("mock_db_put('\\0seq', '10')")
    L1.execute("mock_db_put('e\\ttyac\\t造词功能', '1')")
    L1.eval("dofile([[%s]])" % to_lua(SUBMIT_LUA))

    print("\n【用例 1 · 手动词 · 14键 精确输入 tyac】")
    res = run_translator(L1, "ly_wubi_pinyin_14", "tyac")
    ok = ("造词功能" in res)
    print("  yield 候选：%s" % (res or "(无)"))
    print("  %s" % ("✅ 通过" if ok else "❌ 失败"))
    fail += 0 if ok else 1

    print("\n【用例 2 · 手动词 · 14键 模糊输入 ttax】")
    res = run_translator(L1, "ly_wubi_pinyin_14", "ttax")
    ok = ("造词功能" in res)
    print("  yield 候选：%s" % (res or "(无)"))
    print("  %s" % ("✅ 通过：手动词模糊输入召回" if ok else "❌ 失败"))
    fail += 0 if ok else 1

    # ---- 自动临时词（UserDb 临时词 a\t...）----
    L2 = build_runtime(tmp, SCHEMA_DIR)
    L2.execute("mock_db_put('\\0seq', '10')")
    L2.execute("mock_db_put('a\\ttyac\\t造词功能', '2')")
    L2.eval("dofile([[%s]])" % to_lua(SUBMIT_LUA))

    print("\n【用例 3 · 临时词 · 14键 精确输入 tyac（对照）】")
    res = run_translator(L2, "ly_wubi_pinyin_14", "tyac")
    ok = ("造词功能" in res)
    print("  yield 候选：%s" % (res or "(无)"))
    print("  %s" % ("✅ 通过：临时词精确输入召回" if ok else "❌ 失败"))
    fail += 0 if ok else 1

    print("\n【用例 4 · 临时词 · 14键 模糊输入 ttax（复现 bug）】")
    res = run_translator(L2, "ly_wubi_pinyin_14", "ttax")
    ok = ("造词功能" in res)
    print("  yield 候选：%s" % (res or "(无)"))
    print("  %s" % ("✅ 通过：临时词模糊输入召回" if ok else "❌ 失败：临时词模糊输入召回不了（根因复现）"))
    fail += 0 if ok else 1

    shutil.rmtree(tmp, ignore_errors=True)
    print("\n" + "=" * 70)
    print("结论：%s" % ("全部通过" if fail == 0 else "%d 项失败（见上方 ❌）" % fail))
    print("=" * 70)
    return 0 if fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
