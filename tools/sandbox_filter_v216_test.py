#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
wubi_pinyin_filter.lua v2.16 沙盒测试

针对 2026-10-31 v2.16 两处修复做白盒验证：
  1. 纯反引号（input=`，无编码字母）不吐任何候选 —— 恢复「长按Z再按空格=结束造词」信号态；
  2. 反引号段第 5 码（`ruujd）候选的 span 拉满整串（含反引号），点选后第 5 码不再残留成「接单d」。

用法：python dev/tools/sandbox_filter_v216_test.py
"""
import os
import sys

from lupa import LuaRuntime

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LUA_DIR = os.path.join(ROOT, "space", "schemas", "TouchWB", "lua")
FILTER_LUA = os.path.join(LUA_DIR, "wubi_pinyin_filter.lua")


def to_lua(p):
    return p.replace("\\", "/")


def main():
    fail = 0
    L = LuaRuntime(unpack_returned_tuples=True)
    L.execute("package.path = [[%s/?.lua;]] .. package.path" % to_lua(LUA_DIR))

    # ---- 全局 mock：Candidate / ReverseDb / config / env / input / yield ----
    L.execute("""
        Candidate = function(ctype, s, e, text, comment, preedit)
            return { type=ctype, start=s, _end=e, text=text,
                     comment=comment or "", preedit=preedit or "", quality=0 }
        end
        -- 反查库：字→[字根,五笔码,拼音,字符集]，拼音用于第5码首字母筛选
        local rev = {
            ['接'] = '[接,ruv,jie,1]',
            ['单'] = '[单,ujf,dan,1]',
            ['手'] = '[手,rt,shou,1]',
            ['动'] = '[动,fcl,dong,1]',
        }
        ReverseDb = function(path)
            return { lookup = function(self, ch) return rev[ch] end }
        end
        config = {
            get_list = function(self, path)
                return { size = 0, get_value_at = function() return nil end }
            end,
            get_string = function(self, path)
                if path == 'lua_reverse_db/spelling' then return 'wb_spelling' end
                return nil
            end,
            get_bool = function(self, path)
                if path == 'engine/mixed_input' then return true end
                if path == 'wubi_pinyin_filter/use_key_pairs' then return false end
                if path == 'wubi_pinyin_filter/use_last_char' then return true end
                return nil
            end,
            get_int = function(self, path) return nil end,
        }
        ctx = { input = "" }
        env = {
            engine = { context = ctx, schema = { config = config } },
        }
        function set_input(s) ctx.input = s end

        -- 可重设的候选列表 + iter
        candidates = {}
        input_mock = {
            iter = function(self)
                local i, n = 0, #candidates
                return function()
                    i = i + 1
                    if i <= n then return candidates[i] end
                    return nil
                end
            end,
        }
        results = {}
        function yield(c) results[#results + 1] = c end
        function reset_results() results = {} end
    """)

    mod = L.eval("dofile([[%s]])" % to_lua(FILTER_LUA))
    mod["init"](L.eval("env"))
    filter_func = mod["func"]

    print("=" * 70)
    print("wubi_pinyin_filter v2.16 沙盒测试")
    print("=" * 70)

    # ----------------------------------------------------------------
    print("\n【用例 1 · 纯反引号 input=` 不吐候选】")
    L.execute("""
        set_input('`')
        reset_results()
        candidates = {
            Candidate('completion', 0, 1, '的', 'r', ''),
            Candidate('completion', 0, 1, '一', 'g', ''),
            Candidate('completion', 0, 1, '是', 'j', ''),
        }
    """)
    filter_func(L.eval("input_mock"), L.eval("env"))
    n = int(L.eval("#results"))
    ok = (n == 0)
    print("  纯反引号下 yield 候选数：%d" % n)
    print("  %s" % ("✅ 通过：纯反引号无候选（结束信号态恢复）" if ok else "❌ 失败：仍吐了 %d 条候选" % n))
    fail += 0 if ok else 1

    # ----------------------------------------------------------------
    print("\n【用例 2 · 反引号段第 5 码 `ruujd → 接单 span 拉满 0..6】")
    L.execute("""
        set_input('`ruujd')
        reset_results()
        candidates = {
            -- 五笔匹配只吃掉前 4 码 `ruuj（_end=5），第 5 码 d 残留
            Candidate('table', 0, 5, '接单', 'ruuj', ''),
        }
    """)
    filter_func(L.eval("input_mock"), L.eval("env"))
    n = int(L.eval("#results"))
    got = L.eval("#results > 0 and results[1].text or ''")
    st = L.eval("#results > 0 and results[1].start or -1")
    en = L.eval("#results > 0 and results[1]._end or -1")
    ok = (n == 1 and got == "接单" and st == 0 and en == 6)
    print("  候选数=%d text=%s span=[%s..%s]" % (n, got, st, en))
    print("  %s" % ("✅ 通过：第 5 码被消费（span 0..6，点选不再残留「接单d」）"
                   if ok else "❌ 失败：span 未拉满"))
    fail += 0 if ok else 1

    # ----------------------------------------------------------------
    print("\n【用例 3 · 反引号段 4 码 `rtfc → 手动 span 不破坏（仍原样 yield）】")
    L.execute("""
        set_input('`rtfc')
        reset_results()
        candidates = {
            Candidate('table', 0, 5, '手动', 'rtfc', ''),
        }
    """)
    filter_func(L.eval("input_mock"), L.eval("env"))
    n = int(L.eval("#results"))
    ok = (n == 1)
    print("  4 码反引号段候选数：%d" % n)
    print("  %s" % ("✅ 通过：4 码正常出候选" if ok else "❌ 失败"))
    fail += 0 if ok else 1

    # ----------------------------------------------------------------
    print("\n【用例 4 · 计算器 =1+1（纯符号，非反引号）→ 仍 yield 候选，不误伤】")
    L.execute("""
        set_input('=1+1')
        reset_results()
        candidates = {
            Candidate('lua', 0, 4, '2', '', ''),
        }
    """)
    filter_func(L.eval("input_mock"), L.eval("env"))
    n = int(L.eval("#results"))
    ok = (n == 1)
    print("  =1+1 候选数：%d" % n)
    print("  %s" % ("✅ 通过：纯符号（计算器）候选保留" if ok else "❌ 失败：计算器候选被误清空"))
    fail += 0 if ok else 1

    print("\n" + "=" * 70)
    print("结论：%s" % ("全部通过" if fail == 0 else "%d 项失败（见上方 ❌）" % fail))
    print("=" * 70)
    return 0 if fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
