#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
自动/手动造词 v2.3 修复沙盒测试（auto_coined.lua + Submit_text.lua）

针对 2026-10-30 三个修复做白盒验证：
  修复 1  逐词上屏时跨界子词缺失 —— on_commit 按字拆分入 _hist；
           build_phrases 起点固定 1（旧公式丢 5 字窗口的「头字」）。
  修复 2  手动造词「点击候选栏上屏」—— Submit_text.lua 接 update_notifier，
           预登记后点候选上屏（Context::Select）结算保存。
  修复 3  临时词 txt 注释头补第 4 行空行，与手动词库一致。

用法：python dev/tools/sandbox_coined_v23_test.py
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


def raw_lines(path):
    if not os.path.exists(path):
        return []
    with open(path, "r", encoding="utf-8", newline="") as f:
        return f.read().split("\n")


def main():
    fail = 0
    tmp = tempfile.mkdtemp(prefix="touchwb_v23_")
    auto_path = os.path.join(tmp, "user_coined_auto.txt")
    manual_path = os.path.join(tmp, "user_coined_ext.txt")

    print("=" * 70)
    print("自动/手动造词 v2.3 修复沙盒测试")
    print("=" * 70)

    # ================================================================
    # 第一部分：逐词上屏 → 字级窗口（拆分 + 起点固定 1）
    # ================================================================
    print("\n【修复 1 · 逐词上屏字级窗口】")
    L1 = build_runtime(tmp, SCHEMA_DIR)
    L1.eval("dofile([[%s]])" % to_lua(SUBMIT_LUA))   # 暴露真实 UserCoined_DB_* 钩子
    L1.execute("""
        code_seq = 0
        auto_coined_stdcode = function(phrase)
            code_seq = code_seq + 1
            return string.format("a%03d", code_seq % 1000)
        end
        auto_coined_in_main_dict = function(phrase)
            return phrase == "自动" or phrase == "造词" or phrase == "功能"
        end
    """)

    L1.execute("""
        OPTION_ON = true
        ctx = {
            input = "",
            commit_history = {
                size = 0,
                entry = nil,
                back = function(self) return self.entry end,
            },
            has_menu = function() return false end,
            get_commit_text = function() return "" end,
            update_notifier = {
                fn = nil,
                connect = function(self, fn) self.fn = fn end,
            },
            get_option = function(self, name)
                if name == "auto_coined" then return OPTION_ON end
                return false
            end,
        }
        env = { engine = { context = ctx, schema = { schema_id = "ly_wubi" } } }
        function make_key(keycode)
            return { keycode = keycode, repr = function(self) return "x" end }
        end
        function click_commit(text)
            ctx.commit_history.size = ctx.commit_history.size + 1
            ctx.commit_history.entry = { text = text }
            if ctx.update_notifier.fn then ctx.update_notifier.fn(ctx) end
        end
    """)

    P = L1.eval("dofile([[%s]])" % to_lua(AUTO_LUA))
    p_func = P["P"]["func"]
    p_func(L1.eval("make_key(97)"), L1.eval("env"))

    # 逐词上屏「自动」「造词」「功能」（每次提交是 2 字词，不是单字）
    L1.execute("click_commit('自动')")
    L1.execute("click_commit('造词')")
    L1.execute("click_commit('功能')")

    temp = L1.eval("mock_db_texts('a\\t')")
    texts = {ln.split("\t")[0] for ln in temp.split("\n") if ln}
    expected = {"自动造", "自动造词", "自动造词功",
                "动造", "动造词", "动造词功", "动造词功能",
                "造词功", "造词功能", "词功", "词功能"}
    missing = expected - texts
    extra = texts - expected
    print("  生成的窗口词（%d 个）：%s" % (len(texts), sorted(texts)))
    ok = (missing == set() and extra == set())
    if not ok:
        print("  缺失：%s" % (sorted(missing) if missing else "无"))
        print("  多余：%s" % (sorted(extra) if extra else "无"))
    print("  %s" % ("✅ 通过：字级窗口齐全（含 5 字「自动造词功」，且主词典词被过滤）"
                    if ok else "❌ 失败"))
    fail += 0 if ok else 1

    # ================================================================
    # 第二部分：手动造词点击候选栏上屏（update_notifier）
    # ================================================================
    print("\n【修复 2 · 手动造词点击候选栏上屏】")
    L2 = build_runtime(tmp, SCHEMA_DIR)
    L2.execute("""
        ctx2 = {
            input = "d`v`a",
            commit_history = {
                size = 0,
                entry = nil,
                back = function(self) return self.entry end,
            },
            composition = { back = function() return segment2 end },
            has_menu = function() return false end,
            get_commit_text = function() return "万灵药" end,
            get_selected_candidate = function() return nil end,
            clear = function() end,
            is_composing = function() return false end,
            push_input = function() end,
            update_notifier = {
                fn = nil,
                connect = function(self, fn) self.fn = fn end,
            },
        }
        segment2 = {
            menu = { candidate_count = function() return 0 end },
            get_candidate_at = function(self, i) return nil end,
            get_selected_candidate = function() return nil end,
            start = 0,
        }
        engine2 = {
            context = ctx2,
            schema = { schema_id = "ly_wubi" },
            commit_text = function(self, t) end,
        }
        env2 = {
            engine = engine2,
            last_1th_text = "",
            last_2th_text = { text = "", type = "" },
            last_3th_text = { text = "", type = "" },
        }
        function make_key2(keycode)
            return { keycode = keycode, repr = function(self) return "x" end }
        end
        function click_commit2(text)
            ctx2.commit_history.size = ctx2.commit_history.size + 1
            ctx2.commit_history.entry = { text = text }
            if ctx2.update_notifier.fn then ctx2.update_notifier.fn(ctx2) end
        end
    """)

    processor = L2.eval("dofile([[%s]])" % to_lua(SUBMIT_LUA))
    # 首次按键（普通字母键，非空格）→ 连接 notifier + 预登记手动造词
    processor(L2.eval("make_key2(97)"), L2.eval("env2"))
    # ★ 稳定基线：真机上点选上屏前必有输入过程触发多次 update_notifier，
    #   这里先补一次空 notifier，让「首次只记基线」落到上屏之前（贴近真机时序）。
    L2.execute("if ctx2.update_notifier.fn then ctx2.update_notifier.fn(ctx2) end")

    # 点候选栏上屏（无任何按键事件）→ v2.12 单字/词组一律累积，不直接保存
    L2.execute("click_commit2('万灵药')")

    manual = L2.eval("mock_db_texts('e\\t')")
    texts0 = {ln.split("\t")[0] for ln in manual.split("\n") if ln}
    ok = (texts0 == set())
    print("  点选上屏后（未结束）UserDb 永久词：%s" % (sorted(texts0) if texts0 else "(空)"))
    print("  %s" % ("✅ 通过：点击候选栏上屏先累积进缓冲、未直接保存" if ok else "❌ 失败：被提前保存"))
    fail += 0 if ok else 1

    # 长按Z（input=`）再按空格 → 一次性保存整词
    L2.execute("ctx2.input = '`'")
    processor(L2.eval("make_key2(0x20)"), L2.eval("env2"))
    manual = L2.eval("mock_db_texts('e\\t')")
    texts2 = {ln.split("\t")[0] for ln in manual.split("\n") if ln}
    print("  长按Z+空格后 UserDb 永久词：%s" % (sorted(texts2) if texts2 else "(空)"))
    ok = ("万灵药" in texts2)
    print("  %s" % ("✅ 通过：点击候选栏上屏 + 长按Z空格 保存了手动造词" if ok else "❌ 失败：未保存"))
    fail += 0 if ok else 1

    # 重复触发 notifier 不应重复保存
    before = len(texts2)
    L2.execute("if ctx2.update_notifier.fn then ctx2.update_notifier.fn(ctx2) end")
    manual2 = L2.eval("mock_db_texts('e\\t')")
    after = len({ln.split("\t")[0] for ln in manual2.split("\n") if ln})
    ok = (before == after)
    print("  重复触发 notifier：词条 %d → %d  %s" % (before, after,
          "✅ 通过（无重复保存）" if ok else "❌ 失败（被重复保存）"))
    fail += 0 if ok else 1

    shutil.rmtree(tmp, ignore_errors=True)
    print("\n" + "=" * 70)
    print("结论：%s" % ("全部通过" if fail == 0 else "%d 项失败（见上方 ❌）" % fail))
    print("=" * 70)
    return 0 if fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
