#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
new_spelling.lua 自造词候选保留 沙盒测试（2026-10-31 v2.17 修复）

针对根因做白盒验证：new_spelling 以前会用字根/拼音注解覆盖 user_coined 候选的
comment（原为「编码☯」），导致下游 wubi_pinyin_filter 的 get_candidate_wubi_code
取到拼音（如 pinyinke）而非编码（rusk）⇒ 编码不匹配被丢弃 ⇒ 自造词「打不出来」。

修复：new_spelling 对 type=user_coined 的候选原样放行（不做注解、不覆盖 comment）。

本测试验证：
  1. 隐根模式：user_coined 候选 comment 不被覆盖（保持「编码☯」）；
  2. 显根模式：user_coined 候选 comment 不被覆盖；
  3. 端到端：new_spelling 放行的 user_coined 候选，能被 wubi_pinyin_filter 按编码匹配保留。

用法：python dev/tools/sandbox_newspelling_coin_test.py
"""
import os
import sys

from lupa import LuaRuntime

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LUA_DIR = os.path.join(ROOT, "space", "schemas", "TouchWB", "lua")
NEW_SPELLING_LUA = os.path.join(LUA_DIR, "new_spelling.lua")
FILTER_LUA = os.path.join(LUA_DIR, "wubi_pinyin_filter.lua")


def to_lua(p):
    return p.replace("\\", "/")


def build_env(L, script_text, spelling_states):
    """构造 new_spelling filter 所需的最小环境。"""
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
            local rev = {
                ['拼'] = '[扌,rua,pin,1]',
                ['音'] = '[立,ujf,yin,1]',
                ['可'] = '[丁,skd,ke,1]',
                ['拉'] = '[扌,ru,la,1]',
            }
            return { lookup = function(self, ch) return rev[ch] end }
        end
        config = {
            get_list = function(self, path)
                return { size = 0, get_value_at = function() return nil end }
            end,
            get_list_size = function(self, path) return 0 end,
            get_string = function(self, path)
                if path == 'lua_reverse_db/spelling' then return 'wb_spelling' end
                if path == 'lua_reverse_db/code' then return 'wb_spelling' end
                return nil
            end,
            get_bool = function(self, path)
                if path == 'engine/mixed_input' then return true end
                return nil
            end,
            get_int = function(self, path) return nil end,
        }
        opts = {
            new_hide_pinyin = true,   -- 显拼音（会触发覆盖 comment 的路径）
            new_hide_code = true,     -- 显编码
        }
        ctx = {
            input = [[%s]],
            get_script_text = function(self) return self.input end,
            get_option = function(self, name) return opts[name] end,
            composition = { back = function() return { start=0, _end=#ctx.input } end },
        }
        env = {
            engine = { context = ctx, schema = { schema_id='ly_wubi_pinyin', config=config } },
        }
        function set_spelling(v) opts.new_spelling = v end
        function set_phrase_pinyin(v) opts.new_phrase_pinyin = v end
    """ % script_text)


def run_filter(L, filter_func, candidates):
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
    """ % candidates)
    filter_func(L.eval("input_mock"), L.eval("env"))
    return L.eval("results")


def main():
    fail = 0
    L = LuaRuntime(unpack_returned_tuples=True)
    L.execute("package.path = [[%s/?.lua;]] .. package.path" % to_lua(LUA_DIR))

    ns_mod = L.eval("dofile([[%s]])" % to_lua(NEW_SPELLING_LUA))
    ns_init = ns_mod["init"]
    ns_func = ns_mod["func"]

    wf_mod = L.eval("dofile([[%s]])" % to_lua(FILTER_LUA))

    print("=" * 70)
    print("new_spelling 自造词候选保留 沙盒测试（v2.17 修复）")
    print("=" * 70)

    # 用户自造词候选：comment 是「编码☯」，这是 wubi_pinyin_filter 匹配编码的唯一依据
    user_coined_cand = ("Candidate('user_coined', 0, 5, '拼音可', 'rusk☯', '')")

    # ----------------------------------------------------------------
    print("\n【用例 1 · 隐根模式：user_coined comment 不被覆盖】")
    build_env(L, '`rusk', False)
    L.execute("set_spelling(false); set_phrase_pinyin(false)")
    ns_init(L.eval("env"))
    res = run_filter(L, ns_func, "{ %s }" % user_coined_cand)
    n = len(res)
    comment = res[1]["comment"] if n else ""
    ok = (n == 1 and "rusk" in comment and "☯" in comment)
    print("  隐根模式 user_coined 候选数=%d comment=%s" % (n, comment))
    print("  %s" % ("✅ 通过：comment 保留「编码☯」" if ok else "❌ 失败：comment 被覆盖=%s" % comment))
    fail += 0 if ok else 1

    # ----------------------------------------------------------------
    print("\n【用例 2 · 显根模式：user_coined comment 不被覆盖】")
    build_env(L, '`rusk', True)
    L.execute("set_spelling(true); set_phrase_pinyin(false)")
    ns_init(L.eval("env"))
    res = run_filter(L, ns_func, "{ %s }" % user_coined_cand)
    n = len(res)
    comment = res[1]["comment"] if n else ""
    ok = (n == 1 and "rusk" in comment and "☯" in comment)
    print("  显根模式 user_coined 候选数=%d comment=%s" % (n, comment))
    print("  %s" % ("✅ 通过：comment 保留「编码☯」" if ok else "❌ 失败：comment 被覆盖=%s" % comment))
    fail += 0 if ok else 1

    # ----------------------------------------------------------------
    print("\n【用例 3 · 端到端：user_coined 候选经 new_spelling 后能被 wubi_pinyin_filter 按编码保留】")
    build_env(L, '`rusk', False)
    L.execute("set_spelling(false); set_phrase_pinyin(false)")
    ns_init(L.eval("env"))
    # 模拟候选流：user_coined「拼音可」(rusk) + sentence「拉可」(rusk)
    res = run_filter(L, ns_func,
                     "{ %s, Candidate('sentence', 0, 5, '拉可', 'rusk', '') }" % user_coined_cand)
    # 把 new_spelling 的输出喂给 wubi_pinyin_filter
    wf_init = wf_mod["init"]
    wf_func = wf_mod["func"]
    L.execute("""
        ctx2 = { input = '`rusk' }
        env2 = { engine = { context = ctx2, schema = { config = config } } }
        function set_input2(s) ctx2.input = s end
    """)
    wf_init(L.eval("env2"))
    # 用 new_spelling 的产物构造 wf 的输入
    L.execute("""
        ns_results = results
        input_mock2 = {
            iter = function(self)
                local i, n = 0, #ns_results
                return function()
                    i = i + 1
                    if i <= n then return ns_results[i] end
                    return nil
                end
            end,
        }
        wf_texts = {}
        function yield(c) wf_texts[#wf_texts + 1] = c.text end
    """)
    wf_func(L.eval("input_mock2"), L.eval("env2"))
    texts = L.eval("table.concat(wf_texts, ',')")
    ok = ("拼音可" in texts)
    print("  wubi_pinyin_filter 输出候选 text=%s" % texts)
    print("  %s" % ("✅ 通过：「拼音可」按编码 rusk 保留" if ok else "❌ 失败：「拼音可」被丢弃"))
    fail += 0 if ok else 1

    print("\n" + "=" * 70)
    print("结论：%s" % ("全部通过" if fail == 0 else "%d 项失败（见上方 ❌）" % fail))
    print("=" * 70)
    return 0 if fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
