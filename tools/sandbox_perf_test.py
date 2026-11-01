#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
方案 B：自造词存储迁 C++ UserDb 的等价性/正确性 沙盒测试（2026-11-01）

验证 UserDb 迁移后召回语义不变（LevelDb 用 Lua table 模拟）：
  1. 精确召回（26键）
  2. 前缀召回 + 反向前缀召回
  3. 14键模糊整码召回（同键）
  4. UserCoined_AppendManual 写 db 后召回（转正语义）
  5. PutTemp / EraseTemp 临时词增删

用法：python dev/tools/sandbox_perf_test.py
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
    """调用 user_coined_translator，返回 yield 出的 text 列表。"""
    texts = []

    def _yield(cand):
        texts.append(cand["text"])

    L.globals()["yield"] = _yield
    L.execute("""
        ctx = { input = [[%s]] }
        env = { engine = { context = ctx, schema = { schema_id = '%s' } } }
        seg = { start = 0, _end = #ctx.input }
    """ % (input_str, schema_id))
    L.execute("user_coined_translator(%s, seg, env)" % repr(input_str))
    return texts


def main():
    fail = 0
    tmp = tempfile.mkdtemp(prefix="touchwb_userdb_")

    print("=" * 70)
    print("方案 B · UserDb 迁移 等价性 沙盒测试")
    print("=" * 70)

    # ---- 用例 1~2：精确 / 前缀 / 反向前缀召回（26键）----
    L1 = build_runtime(tmp, SCHEMA_DIR)
    L1.execute("mock_db_put('\\0seq', '100')")
    L1.execute("mock_db_put('e\\tamad\\t阿妈', '1')")
    L1.execute("mock_db_put('e\\tkqwy\\t测试词', '2')")
    L1.eval("dofile([[%s]])" % to_lua(SUBMIT_LUA))

    print("\n【用例 1 · 精确召回】")
    res = run_translator(L1, "ly_wubi", "amad")
    ok = "阿妈" in res
    print("  input=amad -> %s %s" % (res or "(无)", "✅" if ok else "❌"))
    fail += 0 if ok else 1

    print("\n【用例 2 · 前缀召回 + 反向前缀召回】")
    res = run_translator(L1, "ly_wubi", "am")
    ok1 = "阿妈" in res
    res2 = run_translator(L1, "ly_wubi", "kqwys")
    ok2 = "测试词" in res2
    print("  前缀 input=am -> %s %s" % (res or "(无)", "✅" if ok1 else "❌"))
    print("  反向 input=kqwys -> %s %s" % (res2 or "(无)", "✅" if ok2 else "❌"))
    fail += 0 if (ok1 and ok2) else 1

    # ---- 用例 3：14键模糊整码召回 ----
    L2 = build_runtime(tmp, SCHEMA_DIR)
    L2.execute("mock_db_put('\\0seq', '100')")
    L2.execute("mock_db_put('e\\ttyac\\t造词功能', '1')")
    L2.eval("dofile([[%s]])" % to_lua(SUBMIT_LUA))

    print("\n【用例 3 · 14键模糊整码召回】")
    res = run_translator(L2, "ly_wubi_pinyin_14", "ttax")
    ok = "造词功能" in res
    print("  input=ttax -> %s %s" % (res or "(无)", "✅" if ok else "❌"))
    fail += 0 if ok else 1

    # ---- 用例 4：AppendManual 写 db 后召回（转正语义）----
    L3 = build_runtime(tmp, SCHEMA_DIR)
    L3.execute("mock_db_put('\\0seq', '100')")
    L3.eval("dofile([[%s]])" % to_lua(SUBMIT_LUA))

    print("\n【用例 4 · AppendManual 写 db 后召回】")
    ok_append = L3.eval("UserCoined_AppendManual('新词', 'zzzz')")
    res = run_translator(L3, "ly_wubi", "zzzz")
    in_db = L3.eval("mock_db_get('e\\tzzzz\\t新词') ~= nil")
    ok = (ok_append == True) and ("新词" in res) and in_db
    print("  append=%s, db 含词=%s, input=zzzz -> %s %s" % (
        ok_append, in_db, res or "(无)", "✅" if ok else "❌"))
    fail += 0 if ok else 1

    # ---- 用例 5：PutTemp / EraseTemp 临时词增删 ----
    L4 = build_runtime(tmp, SCHEMA_DIR)
    L4.execute("mock_db_put('\\0seq', '100')")
    L4.eval("dofile([[%s]])" % to_lua(SUBMIT_LUA))

    print("\n【用例 5 · PutTemp / EraseTemp 临时词增删】")
    L4.execute("UserCoined_DB_PutTemp('临时词', 'lins', 1)")
    res = run_translator(L4, "ly_wubi", "lins")
    ok1 = "临时词" in res
    L4.execute("UserCoined_DB_EraseTemp('临时词', 'lins')")
    res2 = run_translator(L4, "ly_wubi", "lins")
    ok2 = "临时词" not in res2
    ok = ok1 and ok2
    print("  写入后 input=lins -> %s %s" % (res or "(无)", "✅" if ok1 else "❌"))
    print("  删除后 input=lins -> %s %s" % (res2 or "(无)", "✅" if ok2 else "❌"))
    fail += 0 if ok else 1

    shutil.rmtree(tmp, ignore_errors=True)
    print("\n" + "=" * 70)
    print("结论：%s" % ("全部通过" if fail == 0 else "%d 项失败（见上方 ❌）" % fail))
    print("=" * 70)
    return 0 if fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
