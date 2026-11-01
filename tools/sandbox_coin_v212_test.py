#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
手动造词 v2.12「单字/词组一律累积 + 长按Z再按空格结束」沙盒测试（Submit_text.lua）

针对 2026-10-31 v2.12 行为做白盒验证（结束键 = 长按Z（`）再按空格；
notifier 把 v2.11 的 n>1「整词直接保存」分支删掉，改为单字/词组一律累积）：

  1. 单字上屏（两步时序）⇒ 累积进缓冲，不落盘；
  2. 词组上屏（≥2字，两步时序）⇒ 也累积进缓冲、不独立保存（v2.12 关键修复）；
  3. 长按Z（input=`）再按空格 ⇒ 缓冲合并成整词一次性保存（吞空格）；
  4. 空格但 input 非纯反引号 ⇒ 不结束（诊断分支，缓冲保留）；
  5. 放弃：输入非反引号内容 ⇒ 缓冲清空，不保存。

用法：python dev/tools/sandbox_coin_v212_test.py
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
function mock_db_texts(prefix)
    local out = {}
    for k in pairs(_MockDB) do
        if string.sub(k, 1, #prefix) == prefix then
            local code, text = string.match(k, '^.-\t([^\t]+)\t(.+)$')
            if code and text then out[#out + 1] = text .. '\t' .. code .. '\t' .. tostring(_MockDB[k]) end
        end
    end
    table.sort(out)
    return table.concat(out, '\n')
end
"""


def to_lua(p):
    return p.replace("\\", "/")


def db_manual_texts(L):
    """读取 mock UserDb 中永久词（e\t 前缀）的词条文本列表。"""
    s = L.eval("mock_db_texts('e\\t')")
    return [ln.split("\t")[0] for ln in s.split("\n") if ln]


def build_runtime(user_dir):
    L = LuaRuntime(unpack_returned_tuples=True)
    L.execute("package.path = [[%s/?.lua;]] .. package.path" % to_lua(LUA_DIR))
    ud = to_lua(user_dir)
    L.execute(
        "rime_api = {"
        "  get_user_data_dir   = function() return [[%s]] end,"
        "  get_schema_data_dir = function() return [[%s]] end,"
        "  get_shared_data_dir = function() return [[%s]] end,"
        "}" % (ud, ud, ud)
    )
    L.execute("log = { info=function() end, error=function(m) print('[lua.error]', m) end,"
              " warning=function() end }")
    L.execute(MOCK_LEVELDB)
    return L


def main():
    fail = 0
    tmp = tempfile.mkdtemp(prefix="touchwb_v212_")
    manual_path = os.path.join(tmp, "UserDb 永久词")

    print("=" * 70)
    print("手动造词 v2.12 单字/词组累积 + 长按Z再按空格结束 沙盒测试")
    print("=" * 70)

    L = build_runtime(tmp)
    L.execute("""
        ctx = {
            input = "",
            commit_history = {
                size = 0,
                entry = nil,
                back = function(self) return self.entry end,
            },
            composition = { back = function() return seg end },
            has_menu = function() return false end,
            get_commit_text = function() return "" end,
            get_selected_candidate = function() return nil end,
            clear = function() ctx.input = "" end,
            is_composing = function() return false end,
            push_input = function() end,
            update_notifier = {
                fn = nil,
                connect = function(self, fn) self.fn = fn end,
            },
        }
        seg = {
            menu = { candidate_count = function() return 0 end },
            get_candidate_at = function(self, i) return nil end,
            get_selected_candidate = function() return nil end,
            start = 0,
        }
        env = {
            engine = {
                context = ctx,
                schema = { schema_id = "ly_wubi" },
                commit_text = function(self, t) end,
            },
            last_1th_text = "",
            last_2th_text = { text = "", type = "" },
            last_3th_text = { text = "", type = "" },
        }
        function make_key(keycode, repr_str)
            repr_str = repr_str or "x"
            return {
                keycode = keycode,
                repr = function(self) return repr_str end,
                release = function(self) return false end,
            }
        end
        function notify_update()
            if ctx.update_notifier.fn then ctx.update_notifier.fn(ctx) end
        end
        -- ★ 模拟 bimkit「点选候选上屏」两步时序（先清空 composition、再 commit）
        function click_commit(text)
            ctx.input = ""
            notify_update()
            ctx.commit_history.size = ctx.commit_history.size + 1
            ctx.commit_history.entry = { text = text }
            notify_update()
        end
    """)

    processor = L.eval("dofile([[%s]])" % to_lua(SUBMIT_LUA))

    # 首次按键（普通字母键），连接 notifier，稳定基线
    processor(L.eval("make_key(97)"), L.eval("env"))
    L.execute("ctx.input = 'x'; notify_update()")

    # ----------------------------------------------------------------
    print("\n【用例 1 · 单字累积：之、田 → 缓冲，不落盘】")
    L.execute("ctx.input = '`pp'")
    processor(L.eval("make_key(112)"), L.eval("env"))
    L.execute("click_commit('之')")
    L.execute("ctx.input = '`ll'")
    processor(L.eval("make_key(108)"), L.eval("env"))
    L.execute("click_commit('田')")
    entries = db_manual_texts(L)
    ok = (entries == [])
    print("  之、田 上屏后 UserDb 永久词：%s" % (entries if entries else "(空)"))
    print("  %s" % ("✅ 通过：单字只进缓冲、未落盘" if ok else "❌ 失败：单字被提前保存"))
    fail += 0 if ok else 1

    # ----------------------------------------------------------------
    print("\n【用例 2 · 词组累积：回到家、吃饱 → 也累积，不独立保存（v2.12 关键修复）】")
    L.execute("ctx.input = '`lgp'")
    processor(L.eval("make_key(112)"), L.eval("env"))
    L.execute("click_commit('回到家')")
    entries = db_manual_texts(L)
    ok = (entries == [])
    print("  回到家 上屏后 UserDb 永久词：%s" % (entries if entries else "(空)"))
    print("  %s" % ("✅ 通过：词组也进缓冲、不独立保存" if ok else "❌ 失败：词组被独立保存"))
    fail += 0 if ok else 1

    L.execute("ctx.input = '`ktq'")
    processor(L.eval("make_key(113)"), L.eval("env"))
    L.execute("click_commit('吃饱')")
    entries = db_manual_texts(L)
    ok = (entries == [])
    print("  吃饱 上屏后 UserDb 永久词：%s" % (entries if entries else "(空)"))
    print("  %s" % ("✅ 通过：第二个词组仍只进缓冲" if ok else "❌ 失败"))
    fail += 0 if ok else 1

    # ----------------------------------------------------------------
    print("\n【用例 3 · 空格但 input 非纯反引号 → 不结束（缓冲保留）】")
    L.execute("ctx.input = '`'")
    L.execute("ctx.input = '`rt'")   # 模拟：缓冲非空，但输入区是编码（非纯反引号）
    processor(L.eval("make_key(0x20)"), L.eval("env"))
    entries = db_manual_texts(L)
    ok = (entries == [])
    print("  空格后（input=`rt）UserDb 永久词：%s" % (entries if entries else "(空)"))
    print("  %s" % ("✅ 通过：非纯反引号 + 空格不结束" if ok else "❌ 失败：误触发结束"))
    fail += 0 if ok else 1

    # ----------------------------------------------------------------
    print("\n【用例 4 · 长按Z（input=`）再按空格 → 一次性保存整词】")
    L.execute("ctx.input = '`'")   # 长按Z → 纯反引号
    processor(L.eval("make_key(0x20)"), L.eval("env"))   # 空格
    entries = db_manual_texts(L)
    texts = {e.split("\t")[0] for e in entries}
    ok = ("之田回到家吃饱" in texts)
    print("  长按Z+空格后 UserDb 永久词：%s" % entries)
    print("  %s" % ("✅ 通过：缓冲合并成「之田回到家吃饱」保存" if ok else "❌ 失败：未保存"))
    fail += 0 if ok else 1

    # ----------------------------------------------------------------
    print("\n【用例 5 · 放弃：输入非反引号内容 → 清空缓冲，不保存】")
    L.execute("ctx.input = '`pp'")
    processor(L.eval("make_key(112)"), L.eval("env"))
    L.execute("click_commit('之')")            # 缓冲=[之]
    L.execute("ctx.input = 'k'")               # 用户转而正常输入（无反引号）
    processor(L.eval("make_key(107)"), L.eval("env"))   # → 放弃缓冲
    L.execute("ctx.input = '`'")
    processor(L.eval("make_key(0x20)"), L.eval("env"))   # 长按Z+空格（缓冲已空）
    entries = db_manual_texts(L)
    texts = {e.split("\t")[0] for e in entries}
    ok = ("之" not in texts)
    print("  放弃后再结束：词条集合 %s" % texts)
    print("  %s" % ("✅ 通过：缓冲被放弃，未保存「之」" if ok else "❌ 失败：残留「之」被保存"))
    fail += 0 if ok else 1

    shutil.rmtree(tmp, ignore_errors=True)
    print("\n" + "=" * 70)
    print("结论：%s" % ("全部通过" if fail == 0 else "%d 项失败（见上方 ❌）" % fail))
    print("=" * 70)
    return 0 if fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
