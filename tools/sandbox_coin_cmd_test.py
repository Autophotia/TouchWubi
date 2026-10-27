#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
自造词管理命令沙盒测试（/zctj /zcscNN /zccx /zcqk /zcdr）

用 lupa 在纯 Lua 环境里加载 Submit_text.lua + user_coined_cmd.lua，
mock 掉 librime 的 Candidate / yield / engine.context，真读真写临时文件，验证：

  1  /zctj   空库与有库时的展示、摘要含备份条数、倒序序号是否正确
  2  /zcsc   直接显示词条列表（序号固定 2 位，01~99）
  3  /zcsc00 序号 0 无效，提示从 01 开始
  4  /zcscNN 删除倒序第 NN 条是否删对条目
  5  越界    删不存在的序号是否安全拒绝
  6  /zccx   是否删的就是「最后造的那条」（不依赖会话状态）
  7  重复锁  同一命令串被 compose 重复触发时不会连删两条
  8  /zcqk   清空是否备份 .bak，且备份内容与清空前一致
  9  格式    删除后文件格式是否仍然规范（无空行、末行无多余换行），
             且后续再造词不会产生空行
  10 P       数字键接管：/zcsc 前缀下接管，满 2 位后不再接管
  11 /zcqk   + /zctj「有备份：共 N 条」+ /zcdr 完整导入
  12 /zcdr   合并去重只补缺、重复执行不翻倍
  13 合并去重 清空备份 = txt ∪ bak（新词追加 / 无新词不变 / 部分新词追加）
  14 顺序    /zcdr 恢复后「末行=最新」的序号语义不反转
  15 无备份   /zcdr 安全提示「暂无备份」

用法：
    python dev/tools/sandbox_coin_cmd_test.py
依赖：lupa
"""
import io
import os
import sys
import shutil
import tempfile

from lupa import LuaRuntime

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCHEMA_DIR = os.path.join(ROOT, "space", "schemas", "TouchWB")
LUA_DIR = os.path.join(SCHEMA_DIR, "lua")
SUBMIT_LUA = os.path.join(LUA_DIR, "Submit_text.lua")
CMD_LUA = os.path.join(LUA_DIR, "user_coined_cmd.lua")

HEADER = ["# 自造词文件", "# 格式：词条<Tab>编码", "# 即时生效，无需重新部署"]


def to_lua_path(p):
    return p.replace("\\", "/")


def build_runtime(user_dir):
    L = LuaRuntime(unpack_returned_tuples=True)
    L.execute("package.path = [[%s/?.lua;]] .. package.path" % to_lua_path(LUA_DIR))
    L.execute(
        "rime_api = {"
        "  get_user_data_dir   = function() return [[%s]] end,"
        "  get_schema_data_dir = function() return [[%s]] end,"
        "  get_shared_data_dir = function() return '' end,"
        "}" % (to_lua_path(user_dir), to_lua_path(SCHEMA_DIR))
    )
    L.execute("log = { info=function() end, error=function(m) print('[lua.error]', m) end,"
              " warning=function() end }")
    L.eval("dofile([[%s]])" % to_lua_path(SUBMIT_LUA))
    L.execute("""
        _yielded = {}
        function Candidate(t, s, e, txt, c)
            return { type = t, start = s, _end = e, text = txt or '', comment = c or '' }
        end
        function yield(c) table.insert(_yielded, c) end
        function reset_yield() _yielded = {} end
        function yielded_texts()
            local r = {}
            for i, c in ipairs(_yielded) do r[i] = c.text end
            return r
        end
        function yielded_pairs()
            local r = {}
            for i, c in ipairs(_yielded) do r[i] = { text = c.text, comment = c.comment } end
            return r
        end
        function new_input_stream(list)
            local i = 0
            return { iter = function(self)
                i = 0
                return function() i = i + 1; return list[i] end
            end }
        end
        env = { engine = { context = { input = "" } } }
        function set_input(s) env.engine.context.input = s end
    """)
    cmd = L.eval("dofile([[%s]])" % to_lua_path(CMD_LUA))
    return L, cmd


class Fixture(object):
    def __init__(self, tmp):
        self.tmp = tmp
        self.path = os.path.join(tmp, "user_coined_ext.txt")
        self.L, self.cmd = build_runtime(tmp)
        self._f = self.L.eval("function(x) end")

    # ---- Lua 交互 ----
    def set_input(self, s):
        self.L.globals().set_input(s)

    def run_filter(self, inp):
        """执行 F（filter），返回 (输入的候选文本列表)"""
        g = self.L.globals()
        stream = g.new_input_stream(self.L.table_from([]))
        g.reset_yield()
        self.cmd["F"](stream, g.env)
        return list(g.yielded_texts().values())

    def run_translator(self, inp):
        """执行 T（translator），返回候选文本列表"""
        g = self.L.globals()
        g.reset_yield()
        seg = self.L.table_from({"start": 0, "_end": len(inp)})
        self.cmd["T"](inp, seg, g.env)
        return list(g.yielded_texts().values())

    def run_translator_ex(self, inp):
        """执行 T，返回 [(文本, 注释)]，用于检查候选注释（如备份时间）"""
        g = self.L.globals()
        g.reset_yield()
        seg = self.L.table_from({"start": 0, "_end": len(inp)})
        self.cmd["T"](inp, seg, g.env)
        return [(p["text"], p["comment"]) for p in g.yielded_pairs().values()]

    def clear_lib(self):
        """把当前库清成「清空后的样子」（只留注释头），且不触发备份"""
        with io.open(self.path, "w", encoding="utf-8", newline="") as f:
            f.write("\n".join(HEADER))

    def unlock(self):
        """用一条非本模块的输入跑一次 F，清掉单次执行锁（模拟用户中间打了别的字）"""
        self.set_input("/zctj")
        self.run_filter("/zctj")

    def read_bak(self, n=1):
        """读第 n 份备份，返回 (全部原始行, 有效条目, 备份时间串)"""
        p = self.path + (".bak2" if n == 2 else ".bak")
        if not os.path.exists(p):
            return None, None, None
        with io.open(p, "r", encoding="utf-8", newline="") as f:
            raw = f.read()
        lines = raw.split("\n")
        entries = [ln for ln in lines if ln and not ln.startswith("#")]
        stamp = None
        for ln in lines:
            if ln.startswith("# 备份时间"):
                stamp = ln.split("：", 1)[1] if "：" in ln else ln
        return lines, entries, stamp

    def run_processor(self, inp, key_repr, ctrl=False, alt=False, release=False):
        """执行 P（processor），返回 (返回值, 是否被 push_input 及其参数)"""
        g = self.L.globals()
        self.L.execute(
            "_pushed = nil\n"
            "function _mkkey(r, ctrl, alt, rel)\n"
            "  return { repr=function() return r end, ctrl=function() return ctrl end,"
            "           alt=function() return alt end, release=function() return rel end }\n"
            "end\n"
            "_ctx_mock = { push_input = function(self, c) _pushed = c end,"
            "              input = [[%s]] }\n"
            "env2 = { engine = { context = _ctx_mock } }" % inp
        )
        key = g._mkkey(key_repr, ctrl, alt, release)
        ret = self.cmd["P"](key, g.env2)
        pushed = g._pushed
        return ret, pushed

    # ---- 文件 ----
    def write_entries(self, entries):
        """按 Submit_text 的真实写入格式生成文件（无末尾换行）"""
        lines = list(HEADER) + ["%s\t%s" % (t, c) for t, c in entries]
        with io.open(self.path, "w", encoding="utf-8", newline="") as f:
            f.write("\n".join(lines))

    def read_lines(self):
        if not os.path.exists(self.path):
            return []
        with io.open(self.path, "r", encoding="utf-8", newline="") as f:
            raw = f.read()
        return raw.split("\n")

    def read_entries(self):
        return [ln for ln in self.read_lines() if ln and not ln.startswith("#")]

    def write_bak(self, entries):
        """直接写备份文件（模拟「之前某次清空留下的备份」），不带时间戳头"""
        p = self.path + ".bak"
        with io.open(p, "w", encoding="utf-8", newline="") as f:
            f.write("\n".join(["%s\t%s" % (t, c) for t, c in entries]))


def check(name, ok, detail=""):
    print("  %-52s %s" % (name, "通过" if ok else "失败"))
    if detail:
        for d in detail:
            print("      %s" % d)
    return 0 if ok else 1


def main():
    if not os.path.exists(CMD_LUA):
        print("找不到 %s" % CMD_LUA)
        return 1

    fail = 0
    tmp = tempfile.mkdtemp(prefix="touchwb_coincmd_")
    try:
        fx = Fixture(tmp)
        sample = [("测试", "iyfb"), ("人工延误", "wwbk"), ("自造词库", "thiy"), ("最后一条", "jbwa")]

        print("=" * 70)
        print("自造词管理命令沙盒测试")
        print("=" * 70)
        print("用户目录 : %s (mock)" % tmp)
        print("")

        # ---- 1. 空库展示 ----
        print("【1】空库时 /zctj")
        fx.set_input("/zctj")
        out = fx.run_translator("/zctj")
        ok = len(out) == 1 and "暂无自造词" in out[0]
        fail += check("/zctj 提示暂无", ok, out)
        print("")

        # ---- 2. 有库展示与倒序序号 ----
        print("【2】4 条自造词时的 /zctj 倒序列表")
        fx.write_entries(sample)
        fx.set_input("/zctj")
        out = fx.run_translator("/zctj")
        # 摘要 1 条 + 倒序列表 4 条（备份信息并入摘要行，不单列）；序号 2 位补零
        ok = (len(out) == 5 and out[0].startswith("※ 自造词：共 4 条") and
              out[1] == "01. 最后一条" and out[4] == "04. 测试")
        fail += check("摘要（含备份状态）+ 倒序列表 4 条（2 位序号）", ok, out)
        print("")

        # ---- 2.5 /zcsc 直接显示列表 ----
        print("【2.5】/zcsc 直接显示词条列表（2 位序号，输满即删）")
        fx.set_input("/zcsc")
        out = fx.run_translator("/zcsc")
        ok = (len(out) == 5 and out[0].startswith("※ 自造词共 4 条") and
              out[1] == "01. 最后一条" and out[4] == "04. 测试")
        fail += check("/zcsc 显示列表（01~04 倒序）", ok, out)
        print("")

        # ---- 2.6 /zcsc0 中间态仍显示列表 ----
        print("【2.6】/zcsc0 中间态（1 位数字）仍保持列表")
        fx.set_input("/zcsc0")
        out = fx.run_translator("/zcsc0")
        ok = (len(out) == 5 and out[1] == "01. 最后一条" and out[4] == "04. 测试")
        fail += check("/zcsc0 保持列表不删除", ok, out[:3])
        print("")

        # ---- 2.7 /zcsc00 序号 0 无效 ----
        print("【2.7】/zcsc00 序号 0 无效，提示从 01 开始")
        before = fx.read_entries()
        fx.set_input("/zcsc00")
        out = fx.run_translator("/zcsc00")
        after = fx.read_entries()
        ok = (len(out) == 1 and "序号从 01 开始" in out[0] and before == after)
        fail += check("/zcsc00 提示无效且不改文件", ok, out)
        print("")

        # ---- 3. 按序号删除 ----
        print("【3】/zcsc02 删除倒序第 2 条（应为「自造词库」）")
        fx.set_input("/zcsc02")
        out = fx.run_filter("/zcsc02")
        left = fx.read_entries()
        ok = (len(out) == 1 and "自造词库" in out[0] and len(left) == 3 and
              "自造词库" not in "\n".join(left))
        fail += check("删对条目且剩余 3 条", ok, out + left)
        print("")

        # ---- 4. 越界拒绝 ----
        print("【4】/zcsc09 越界应安全拒绝")
        before = fx.read_entries()
        fx.set_input("/zcsc09")
        out = fx.run_filter("/zcsc09")
        after = fx.read_entries()
        ok = (len(out) == 1 and "没有第 9 条" in out[0] and before == after)
        fail += check("提示越界且文件未被改动", ok, out)
        print("")

        # ---- 5. 单次执行锁 ----
        print("【5】同一命令串重复 compose 不应连删两条")
        fx.write_entries(sample)
        fx.set_input("/zcsc01")
        first = fx.run_filter("/zcsc01")
        n1 = len(fx.read_entries())
        second = fx.run_filter("/zcsc01")   # input 没变，模拟 compose 重跑
        n2 = len(fx.read_entries())
        # 关键是「不重复删」；同时重复触发应还能看到上次的结果候选
        ok = (n1 == 3 and n2 == n1 and len(second) == 1 and "最后一条" in second[0])
        fail += check("第二次不重复执行（4 -> %d -> %d）" % (n1, n2), ok, second)
        print("")

        # ---- 6. /zccx 撤销末条 ----
        print("【6】/zccx 撤销最近造的词")
        fx.write_entries(sample)
        fx.set_input("/zccx")
        out = fx.run_filter("/zccx")
        left = fx.read_entries()
        ok = (len(out) == 1 and "最后一条" in out[0] and len(left) == 3 and
              "最后一条" not in "\n".join(left))
        fail += check("删掉的正是最后追加的那条", ok, out + left)
        print("")

        # ---- 7. /zcqk 清空与备份 ----
        print("【7】/zcqk 清空并备份")
        fx.write_entries(sample)
        fx.set_input("/zcqk")
        out = fx.run_filter("/zcqk")
        left = fx.read_entries()
        bak = fx.path + ".bak"
        bak_ok = False
        if os.path.exists(bak):
            with io.open(bak, "r", encoding="utf-8", newline="") as f:
                bak_lines = [ln for ln in f.read().split("\n") if ln and not ln.startswith("#")]
            bak_ok = bak_lines == ["%s\t%s" % (t, c) for t, c in sample]
        ok = (len(out) == 1 and "已清空 4 条" in out[0] and len(left) == 0 and bak_ok)
        fail += check("清空 + 备份内容一致", ok, out + (bak_lines if os.path.exists(bak) else ["无 .bak"]))
        print("")

        # ---- 8. 空库时各命令不崩 ----
        print("【8】空库时 /zcsc01 /zccx /zcqk 均安全")
        if os.path.exists(fx.path):
            os.remove(fx.path)
        allok = True
        detail = []
        for c in ("/zcsc01", "/zccx", "/zcqk"):
            fx.set_input(c)
            o = fx.run_filter(c)
            detail.extend(o)
            if not (len(o) == 1 and "暂无自造词" in o[0]):
                allok = False
        fail += check("三条命令均提示暂无自造词且无异常", allok, detail)
        print("")

        # ---- 9. 删除后格式仍规范（无空行）----
        print("【9】删除后再造词，文件不应产生空行")
        fx.write_entries(sample)
        fx.set_input("/zcsc02")
        fx.run_filter("/zcsc02")
        # 用 Submit_text 自己的追加函数再造一个词，模拟真实接续写入
        fx.L.globals().fileappendtext(fx.L.globals().get_userphrase_path(), "中国", "kh`lg", None)
        lines = fx.read_lines()
        empties = [i + 1 for i, ln in enumerate(lines) if ln == ""]
        ok = not empties
        fail += check("无空行（空行行号：%s）" % (empties or "无"), ok, lines)
        print("")

        # ---- 10. P 数字接管 ----
        # 只有 /zcscNN 需要序号，故仅 /zcsc 前缀接管数字，且满 2 位后不再接管
        print("【10】P：/zcsc 前缀接管数字，满 2 位后不再接管")
        r1, p1 = fx.run_processor("/zcsc", "0")
        r2, p2 = fx.run_processor("/zcsc0", "1")
        r3, p3 = fx.run_processor("/zcsc01", "2")   # 已满 2 位，不再接管
        r4, p4 = fx.run_processor("/zctj", "3")
        r5, p5 = fx.run_processor("/zcsc", "a")
        ok = (r1 == 1 and p1 == "0" and r2 == 1 and p2 == "1" and
              r3 == 2 and p3 is None and r4 == 2 and p4 is None and
              r5 == 2 and p5 is None)
        fail += check("数字接管正确，满 2 位/非前缀/非数字一律放行", ok,
                      ["/zcsc+0 -> ret=%s push=%s" % (r1, p1),
                       "/zcsc0+1 -> ret=%s push=%s" % (r2, p2),
                       "/zcsc01+2 -> ret=%s push=%s" % (r3, p3),
                       "/zctj+3 -> ret=%s push=%s" % (r4, p4),
                       "/zcsc+a -> ret=%s push=%s" % (r5, p5)])
        print("")

        # ============================================================
        # 备份与导入：用独立的用户目录，避免与上面的清空/删除用例互相污染
        # ============================================================
        expect4 = ["%s\t%s" % (t, c) for t, c in sample]
        bdir = os.path.join(tmp, "bak")
        os.makedirs(bdir, exist_ok=True)
        fb = Fixture(bdir)

        # ---- 11. /zcqk 自动备份 + /zctj 显示「有备份」 + /zcdr 导入 ----
        print("【11】/zcqk 清空自动备份，/zctj 显示有备份，/zcdr 完整导入")
        fb.write_entries(sample)
        fb.set_input("/zcqk")
        fb.run_filter("/zcqk")
        fb.set_input("/zctj")
        t = fb.run_translator("/zctj")
        ok1 = (len(t) == 1 and "暂无自造词" in t[0] and "有备份：共 4 条" in t[0])
        fail += check("空库时 /zctj 报「有备份：共 4 条」", ok1, t)
        fb.set_input("/zcdr")
        out = fb.run_filter("/zcdr")
        after = fb.read_entries()
        ok2 = (len(out) == 1 and "已从备份导入 4 条" in out[0] and sorted(after) == sorted(expect4))
        fail += check("/zcdr 从空库完整导入 4 条", ok2, out + after)
        print("")

        # ---- 12. /zcdr 合并去重 + 幂等 ----
        print("【12】/zcdr 只补缺，重复执行不翻倍")
        fb.unlock()
        fb.set_input("/zcdr")
        out = fb.run_filter("/zcdr")
        after1 = fb.read_entries()
        ok1 = (len(out) == 1 and "无需恢复" in out[0] and len(after1) == 4)
        fail += check("全都在库时不再追加", ok1, out + after1)
        fb.set_input("/zcsc01")
        fb.run_filter("/zcsc01")             # 删掉倒序第 1 条
        mid = fb.read_entries()
        fb.unlock()
        fb.set_input("/zcdr")
        out = fb.run_filter("/zcdr")
        after2 = fb.read_entries()
        ok2 = (len(mid) == 3 and len(after2) == 4 and len(out) == 1 and "导入 1 条" in out[0])
        fail += check("删掉 1 条后 /zcdr 补回 1 条", ok2, out + after2)
        print("")

        # ---- 13/14/15. 清空备份 = 合并去重（txt ∪ bak），三个场景 ----
        # 用独立 fixture + 手动写 bak，精确还原用户给的三个例子
        def merged_bak(txt_entries):
            _, bentries, _ = fx_merge.read_bak(1)
            return sorted(bentries) if bentries is not None else None

        A = [("测试一", "aa"), ("测试二", "ab"), ("测试三", "ac")]
        B = [("测试四", "ad"), ("测试五", "ae"), ("测试六", "af"), ("测试七", "ag")]

        # ---- 13. 场景1：txt 全新 3 条 + bak 4 条 → 并集 7 条 ----
        print("【13】合并去重场景1：txt 全新 + bak → 并集 7 条")
        d1 = os.path.join(tmp, "merge1")
        os.makedirs(d1, exist_ok=True)
        fx_merge = Fixture(d1)
        fx_merge.write_bak(B)                      # 备份：测试四五六七
        fx_merge.write_entries(A)                  # 当前库：测试一二三
        fx_merge.set_input("/zcqk")
        out = fx_merge.run_filter("/zcqk")
        bak = merged_bak(A)
        expect1 = sorted(["%s\t%s" % (t, c) for t, c in A + B])
        ok = (len(out) == 1 and "并入 3 条新词" in out[0] and bak == expect1)
        fail += check("场景1：并集 7 条（一~七）", ok, out + ["bak: %s" % bak])
        print("")

        # ---- 14. 场景2：txt ⊆ bak → 备份不变 ----
        print("【14】合并去重场景2：txt 全是 bak 子集 → 备份不变")
        d2 = os.path.join(tmp, "merge2")
        os.makedirs(d2, exist_ok=True)
        fx_merge = Fixture(d2)
        fx_merge.write_bak(B)                      # 备份：测试四五六七
        fx_merge.write_entries(B[:3])              # 当前库：测试四五六
        fx_merge.set_input("/zcqk")
        out = fx_merge.run_filter("/zcqk")
        bak = merged_bak(B[:3])
        expect2 = sorted(["%s\t%s" % (t, c) for t, c in B])
        ok = (len(out) == 1 and "均已在备份中" in out[0] and bak == expect2)
        fail += check("场景2：备份不变仍 4 条（四~七）", ok, out + ["bak: %s" % bak])
        print("")

        # ---- 15. 场景3：txt 含 1 条新词 → 只追加缺的那条 ----
        print("【15】合并去重场景3：txt 部分新词 → 只追加缺的词")
        d3 = os.path.join(tmp, "merge3")
        os.makedirs(d3, exist_ok=True)
        fx_merge = Fixture(d3)
        fx_merge.write_bak(B)                      # 备份：测试四五六七
        C = B[:3] + [("测试八", "ah")]             # 当前库：测试四五六 + 测试八
        fx_merge.write_entries(C)
        fx_merge.set_input("/zcqk")
        out = fx_merge.run_filter("/zcqk")
        bak = merged_bak(C)
        expect3 = sorted(["%s\t%s" % (t, c) for t, c in B + [("测试八", "ah")]])
        ok = (len(out) == 1 and "并入 1 条新词" in out[0] and bak == expect3)
        fail += check("场景3：并集 5 条（四~七 + 八）", ok, out + ["bak: %s" % bak])
        print("")

        # ---- 16. /zctj 非空库时摘要含「有备份」 ----
        print("【16】/zctj 非空库时摘要同时报自造词与备份条数")
        fb.unlock()
        fb.set_input("/zcdr")
        fb.run_filter("/zcdr")              # 恢复到 4 条
        fb.set_input("/zctj")
        t = fb.run_translator("/zctj")
        ok = (len(t) >= 1 and t[0].startswith("※ 自造词：共 4 条 · 有备份：共 4 条") and
              t[1] == "01. 最后一条")   # 恢复后顺序不变：末行（最新）应排第 1
        fail += check("摘要同时报条数，且恢复后顺序未反转", ok, t[:3])
        print("")

        # ---- 16. 无备份时 /zcdr 提示 ----
        print("【16】无备份时 /zcdr 安全提示")
        bdir2 = os.path.join(tmp, "nobak")
        os.makedirs(bdir2, exist_ok=True)
        fb2 = Fixture(bdir2)
        fb2.write_entries(sample)
        fb2.set_input("/zcdr")
        out = fb2.run_filter("/zcdr")
        ok = len(out) == 1 and "暂无备份" in out[0]
        fail += check("提示「暂无备份（/zcqk 清空时会自动备份）」", ok, out)
        print("")

        print("=" * 70)
        print("结论：%s" % ("全部通过" if fail == 0 else "%d 项失败（见上方）" % fail))
        print("=" * 70)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    return 0 if fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
