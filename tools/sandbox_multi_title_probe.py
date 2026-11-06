# -*- coding: utf-8 -*-
"""「多行命令候选栏只显标题、上屏还原全文」回归（真实 rime.dll，2026-11-06）。

★ 用户需求（2026-11-06 傍晚）：
    /jt 候选显示应对齐 /h 分组行「打字  ⦑/tj⦒统计」那种干净单行样式 ——
    只显示首行标题「嗨，下午好!〔17点32分45秒〕」，后面的正文预览
    （「2...天」等）不应显示；/jq /txtj 等其它多行命令同理。
    概括为：**有多行内容的候选，只显示标题，不显示内容预览。**

★ 根因：Rime 候选栏显示与上屏同源（都取 cand->text()），之前把完整多行
  段落塞进候选 text ⇒ 前端把 \\n 压平成「标题 + 正文截断」的长串。

★ 实现（复用既有「显示/上屏分离」资产，不新增组件、不改 schema yaml）：
    1. core.register_short_full / core.expand_short_full：模块级精确匹配注册表。
    2. schedule.lua（/jt /jq /gz /nl）、super_sequence.lua（/txtj）：候选 text
       只放首行标题，同时登记 title → full。
    3. input_statistics 的 group=-1 前置 select/commit 回调：点候选 / 数字键
       查表还原全文（该 translator 4 个五笔 schema 都注册、init 时无条件安装
       ⇒ 覆盖所有模块的候选）。
    4. Submit_text.submit_text_for：空格 / 分号 / 引号查表还原全文。
    5. core.finalize_commit_text：多行末尾补 1 个 \\n（既有的尾部空行约定），
       单行不加。

★ 本脚本验证：
    [0] core 注册表纯函数单测（精确匹配 / 覆盖 / 空值安全）
    [1] 5 个多行命令候选栏 = 单行标题，无 \\n、无正文特征串
    [2] 空格 / 数字键 / 点候选三条路径均上屏完整多行正文 + 恰 1 个尾换行
    [3] 单行命令 /rq /sj /dt 不受影响（候选与上屏都单行无 \\n）
    [4] /h 总览、/h 分组行、/tj 报告不受影响（不重复展开、不重复补换行）
    [5] 新 session / 连续调用 / 上屏后继续打码无残留

只读实验：复制真机目录到临时目录 + 叠加 dev lua + 预置统计/调序数据。
"""
import os
import re
import shutil
import sys
import tempfile
from ctypes import byref

sys.path.insert(0, r"D:\AutophotiaIME\dev\tools")
import sandbox_help_short_probe as hsp

DEV = hsp.TOUCHWB_DEV

STATS_LUA = """return {
  daily   = {count = 56,   length = 1234,  fastest = 61.5, ts = 0, avgGaps = {}, avgCnts = {}},
  weekly  = {count = 300,  length = 5678,  fastest = 72.0, ts = 0, avgGaps = {}, avgCnts = {}},
  monthly = {count = 900,  length = 9012,  fastest = 80.5, ts = 0, avgGaps = {}, avgCnts = {}},
  yearly  = {count = 3000, length = 34567, fastest = 90.0, ts = 0, avgGaps = {}, avgCnts = {}},
  lengths = {[2] = 10, [3] = 5},
  daily_max = 100, weekly_max = 500, recent = {},
  yesterday = {count = 40, length = 900, fastest = 50, ts = 0},
}
"""

# /txtj 会读 lua/sequence_<schema_id>.txt；两条记录 ⇒ 产出多行调序统计。
SEQ_TXT_BYTES = ("\ufeff#/user_id\ttitle_probe\n"
                 "aaaa|测试词\t1\n"
                 "bbbb|另一个词\t2\n").encode("utf-8")

# cmd -> (候选栏应命中的标题片段, 正文中必出现的特征串, 正文绝不能出现在候选栏的特征串)
MULTI = {
    "/jq":   ("=== 二十四节气 ===",  "当前日期：",  "当前日期："),
    "/gz":   ("=== 干支历信息 ===",  "干支：",      "干支："),
    "/nl":   ("=== 农历日期信息 ===", "公历：",      "公历："),
    "/jt":   ("嗨，",                "年已过",      "年已过"),
    "/txtj": ("=== 调序统计 ===",    "1. 测试词",   "1. 测试词"),
}
SINGLE = ("/rq", "/sj", "/dt")
PATHS = ("space", "digit", "click")
DEV_LUA = ("lua/core.lua", "lua/input_statistics.lua", "lua/Submit_text.lua",
           "lua/help_cmd.lua", "lua/schedule.lua", "lua/super_sequence.lua")


def reset(lib, sid):
    hsp.press(lib, sid, "{Escape}")
    hsp.get_commit(lib, sid)


def first_cand(lib, sid, cmd):
    reset(lib, sid)
    hsp.press(lib, sid, cmd)
    hsp.get_commit(lib, sid)
    page = hsp.all_cands(hsp.get_context(lib, sid))
    return (page[0][0] if page else ""), page


def commit(lib, sid, cmd, how):
    """按指定路径上屏首候选，返回 commit text。"""
    reset(lib, sid)
    hsp.press(lib, sid, cmd)
    hsp.get_commit(lib, sid)
    if how == "space":
        hsp.press(lib, sid, "{space}")
    elif how == "digit":
        hsp.press(lib, sid, "1")
    elif how == "click":
        lib.RimeSelectCandidate(sid, 0)
    return hsp.get_commit(lib, sid)


def tail1(s):
    return s.endswith("\n") and not s.endswith("\n\n")


def norm(s):
    """/jt 含实时秒数，三次提交可能跨秒 ⇒ 比较前归一化。"""
    return re.sub(r"〔\d+点\d+分\d+秒〕", "〔TIME〕", s)


def registry_unit(results):
    """纯函数单测：抽出 core.lua 的两个注册函数单独跑（不 require 全模块）。"""
    print("\n=== [0] core 短标题注册表 · 纯函数单测 ===")
    from lupa import LuaRuntime
    src = open(os.path.join(DEV, "lua", "core.lua"), encoding="utf-8").read()
    m1 = re.search(r"(function core\.register_short_full\(short, full\).*?\nend)", src, re.S)
    m2 = re.search(r"(function core\.expand_short_full\(text\).*?\nend)", src, re.S)
    assert m1 and m2, "未找到 register_short_full / expand_short_full 函数体"
    lua = LuaRuntime()
    lua.execute("core = {}\nSHORT_FULL_MULTI = {}\n" + m1.group(1) + "\n" + m2.group(1))
    reg = lua.globals().core.register_short_full
    exp = lua.globals().core.expand_short_full
    reg("T", "第一行\n第二行")
    results.append(hsp.check("登记后精确查回全文", exp("T") == "第一行\n第二行",
                             f"got={exp('T')!r}"))
    results.append(hsp.check("未登记的 key 返回 nil", exp("T2") is None,
                             f"got={exp('T2')!r}"))
    results.append(hsp.check("非前缀匹配（T2 不命中 T）", exp("T2") is None))
    reg("T", "新全文\n第二行")
    results.append(hsp.check("同 key 覆盖登记", exp("T") == "新全文\n第二行"))
    results.append(hsp.check("空串不登记", (reg("", "x"), exp(""))[1] is None))
    results.append(hsp.check("nil 参数安全", exp(None) is None))
    results.append(hsp.check("多行全文含 \\n 不丢", "\n" in exp("T")))


def main():
    tmp = tempfile.mkdtemp(prefix="multi_title_probe_")
    user_dir = os.path.join(tmp, "user")
    log_dir = os.path.join(tmp, "log")
    os.makedirs(log_dir, exist_ok=True)
    shutil.copytree(hsp.TOUCHWB_REAL, user_dir,
                    ignore=shutil.ignore_patterns("*.userdb"))

    for rel in DEV_LUA:
        shutil.copyfile(os.path.join(DEV, rel), os.path.join(user_dir, rel))

    # 预置数据：统计报告 + 调序统计列表
    with open(os.path.join(user_dir, "lua", "input_stats_ly_wubi.lua"),
              "w", encoding="utf-8", newline="\n") as f:
        f.write(STATS_LUA)
    with open(os.path.join(user_dir, "lua", "sequence_ly_wubi.txt"), "wb") as f:
        f.write(SEQ_TXT_BYTES)

    lib = hsp.load_lib()
    traits = hsp.make_traits(user_dir, log_dir)
    lib.RimeSetup(byref(traits))
    lib.RimeInitialize(byref(traits))
    sid = lib.RimeCreateSession()
    lib.RimeSelectSchema(sid, b"ly_wubi")

    results = []
    registry_unit(results)

    # ---------- 1. 候选栏只显标题 ----------
    print("\n=== [1] 多行命令候选栏 = 单行标题（无 \\n / 无正文预览）===")
    titles = {}
    for cmd, (needle, _mark, forbidden) in MULTI.items():
        first, page = first_cand(lib, sid, cmd)
        titles[cmd] = first
        print(f"  {cmd:6s} 候选栏 = {first!r}")
        results.append(hsp.check(f"{cmd} 首候选命中标题", needle in first,
                                 f"first={first[:40]!r}"))
        results.append(hsp.check(f"{cmd} 首候选是单行（无 \\n）",
                                 bool(first) and "\n" not in first,
                                 f"first={first[:40]!r}"))
        results.append(hsp.check(f"{cmd} 首候选不含正文预览",
                                 bool(first) and forbidden not in first,
                                 f"forbidden={forbidden!r}"))
        results.append(hsp.check(f"{cmd} 标题足够短（<= 40 字）",
                                 bool(first) and len(first) <= 40,
                                 f"len={len(first)}"))
        results.append(hsp.check(f"{cmd} 全部候选均无 \\n",
                                 bool(page) and all("\n" not in t for t, _ in page),
                                 f"cands={len(page)}"))

    # ---------- 2. 三条路径还原全文 ----------
    print("\n=== [2] 空格 / 数字键 / 点候选：上屏完整多行正文 + 恰 1 个尾换行 ===")
    for cmd, (needle, mark, _forbidden) in MULTI.items():
        for how in PATHS:
            c = commit(lib, sid, cmd, how)
            results.append(hsp.check(
                f"{cmd} [{how}] 上屏完整正文（标题+正文特征+多行+尾换行）",
                needle in c and mark in c and c.count("\n") >= 4 and tail1(c),
                f"len={len(c)} nl={c.count(chr(10))} head={c[:24]!r} tail={c[-12:]!r}"))
        vals = [commit(lib, sid, cmd, how) for how in PATHS]
        results.append(hsp.check(f"{cmd} 三条路径内容完全一致",
                                 norm(vals[0]) == norm(vals[1]) == norm(vals[2]),
                                 f"lens={[len(v) for v in vals]}"))
        # 上屏内容必须远长于候选栏标题（证明确实展开了，不是只上屏标题）
        results.append(hsp.check(f"{cmd} 上屏远长于标题（展开生效）",
                                 len(vals[0]) >= len(titles[cmd]) * 2 + 10,
                                 f"title={len(titles[cmd])} commit={len(vals[0])}"))

    # ---------- 3. 单行命令不受影响 ----------
    print("\n=== [3] 单行命令 /rq /sj /dt：候选与上屏都单行、无回车 ===")
    for cmd in SINGLE:
        first, _ = first_cand(lib, sid, cmd)
        results.append(hsp.check(f"{cmd} 候选栏单行", bool(first) and "\n" not in first,
                                 f"first={first!r}"))
        for how in PATHS:
            c = commit(lib, sid, cmd, how)
            results.append(hsp.check(f"{cmd} [{how}] 上屏单行无 \\n",
                                     bool(c) and "\n" not in c, f"commit={c!r}"))

    # ---------- 4. /h、/tj 幂等：不被重复展开 / 重复补换行 ----------
    print("\n=== [4] /h 与 /tj 不受影响（仍恰 1 个尾换行）===")
    for how in PATHS:
        c = commit(lib, sid, "/h", how)
        results.append(hsp.check(f"/h 首候选 [{how}] 完整总览且恰 1 个尾换行",
                                 "【TouchWB 命令总览】" in c and len(c) >= 700 and tail1(c),
                                 f"len={len(c)} tail={c[-8:]!r}"))
    reset(lib, sid)
    hsp.press(lib, sid, "/h")
    hsp.get_commit(lib, sid)
    hsp.press(lib, sid, "2")
    c2 = hsp.get_commit(lib, sid)
    results.append(hsp.check("/h 分组行（数字键 2）恰 1 个尾换行",
                             c2.startswith("日期  ⦑/rq⦒") and tail1(c2),
                             f"commit={c2[:26]!r} tail={c2[-8:]!r}"))
    for how in PATHS:
        c = commit(lib, sid, "/tj", how)
        results.append(hsp.check(f"/tj 报告 [{how}] 完整且恰 1 个尾换行",
                                 "◉ 今日统计" in c and "\n" in c and tail1(c),
                                 f"len={len(c)} tail={c[-12:]!r}"))

    # ---------- 5. 新 session / 连续调用 / 无残留 ----------
    print("\n=== [5] 新 session、连续调用、上屏后继续打码 ===")
    sid2 = lib.RimeCreateSession()
    lib.RimeSelectSchema(sid2, b"ly_wubi")
    c_new = commit(lib, sid2, "/jq", "space")
    results.append(hsp.check("新 session 首次 /jq 仍展开全文",
                             "当前日期：" in c_new and tail1(c_new),
                             f"len={len(c_new)}"))
    c_a = commit(lib, sid, "/jt", "space")
    c_b = commit(lib, sid, "/jt", "click")
    results.append(hsp.check("连续两次 /jt（动态标题）均展开全文",
                             "年已过" in c_a and tail1(c_a)
                             and "年已过" in c_b and tail1(c_b),
                             f"lens={len(c_a)},{len(c_b)}"))
    reset(lib, sid)
    hsp.press(lib, sid, "/txtj")
    hsp.press(lib, sid, "{space}")
    first_commit = hsp.get_commit(lib, sid)
    hsp.press(lib, sid, "z")
    second = hsp.get_commit(lib, sid)
    results.append(hsp.check("上屏后继续打码不被正文污染",
                             tail1(first_commit) and "=== 调序统计 ===" not in second,
                             f"second={second[:40]!r}"))

    print("\n=== 汇总 ===")
    print(f"  {sum(1 for r in results if r)}/{len(results)} 通过")

    reset(lib, sid)
    reset(lib, sid2)
    try:
        lib.RimeDestroySession(sid2)
        lib.RimeDestroySession(sid)
        lib.RimeFinalize()
        print("  [清理] 会话销毁正常")
    except OSError as e:
        # ctypes 收尾偶发 access violation（Lua 状态随 DLL 卸载），非方案代码问题
        print(f"  [清理阶段忽略] {e}")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
