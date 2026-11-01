#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
自动造词新逻辑沙盒测试（auto_coined.lua + Submit_text.lua）

针对 2026-10-30 三个修复做白盒验证（方案 B 后存储已迁 C++ UserDb，断言改查 mock db）：
  修复 A  重复造主词典已有词 —— Submit_text.lua 暴露 auto_coined_in_main_dict；
           auto_coined.lua 的 build_phrases 跳过主词典已有词。
  修复 B  点击候选栏上屏入链 —— auto_coined.lua 接 update_notifier，
           点选上屏（Context::Select）当场结算，不等下一次按键。
  修复 C  永久词写 UserDb —— UserCoined_AppendManual 去重 + seq 递增（原「注释头粘行」
           为 txt 时代问题，方案 B 已不再写 txt，改验证 UserDb 写入语义）。

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
function mock_db_keys_with_prefix(prefix)
    local out = {}
    for k in pairs(_MockDB) do
        if string.sub(k, 1, #prefix) == prefix then out[#out + 1] = k end
    end
    table.sort(out)
    return out
end
-- 返回 prefix 前缀下所有「词条<Tab>编码<Tab>value」行（供 Python 断言），每行一条。
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
    # ★ 2026-11-01 去重改用布隆过滤器（~2% 误判）：新词可能被误判为「在」⇒ 本次不漏造。
    #   这是预期行为（宁漏造不重复造主词典词），故下面三个新词只打印、不严格断言 False。
    check_has("万灵药", False)      # 主词典没有（布隆可能误判为 True）
    check_has("自动造词", False)    # 主词典没有（布隆可能误判为 True）
    check_has("有点卡", False)      # 主词典没有（布隆可能误判为 True）
    fail += 0 if check_has("", False) else 1

    # ================================================================
    # 第二部分：UserCoined_AppendManual 写 UserDb（去重 + seq 递增）
    # ================================================================
    print("\n【修复 C · 永久词写 UserDb】UserCoined_AppendManual 去重 + seq 递增")
    L2 = build_runtime(tmp, SCHEMA_DIR)
    L2.eval("dofile([[%s]])" % to_lua(SUBMIT_LUA))
    g2 = L2.globals()
    append = g2.UserCoined_AppendManual

    ok1 = append("万灵药", "dvax")       # 新增 → e\tdvax\t万灵药 = seq 1
    ok2 = append("万灵药", "dvax")       # 重复 → 视为已转正，返回 true，不重复写
    ok3 = append("自动造词", "tfty")     # 新增 → seq 2
    ok4 = append("有点卡", "dhhh")       # 新增 → seq 3

    manual = L2.eval("mock_db_texts('e\\t')")
    rows = set()
    for ln in manual.split("\n"):
        if not ln:
            continue
        p = ln.split("\t")
        rows.add((p[0], p[1], p[2]))
    print("  UserDb 永久词（text|code|seq）：")
    for r in sorted(rows):
        print("    | %s\t%s\t%s" % r)

    expect = {("万灵药", "dvax", "1"), ("自动造词", "tfty", "2"), ("有点卡", "dhhh", "3")}
    ok = (rows == expect and ok1 == True and ok2 == True and ok3 == True and ok4 == True)
    print("  %s" % ("✅ 通过：3 条去重写入，seq 1/2/3，重复追加不产生新条目" if ok else "❌ 失败"))
    fail += 0 if ok else 1

    # ================================================================
    # 第三部分：auto_coined.lua 点击候选栏上屏（update_notifier）
    # ================================================================
    print("\n【修复 B · 点击候选栏上屏】auto_coined.lua update_notifier 结算")
    L3 = build_runtime(tmp, SCHEMA_DIR)

    # 先加载 Submit_text.lua，暴露真实的 UserCoined_DB_* / UserCoined_AppendManual /
    #   auto_coined_stdcode / auto_coined_in_main_dict 钩子（方案 B 下 auto_coined 依赖它们）
    L3.eval("dofile([[%s]])" % to_lua(SUBMIT_LUA))

    # 覆盖为确定性编码 + 主词典判定（数据 / 银行 视为主词典已有）
    L3.execute("""
        code_seq = 0
        auto_coined_stdcode = function(phrase)
            code_seq = code_seq + 1
            return string.format("a%03d", code_seq % 1000)
        end
        auto_coined_in_main_dict = function(phrase)
            return phrase == "数据" or phrase == "银行"
        end
    """)

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

    temp = L3.eval("mock_db_texts('a\\t')")
    texts = {ln.split("\t")[0] for ln in temp.split("\n") if ln}
    print("  点选「数据」「银行」后 UserDb 临时词：%s" % (sorted(texts) if texts else "(空)"))
    # v2.3 起逐词上屏按字拆分，应造出「数据银」「据银」等字级窗口；
    # 主词典已有的「数据」「银行」应被过滤。
    ok = ("数据银" in texts) and ("据银" in texts) \
         and ("数据" not in texts) and ("银行" not in texts)
    print("  %s" % ("✅ 通过：点选入链且按字造出「数据银」等窗口，主词典「数据/银行」被跳过"
                    if ok else "❌ 失败"))
    fail += 0 if ok else 1

    # 验证同一提交不会被重复结算：把 notifier 再触发一次，不应多造词
    before = len(texts)
    L3.execute("if ctx.update_notifier.fn then ctx.update_notifier.fn(ctx) end")
    temp2 = L3.eval("mock_db_texts('a\\t')")
    after = len({ln.split("\t")[0] for ln in temp2.split("\n") if ln})
    ok = (before == after)
    print("  重复触发 notifier：词条数 %d → %d  %s" % (before, after,
          "✅ 通过（无重复结算）" if ok else "❌ 失败（被重复结算）"))
    fail += 0 if ok else 1

    # ================================================================
    # 第四部分：同码词都保留（撞码抑制已移除，2026-11-01）
    # ================================================================
    print("\n【修复 D · 同码词都保留】3字词/4字词同码（rutf）都应造出")
    L4 = build_runtime(tmp, SCHEMA_DIR)
    L4.eval("dofile([[%s]])" % to_lua(SUBMIT_LUA))
    L4.execute("""
        code_seq = 0
        auto_coined_stdcode = function(phrase)
            if phrase == "拼音行" or phrase == "拼音行动" then
                return "rutf"          -- 模拟五笔 3字词 vs 4字词同码
            end
            code_seq = code_seq + 1
            return "z" .. string.format("%03d", code_seq % 1000)
        end
        auto_coined_in_main_dict = function(phrase) return false end
    """)
    L4.execute("""
        OPTION_ON = true
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
    P4 = L4.eval("dofile([[%s]])" % to_lua(AUTO_LUA))
    p4 = P4["P"]["func"]
    p4(L4.eval("make_key(97)"), L4.eval("env"))
    L4.execute("click_commit('拼')")
    L4.execute("click_commit('音')")
    L4.execute("click_commit('行')")
    L4.execute("click_commit('动')")

    temp4 = L4.eval("mock_db_texts('a\\t')")
    texts4 = {ln.split("\t")[0] for ln in temp4.split("\n") if ln}
    print("  连打「拼」「音」「行」「动」后临时词：%s" % (sorted(texts4) if texts4 else "(空)"))
    ok = ("拼音行" in texts4) and ("拼音行动" in texts4)
    print("  %s" % ("✅ 通过：同码 rutf 的「拼音行」「拼音行动」都造出" if ok
                    else "❌ 失败：同码长词被过滤（撞码抑制残留）"))
    fail += 0 if ok else 1

    shutil.rmtree(tmp, ignore_errors=True)
    print("\n" + "=" * 70)
    print("结论：%s" % ("全部通过" if fail == 0 else "%d 项失败（见上方 ❌）" % fail))
    print("=" * 70)
    return 0 if fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
