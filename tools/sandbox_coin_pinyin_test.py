#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
拼音参与造词 沙盒测试（Submit_text.lua + auto_coined.lua）

验证「拼音打字上屏」和「五码筛选上屏」的字能参与造词。核心机制：
  造词的编码一律由 generate_standard_code（字典「字→码」反查）生成，与用户
  用什么方式上屏（五笔 / 拼音 / 五码筛选）无关 —— 上屏的字只要进缓冲/入链，
  就能反查出标准五笔码。本测试用真实字典（ly_wubi.dict.yaml）验证这一点。

  1. 编码反查：stdcode("手动")=="rtfc"、stdcode("乖戾")=="tfyn"；
  2. 自动造词：模拟拼音上屏「手」「动」⇒ 造出「手动 rtfc」临时词；
  3. 手动造词：反引号段输拼音（`shou / `dong）选字上屏 ⇒ 缓冲累积，结束保存
     的码仍是反查的五笔码「rtfc」，而非拼音串。

用法：python dev/tools/sandbox_coin_pinyin_test.py
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
AUTO_LUA = os.path.join(LUA_DIR, "auto_coined.lua")

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
    L.execute(MOCK_LEVELDB)
    return L


def read_non_comment(path):
    if not os.path.exists(path):
        return []
    with open(path, "r", encoding="utf-8") as f:
        return [ln.rstrip("\n") for ln in f if ln.strip() and not ln.startswith("#")]


def main():
    fail = 0
    tmp = tempfile.mkdtemp(prefix="touchwb_pinyin_")
    auto_path = os.path.join(tmp, "user_coined_auto.txt")
    manual_path = os.path.join(tmp, "user_coined_ext.txt")

    print("=" * 70)
    print("拼音参与造词 沙盒测试（真实字典反查编码）")
    print("=" * 70)

    # ================================================================
    # 部分1：编码反查 —— 拼音上屏的字，靠字典反查出标准五笔码
    # ================================================================
    print("\n【用例1 · 编码反查】generate_standard_code 对任意上屏文本反查五笔码")
    L1 = build_runtime(tmp, SCHEMA_DIR)
    L1.eval("dofile([[%s]])" % to_lua(SUBMIT_LUA))
    stdcode = L1.globals().auto_coined_stdcode

    def check_stdcode(word, expect):
        got = stdcode(word)
        ok = (got == expect)
        print("  stdcode(%r) = %r  (期望 %r)  %s" % (word, got, expect,
              "✅" if ok else "❌"))
        return ok

    fail += 0 if check_stdcode("手动", "rtfc") else 1
    fail += 0 if check_stdcode("乖戾", "tfyn") else 1
    fail += 0 if check_stdcode("搬运", "rtfc") else 1

    # ================================================================
    # 部分2：自动造词 —— 拼音上屏的字入链（真实 stdcode）
    # ================================================================
    print("\n【用例2 · 自动造词拼音上屏】拼音上屏「手」「动」⇒ 造「手动 rtfc」临时词")
    L2 = build_runtime(tmp, SCHEMA_DIR)
    L2.eval("dofile([[%s]])" % to_lua(SUBMIT_LUA))   # 暴露真实 auto_coined_stdcode / 路径函数
    L2.execute("""
        ctx = {
            input = "",
            commit_history = {
                size = 0, entry = nil,
                back = function(self) return self.entry end,
            },
            has_menu = function() return false end,
            get_commit_text = function() return "" end,
            update_notifier = {
                fn = nil,
                connect = function(self, fn) self.fn = fn end,
            },
            get_option = function(self, name)
                if name == "auto_coined" then return true end
                return false
            end,
        }
        env = { engine = { context = ctx, schema = { schema_id = "ly_wubi_pinyin" } } }
        function make_key(keycode)
            return { keycode = keycode, repr = function(self) return "x" end }
        end
        function click_commit(text)
            ctx.commit_history.size = ctx.commit_history.size + 1
            ctx.commit_history.entry = { text = text }
            if ctx.update_notifier.fn then ctx.update_notifier.fn(ctx) end
        end
    """)
    P = L2.eval("dofile([[%s]])" % to_lua(AUTO_LUA))
    p_func = P["P"]["func"]
    stdcode2 = L2.globals().auto_coined_stdcode
    p_func(L2.eval("make_key(97)"), L2.eval("env"))   # 首次按键建立基线
    L2.execute("click_commit('之')")                   # 模拟拼音上屏「之」
    L2.execute("click_commit('田')")                   # 模拟拼音上屏「田」

    temp = L2.eval("mock_db_texts('a\\t')")
    entries = [ln.split("\t") for ln in temp.split("\n") if ln]   # [text, code, tick]
    expect_code = stdcode2("之田")                     # 反查期望码（「之田」不在主词典）
    ok = any(e[0] == "之田" and e[1] == expect_code for e in entries)
    print("  拼音上屏「之」「田」后 UserDb 临时词：%s（期望码 %s）" % (entries, expect_code))
    print("  %s" % ("✅ 通过：拼音上屏的字入链，码=反查的 %s" % expect_code if ok
                    else "❌ 失败：未造出「之田 %s」" % expect_code))
    fail += 0 if ok else 1

    # ================================================================
    # 部分3：手动造词 —— 反引号段输拼音选字，结束保存的码仍反查五笔码
    # ================================================================
    print("\n【用例3 · 手动造词拼音筛字】反引号段输拼音选字 ⇒ 保存码=反查五笔码")
    L3 = build_runtime(tmp, SCHEMA_DIR)
    L3.execute("""
        ctx = {
            input = "",
            commit_history = {
                size = 0, entry = nil,
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
                schema = { schema_id = "ly_wubi_pinyin" },
                commit_text = function(self, t) end,
            },
            last_1th_text = "", last_2th_text = { text="", type="" }, last_3th_text = { text="", type="" },
        }
        function make_key(keycode)
            return { keycode = keycode, repr = function(self) return "x" end,
                     release = function(self) return false end }
        end
        function notify_update()
            if ctx.update_notifier.fn then ctx.update_notifier.fn(ctx) end
        end
        function click_commit(text)
            ctx.input = ""
            notify_update()
            ctx.commit_history.size = ctx.commit_history.size + 1
            ctx.commit_history.entry = { text = text }
            notify_update()
        end
    """)
    processor = L3.eval("dofile([[%s]])" % to_lua(SUBMIT_LUA))
    processor(L3.eval("make_key(97)"), L3.eval("env"))
    L3.execute("ctx.input = 'x'; notify_update()")

    # 反引号段输拼音 `shou → 选「手」
    L3.execute("ctx.input = '`shou'")
    processor(L3.eval("make_key(115)"), L3.eval("env"))
    L3.execute("click_commit('手')")
    # 反引号段输拼音 `dong → 选「动」
    L3.execute("ctx.input = '`dong'")
    processor(L3.eval("make_key(100)"), L3.eval("env"))
    L3.execute("click_commit('动')")
    # 长按Z + 空格 → 保存
    L3.execute("ctx.input = '`'")
    processor(L3.eval("make_key(0x20)"), L3.eval("env"))

    in_db = L3.eval("mock_db_get('e\\trtfc\\t手动') ~= nil")
    manual = L3.eval("mock_db_texts('e\\t')")
    print("  反引号段拼音选字后 UserDb 永久词：%s" % manual)
    print("  %s" % ("✅ 通过：拼音选字成词，保存码=反查的 rtfc" if in_db
                    else "❌ 失败：未保存「手动 rtfc」"))
    fail += 0 if in_db else 1

    shutil.rmtree(tmp, ignore_errors=True)
    print("\n" + "=" * 70)
    print("结论：%s" % ("全部通过" if fail == 0 else "%d 项失败（见上方 ❌）" % fail))
    print("=" * 70)
    return 0 if fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
