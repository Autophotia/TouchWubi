#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
自动造词新逻辑沙盒测试（auto_coined.lua + Submit_text.lua）

针对 2026-10-30 三个修复做白盒验证：
  修复 A  重复造主词典已有词 —— Submit_text.lua 暴露 auto_coined_in_main_dict；
           auto_coined.lua 的 build_phrases 跳过主词典已有词。
  修复 B  点击候选栏上屏入链 —— auto_coined.lua 接 update_notifier，
           点选上屏（Context::Select）当场结算，不等下一次按键。
  修复 C  注释头粘行 —— UserCoined_AppendManual 改为前导换行，产生第 4 行空行。

用法：python dev/tools/sandbox_auto_coined_test.py
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


def to_lua(p):
    return p.replace("\\", "/")


def build_runtime(user_dir, schema_dir):
    """构造 mock 了 librime 的 LuaRuntime（复用 sandbox_coined_test.py 的做法）"""
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
    tmp = tempfile.mkdtemp(prefix="touchwb_auto_")
    auto_path = os.path.join(tmp, "user_coined_auto.txt")
    manual_path = os.path.join(tmp, "user_coined_ext.txt")

    print("=" * 70)
    print("自动造词新逻辑沙盒测试（v2.2）")
    print("=" * 70)

    # ================================================================
    # 第一部分：Submit_text.lua 真实字典加载 —— 测 auto_coined_in_main_dict
    # ================================================================
    print("\n【修复 A · 主词典去重】auto_coined_in_main_dict 判定")
    L1 = build_runtime(tmp, SCHEMA_DIR)
    L1.eval("dofile([[%s]])" % to_lua(SUBMIT_LUA))
    g1 = L1.globals()
    f_has = g1.auto_coined_in_main_dict

    def check_has(word, expect):
        got = f_has(word)
        ok = bool(got) == bool(expect)
        print("  in_main_dict(%r) = %s  (期望 %s)  %s"
              % (word, got, expect, "✅" if ok else "❌"))
        return ok

    fail += 0 if check_has("数据", True) else 1
    fail += 0 if check_has("最好", True) else 1
    fail += 0 if check_has("造词", True) else 1
    fail += 0 if check_has("编辑", True) else 1
    fail += 0 if check_has("中国", True) else 1
    fail += 0 if check_has("万灵药", False) else 1   # 主词典没有
    fail += 0 if check_has("自动造词", False) else 1  # 主词典没有
    fail += 0 if check_has("有点卡", False) else 1    # 主词典没有
    fail += 0 if check_has("", False) else 1

    # ================================================================
    # 第二部分：UserCoined_AppendManual 前导换行 → 第 4 行空行
    # ================================================================
    print("\n【修复 C · 注释头粘行】UserCoined_AppendManual 前导换行")
    L2 = build_runtime(tmp, SCHEMA_DIR)
    L2.eval("dofile([[%s]])" % to_lua(SUBMIT_LUA))
    g2 = L2.globals()
    append = g2.UserCoined_AppendManual

    append("万灵药", "dvax")
    append("自动造词", "tfty")
    lines = raw_lines(manual_path)
    print("  转正后的 user_coined_ext.txt：")
    for i, ln in enumerate(lines, 1):
        print("    %d| %r" % (i, ln))

    # 期望：3 行注释头 + 1 行空 + 2 行数据 = 6 行（最后一行数据无尾换行）
    ok = (len(lines) == 6
          and lines[0].startswith("#")
          and lines[1].startswith("#")
          and lines[2].startswith("#")
          and lines[3] == ""
          and lines[4] == "万灵药\tdvax"
          and lines[5] == "自动造词\ttfty")
    print("  %s" % ("✅ 通过：3 头 + 空行 + 数据，无粘行" if ok else "❌ 失败"))
    fail += 0 if ok else 1

    # 再追加一条，验证「不会出现双空行、不会粘行」
    append("有点卡", "dhhh")
    lines = raw_lines(manual_path)
    ok = (len(lines) == 7 and lines[5] == "自动造词\ttfty" and lines[6] == "有点卡\tdhhh")
    print("  再追加一条：%s" % ("✅ 通过" if ok else "❌ 失败"))
    fail += 0 if ok else 1

    # ================================================================
    # 第三部分：auto_coined.lua 点击候选栏上屏（update_notifier）
    # ================================================================
    print("\n【修复 B · 点击候选栏上屏】auto_coined.lua update_notifier 结算")
    L3 = build_runtime(tmp, SCHEMA_DIR)

    # 注入 mock 全局（auto_coined.lua 运行期依赖）
    L3.execute("""
        -- 确定性唯一编码：递增计数器，避免不同窗口词撞码（撞码会被 build_phrases 抑制）
        code_seq = 0
        auto_coined_stdcode = function(phrase)
            code_seq = code_seq + 1
            return string.format("a%03d", code_seq % 1000)
        end
        -- 主词典判定：数据 / 银行 视为主词典已有
        auto_coined_in_main_dict = function(phrase)
            return phrase == "数据" or phrase == "银行"
        end
        get_autophrase_path = function() return [[__AUTO_PATH__]] end
        get_userphrase_path = function() return [[__MANUAL_PATH__]] end
        UserCoined_AppendManual = function(text, code) return true end
        UserCoined_InvalidateCache = function() end
    """.replace("__AUTO_PATH__", to_lua(auto_path)).replace("__MANUAL_PATH__", to_lua(manual_path)))

    # 构造 mock context / engine / key
    L3.execute("""
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

        -- 模拟一次「点候选栏上屏」：commit_history 变化 + update_notifier 触发
        function click_commit(text)
            ctx.commit_history.size = ctx.commit_history.size + 1
            ctx.commit_history.entry = { text = text }
            if ctx.update_notifier.fn then ctx.update_notifier.fn(ctx) end
        end
    """)

    # 加载 auto_coined.lua，取 P.func
    P = L3.eval("dofile([[%s]])" % to_lua(AUTO_LUA))
    p_func = P["P"]["func"]

    # 首次按键（字母键，keycode 97 = 'a'）→ 连接 notifier + 建立基线
    p_func(L3.eval("make_key(97)"), L3.eval("env"))

    # 连点两个词（模拟点候选栏上屏，无任何按键事件）
    L3.execute("click_commit('数据')")
    L3.execute("click_commit('银行')")

    entries = read_non_comment(auto_path)
    print("  点选「数据」「银行」后 user_coined_auto.txt 内容：%s" % entries)
    texts = {e.split("\t")[0] for e in entries}
    # v2.3 起逐词上屏按字拆分，应造出「数据银」「据银」等字级窗口；
    # 主词典已有的「数据」「银行」应被过滤。
    ok = ("数据银" in texts) and ("据银" in texts) \
         and ("数据" not in texts) and ("银行" not in texts)
    print("  %s" % ("✅ 通过：点选入链且按字造出「数据银」等窗口，主词典「数据/银行」被跳过"
                    if ok else "❌ 失败"))
    fail += 0 if ok else 1

    # 验证同一提交不会被重复结算：把 notifier 再触发一次，不应多造词
    before = len(entries)
    L3.execute("if ctx.update_notifier.fn then ctx.update_notifier.fn(ctx) end")
    after = len(read_non_comment(auto_path))
    ok = (before == after)
    print("  重复触发 notifier：词条数 %d → %d  %s" % (before, after,
          "✅ 通过（无重复结算）" if ok else "❌ 失败（被重复结算）"))
    fail += 0 if ok else 1

    shutil.rmtree(tmp, ignore_errors=True)
    print("\n" + "=" * 70)
    print("结论：%s" % ("全部通过" if fail == 0 else "%d 项失败（见上方 ❌）" % fail))
    print("=" * 70)
    return 0 if fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
