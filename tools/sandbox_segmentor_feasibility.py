#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
「方向 A」可行性探针：用 lua_segmentor 取代 script_translator@wubi_prefix
================================================================

前一轮提出「方向 A」：写一个 lua_segmentor，当输入是「纯五笔码且长度 ≥5」时
在第 4 码后主动切一刀（切出 [0,4) + [4,5)），让 table_translator 拿到 [0,4) 段
产出「前 4 码命中」候选（_end=4），从而甩掉 script_translator。

本沙盒只验证「纯 Lua 侧可证伪」的那部分——切段后 wubi_pinyin_filter 的
第 5 码筛选语义是否被破坏（这是方向 A 的关键连锁风险）。

───────── 两个坑的源码级结论（本沙盒不重复验证，只作事实陈述）─────────

【坑 1 · matcher / lua_segmentor 时序】（已查 librime 官方源码定论）
  - CalculateSegmentation（engine.cc）：每轮从 segmentors_[0] 依次 Proceed，
    **任一返回 false 即 break 该轮**。
  - FallbackSegmentor::Proceed（fallback_segmentor.cc）：三条 return 路径**恒 false**
    （源码注释 "fallback segmentor should be the last being called, so end this round"）。
  - 本方案 segmentors 末尾是：
        ... → punct_segmentor → fallback_segmentor → lua_segmentor@*pair_punct*segmentor
    ⇒ fallback 恒 false 会 break，**排在其后的 lua_segmentor 永远不会被调用**。
    ⇒ 前一轮「pair_punct 已用 lua_segmentor 主动切段、证明 lua_segmentor 可用」的
       前提不成立——那个 lua_segmentor 其实是死代码。
  - 即便把新 lua_segmentor 挪到 abc_segmentor 之前、fallback 之前（必须动
    segmentors 顺序 = 项目铁律红线），切段后也会连锁破坏 filter 语义（见下）。

【坑 2 · table_translator 切分后 quality 是否带词频】（已查源码定论）
  - table_translator（官方 table_translator.cc TableTranslation::Peek）：
        quality = exp(词频weight) + initial_quality + (completion?-1) + (user_phrase?+0.5)
  - script_translator（官方 script_translator.cc，即 wubi_prefix 现状）：
        quality = exp(词频weight) + initial_quality + (quality_len / full_code_length)
  - 两者**都含 exp(词频)**。⇒ 「衍生候选词频被清零」是误读：
    super_sequence.lua:1860 的「quality 恒为 0.0」指的是 **拼音反查（reverse_lookup）**
    候选，与 script_translator / table_translator 无关。
  - 结论：换不换 translator，词频都在，无需在 super_sequence 里单独重建。

───────── 本沙盒验证的两个命题（纯 Lua 可跑）─────────

  命题 A（现状已自洽）：≤4 码时 filter 已丢弃 script_translator 的「前缀短命中」
    （type=phrase、span 未吃满整串）⇒ script_translator 的 ≤4 码副作用已被控制。

  命题 B（方向 A 的致命伤）：切段后第 5 码变成独立 segment [4,5)，其候选
    （如「d」的简码候选）在 filter 第 5 码分支里被 matches_prefix(cand, 整串, 4)
    判 false 而整片丢弃 ⇒ 第 5 码不再是「筛选位」，而是被当独立输入翻译后清空，
    「用第 5 码筛前 4 码候选」这个跨段语义无从附着。

用法：python dev/tools/sandbox_segmentor_feasibility.py
依赖：lupa
"""
import os
import sys

from lupa import LuaRuntime

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LUA_DIR = os.path.join(ROOT, "space", "schemas", "TouchWB", "lua")
FILTER_LUA = os.path.join(LUA_DIR, "wubi_pinyin_filter.lua")

# 14 键 derive 规则（与 ly_wubi_pinyin_14.schema.yaml 一致）
DERIVES = ["derive/w/q/", "derive/r/e/", "derive/y/t/", "derive/i/u/",
           "derive/p/o/", "derive/s/a/", "derive/f/d/", "derive/h/g/",
           "derive/k/j/", "derive/c/x/", "derive/b/v/", "derive/m/n/"]


def to_lua(p):
    return p.replace("\\", "/")


def build_runtime():
    L = LuaRuntime(unpack_returned_tuples=True)
    L.execute("package.path = [[%s/?.lua;]] .. package.path" % to_lua(LUA_DIR))
    return L


def build_env(L, input_str):
    """构造 wubi_pinyin_filter 所需 env（14 键，混输方案）。"""
    items = ", ".join(["{ value = [[%s]] }" % d for d in DERIVES])
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
                if path == 'wubi_pinyin_filter/use_key_pairs' then return true end
                if path == 'engine/mixed_input' then return true end
                return nil
            end,
            get_int = function(self, path) return nil end,
        }
        ctx = { input = [[%s]] }
        env = { engine = { context = ctx, schema = { config = config } } }
    """ % (items, len(DERIVES), input_str))


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
        out.append("%s[%s:%s]" % (res[i]["text"], res[i]["start"], res[i]["_end"]))
    return ",".join(out) if out else "(空)"


def main():
    fail = 0
    L = build_runtime()
    wf_mod = L.eval("dofile([[%s]])" % to_lua(FILTER_LUA))
    wf_init = wf_mod["init"]
    wf_func = wf_mod["func"]

    print("=" * 72)
    print("方向 A（lua_segmentor 取代 script_translator）可行性探针")
    print("=" * 72)

    # ── 命题 A：≤4 码时 filter 已丢弃 script_translator 的 prefix 短命中 ──
    print("\n【命题 A】≤4 码时，script_translator 的前缀短命中已被 filter 控制")
    print("  输入 tane（4 码）：精确命中「物极必反」(_end=4) vs 短命中「某短语」(_end=3)")
    build_env(L, "tane")
    wf_init(L.eval("env"))
    res = run_filter(L, wf_func, """
        {
          Candidate('table',  0, 4, '物极必反', 'tsnr', ''),
          Candidate('phrase', 0, 3, '某短语', 'tane', ''),
        }
    """)
    texts = texts_of(res)
    ok = ("物极必反" in texts) and ("某短语" not in texts)
    print("  filter 输出：%s" % texts)
    print("  %s" % ("✅ 通过：精确命中保留、短命中（_end<4）被丢弃 ⇒ 副作用已受控"
                   if ok else "❌ 意外：%s" % texts))
    fail += 0 if ok else 1

    # ── 命题 B：切段后第 5 码段候选被清空（语义丢失）──
    print("\n【命题 B】切 [0,4)+[4,5) 后，第 5 码段候选在 filter 里被整片丢弃")
    print("  输入 taned（5 码）。模拟切段后 filter 对 segment[4,5)（即第 5 码 \"d\"）")
    print("  收到的候选流：「大」(简码 dddd, span [4,5))")
    build_env(L, "taned")
    wf_init(L.eval("env"))
    res = run_filter(L, wf_func, """
        { Candidate('table', 4, 5, '大', 'dddd', '') }
    """)
    texts = texts_of(res)
    ok = (texts == "(空)")
    print("  filter 输出：%s" % texts)
    print("  %s" % ("✅ 证实：第 5 码段候选被清空 ⇒ 第 5 码不再是「筛选位」，"
                   "而是被当独立输入翻译后丢弃，跨段筛选语义丢失"
                   if ok else "❌ 意外：%s" % texts))
    fail += 0 if ok else 1

    # ── 对照：现状单段下第 5 码筛选的输入是「一个 5 码整段」 ──
    print("\n【对照】现状（单段）下，第 5 码筛选依赖「候选 span 相对整串 5 码」")
    print("  注释已实测：taned 的 script_translator 产出 partial-span 候选")
    print("  （start=0, _end=4 → 吃满前 4 码），filter 靠 _end==4 判「真 4 码命中」。")
    print("  切段后候选 span 变为「相对各自 segment」，此判据的坐标系被拆散。")

    print("\n" + "=" * 72)
    print("沙盒结论：%s" % ("两个命题均按预期成立" if fail == 0 else "%d 项不符预期" % fail))
    print("=" * 72)
    print("综合判定（含源码结论）见回复正文。")
    return 0 if fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
