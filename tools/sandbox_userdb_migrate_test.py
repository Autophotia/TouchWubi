# -*- coding: utf-8 -*-
"""
userdb 迁移 沙盒测试（方案 B 后自造词 userdb 从根目录迁到 lua/ 下）

验证 Submit_text.lua 的 uc_migrate_once 迁移优先级：
  ① 旧根目录 user_coined 库有数据 → 整体复制到新 lua/user_coined 库（含 e/a/seq meta）；
  ② 旧库为空 → 回退从历史 txt（user_coined_ext.txt / user_coined_auto.txt）一次性导入。

与其它 sandbox 测试的区别：这里用 name-aware mock LevelDb（_MockDBs[name]），
能区分 LevelDb("user_coined") 与 LevelDb("lua/user_coined") 两个不同的库。
"""

import os
import sys
import shutil
import tempfile

from lupa import LuaRuntime

HERE = os.path.dirname(os.path.abspath(__file__))
LUA_DIR = os.path.join(HERE, "..", "space", "schemas", "TouchWB", "lua")
SCHEMA_DIR = os.path.join(HERE, "..", "space", "schemas", "TouchWB")
SUBMIT_LUA = os.path.join(LUA_DIR, "Submit_text.lua")


def to_lua(p):
    return p.replace("\\", "/")


# name-aware mock：LevelDb(name) 各自独立存储，区分 user_coined / lua/user_coined
MOCK_LEVELDB = r"""
_MockDBs = {}
function LevelDb(name)
    if _MockDBs[name] == nil then _MockDBs[name] = {} end
    local db = _MockDBs[name]
    return {
        open = function(self) return true end,
        loaded = function(self) return true end,
        close = function(self) end,
        fetch = function(self, key) return db[key] end,
        update = function(self, key, value) db[key] = value; return true end,
        erase = function(self, key)
            if db[key] ~= nil then db[key] = nil; return true end
            return false
        end,
        query = function(self, prefix)
            local keys = {}
            for k in pairs(db) do
                if string.sub(k, 1, #prefix) == prefix then keys[#keys + 1] = k end
            end
            table.sort(keys)
            local i = 0
            return { iter = function()
                return function()
                    i = i + 1
                    if i <= #keys then return keys[i], db[keys[i]] end
                    return nil
                end
            end }
        end,
    }
end
function mock_db_put(name, key, value)
    if _MockDBs[name] == nil then _MockDBs[name] = {} end
    _MockDBs[name][key] = value
end
function mock_db_get(name, key)
    local d = _MockDBs[name]
    return d and d[key]
end
function mock_db_has(name, key)
    return mock_db_get(name, key) ~= nil
end
function mock_db_count(name)
    local d = _MockDBs[name] or {}
    local n = 0
    for _ in pairs(d) do n = n + 1 end
    return n
end
function mock_db_was_opened(name)
    return _MockDBs[name] ~= nil
end
function mock_db_manual_texts(name)
    local d = _MockDBs[name] or {}
    local out = {}
    for k in pairs(d) do
        if string.sub(k, 1, 2) == 'e\t' then
            local code, text = string.match(k, '^.-\t([^\t]+)\t(.+)$')
            if code and text then out[#out + 1] = text .. '\t' .. code end
        end
    end
    table.sort(out)
    return table.concat(out, '\n')
end
function mock_db_temp_texts(name)
    local d = _MockDBs[name] or {}
    local out = {}
    for k in pairs(d) do
        if string.sub(k, 1, 2) == 'a\t' then
            local code, text = string.match(k, '^.-\t([^\t]+)\t(.+)$')
            if code and text then out[#out + 1] = text .. '\t' .. code end
        end
    end
    table.sort(out)
    return table.concat(out, '\n')
end
"""


def build_runtime(user_dir):
    L = LuaRuntime(unpack_returned_tuples=True)
    L.execute("package.path = [[%s/?.lua;]] .. package.path" % to_lua(LUA_DIR))
    ud = to_lua(user_dir)
    L.execute(
        "rime_api = {"
        "  get_user_data_dir   = function() return [[%s]] end,"
        "  get_schema_data_dir = function() return [[%s]] end,"
        "  get_shared_data_dir = function() return '' end,"
        "}" % (ud, ud)
    )
    L.execute("log = { info=function() end, error=function(m) print('[lua.error]', m) end,"
              " warning=function() end }")
    L.execute(MOCK_LEVELDB)
    L.eval("dofile([[%s]])" % to_lua(SUBMIT_LUA))
    return L


def main():
    fail = 0
    tmp = tempfile.mkdtemp(prefix="touchwb_mig_")

    print("=" * 70)
    print("userdb 根目录 → lua/ 迁移 沙盒测试")
    print("=" * 70)

    # ================================================================
    # 场景 A：旧根目录 user_coined 库有数据 → 整体复制到 lua/user_coined
    # ================================================================
    print("\n【场景 A · 旧库有数据 → 迁移到 lua/ 新库】")
    # 模拟旧库真实存在于磁盘：LevelDB 目录里必须有 CURRENT 文件（uc_old_db_exists 判据）
    os.makedirs(os.path.join(tmp, "user_coined.userdb"), exist_ok=True)
    with open(os.path.join(tmp, "user_coined.userdb", "CURRENT"), "w", encoding="utf-8") as f:
        f.write("MANIFEST-000002\n")
    L1 = build_runtime(tmp)
    # 旧库（根目录 user_coined）：seq meta + 2 永久词 + 1 临时词
    L1.execute("mock_db_put('user_coined', '\\0seq', '3')")
    L1.execute("mock_db_put('user_coined', 'e\\tkvsj\\t你好', '1')")
    L1.execute("mock_db_put('user_coined', 'e\\ttfty\\t自动造词', '2')")
    L1.execute("mock_db_put('user_coined', 'a\\tpoiu\\t临时词', '0')")
    L1.execute("UserCoined_DB_Migrate()")

    new_seq = L1.eval("mock_db_get('lua/user_coined', '\\0seq')")
    has_manual1 = L1.eval("mock_db_has('lua/user_coined', 'e\\tkvsj\\t你好')")
    has_manual2 = L1.eval("mock_db_has('lua/user_coined', 'e\\ttfty\\t自动造词')")
    has_temp = L1.eval("mock_db_has('lua/user_coined', 'a\\tpoiu\\t临时词')")
    new_count = L1.eval("mock_db_count('lua/user_coined')")

    print("  新库 lua/user_coined 条目数 = %s（期望 4）" % new_count)
    print("  seq meta 已复制 = %s（期望 '3'）" % new_seq)
    ok = (new_seq == '3' and has_manual1 and has_manual2 and has_temp and new_count == 4)
    print("  %s" % ("✅ 通过：旧库整库复制到新库（含 e/a/seq meta）" if ok else "❌ 失败"))
    fail += 0 if ok else 1

    # 旧库应保持原样（迁移是复制、不删除，兜底安全）
    old_count = L1.eval("mock_db_count('user_coined')")
    ok = (old_count == 4)
    print("  旧库 user_coined 未被删除（条目数 = %s）%s" % (old_count,
          "✅ 通过" if ok else "❌ 失败：旧库被动了"))
    fail += 0 if ok else 1

    # ================================================================
    # 场景 B：旧库目录不存在 → 不 open 旧库，直接回退历史 txt 一次性导入
    # ================================================================
    print("\n【场景 B · 旧库不存在 → 不 open 旧库，回退历史 txt 迁移】")
    tmp_b = tempfile.mkdtemp(prefix="touchwb_mig_b_")
    L2 = build_runtime(tmp_b)
    # 不创建 user_coined.userdb/CURRENT 文件；写历史 txt 作为种子
    with open(os.path.join(tmp_b, "user_coined_ext.txt"), "w", encoding="utf-8") as f:
        f.write("# 自造词文件\n")
        f.write("# 格式：词条<Tab>编码\n")
        f.write("# 即时生效，无需重新部署\n")
        f.write("你好\tkvsj\n")
        f.write("自动造词\ttfty\n")
    L2.execute("UserCoined_DB_Migrate()")

    manual = L2.eval("mock_db_manual_texts('lua/user_coined')")
    print("  txt 导入后的永久词（text\\tcode）：%r" % manual)
    ok = ("你好\tkvsj" in (manual or "")) and ("自动造词\ttfty" in (manual or ""))
    print("  %s" % ("✅ 通过：旧库空时从历史 txt 一次性导入" if ok else "❌ 失败"))
    fail += 0 if ok else 1

    # 关键回归：旧库目录不存在时，迁移逻辑不得 open 旧库（否则会凭空创建空目录）。
    #   mock 层面等价于：'user_coined' 这个库从未被 LevelDb 打开 ⇒ was_opened=false。
    old_b_opened = L2.eval("mock_db_was_opened('user_coined')")
    ok = (old_b_opened == False)
    print("  旧库不存在时未 open（was_opened = %s，期望 false）%s" % (old_b_opened,
          "✅ 通过：未凭空创建旧库" if ok else "❌ 失败：迁移逻辑 open 了旧库"))
    fail += 0 if ok else 1

    shutil.rmtree(tmp, ignore_errors=True)
    shutil.rmtree(tmp_b, ignore_errors=True)
    print("\n" + "=" * 70)
    print("结论：%s" % ("全部通过" if fail == 0 else "%d 项失败（见上方 ❌）" % fail))
    print("=" * 70)
    return 0 if fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
