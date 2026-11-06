# -*- coding: utf-8 -*-
"""「多行上屏内容统一尾部空行」回归（真实 rime.dll，2026-11-06）。

★ 用户规则（2026-11-06 凌晨拍板）：
    上屏后是**多行内容**的段落，末尾留一个空行（光标落到内容后的空行，
    接着打字不会粘在已上屏内容尾部）；上屏后**仅一行**的（时间、日期、
    提示、符号）不加回车，要能直接接着打字。
  ★ 且「尾部 \\n 不写进候选栏 text」—— 否则前端会在候选栏渲染出空白、
    挡住文字预览（/tj 报告「横线挡预览」、/h 短标题都是这个教训）。

★ 实现（三个点，覆盖全部上屏路径）：
    1. core.finalize_commit_text(s)：含 \\n 且末尾无 \\n → 补 1 个；单行原样；幂等。
    2. Submit_text.submit_text_for()：空格 / 分号 / 引号（Lua 快捷上屏，
       不走 notifier）统一调用 finalize。
    3. input_statistics 的 group=-1 前置 select/commit 回调：点候选 / 数字键
       （Rime 原生 Commit）统一调用 finalize；该 translator 在 4 个五笔 schema
       都注册、init 时无条件安装 ⇒ 覆盖所有模块的候选。
    4. schedule.lua 的 /jq /gz /nl /jt 去掉候选 text 末尾的 \\n（行间 \\n 保留），
       改由上述统一收尾在提交时补回 ⇒ 候选栏不再有尾部空白。
    /h 分组行是「单行但要空行」的历史特例（用户 2026-11-05 已真机验收），
    仍由 help_cmd / Submit_text 显式追加 TAIL，finalize 不会重复加也不会删。

★ 覆盖的多行命令（本脚本逐一验证三条上屏路径）：
    /jq 节气 · /gz 干支 · /nl 农历 · /jt 今天信息 · /txtj 调序统计
    + /h 总览与分组行 · /tj /js 统计报告（防止重复加换行）
  单行命令：/rq 日期 · /sj 时间 · /dt 日期时间（不得出现回车）

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

# /txtj 会读 lua/sequence_<schema_id>.txt；key 形如 "code|phrase"，
# 让它列出两条 ⇒ 产出「多行且末尾无 \n」的调序统计（真正需要 finalize 补的样本）。
SEQ_TXT_BYTES = ("\ufeff#/user_id\ttail_probe\n"
                 "aaaa|测试词\t1\n"
                 "bbbb|另一个词\t2\n").encode("utf-8")

MULTI = {
    "/jq":   "=== 二十四节气 ===",
    "/gz":   "=== 干支历信息 ===",
    "/nl":   "=== 农历日期信息 ===",
    "/jt":   "嗨，",
    "/txtj": "=== 调序统计 ===",
}
SINGLE = ("/rq", "/sj", "/dt")
PATHS = ("space", "digit", "click")


def reset(lib, sid):
    hsp.press(lib, sid, "{Escape}")
    hsp.get_commit(lib, sid)


def cands(lib, sid, cmd):
    reset(lib, sid)
    hsp.press(lib, sid, cmd)
    hsp.get_commit(lib, sid)
    return hsp.all_cands(hsp.get_context(lib, sid))


def commit(lib, sid, cmd, how):
    """按指定路径上屏首候选，返回 commit text。"""
    reset(lib, sid)
    hsp.press(lib, sid, cmd)
    hsp.get_commit(lib, sid)          # 清掉命令输入过程中可能的残留
    if how == "space":
        hsp.press(lib, sid, "{space}")
    elif how == "digit":
        hsp.press(lib, sid, "1")
    elif how == "click":
        lib.RimeSelectCandidate(sid, 0)
    return hsp.get_commit(lib, sid)


def tail1(s):
    """末尾恰 1 个换行：有换行、不出现 \\n\\n 结尾。"""
    return s.endswith("\n") and not s.endswith("\n\n")


def norm(s):
    """/jt 内容含「00点17分04秒」实时时钟，三次提交可能跨秒 ⇒ 比较前归一化。"""
    return re.sub(r"〔\d+点\d+分\d+秒〕", "〔TIME〕", s)


def lua_finalize_unit(results):
    """纯函数单测：把 core.lua 的 finalize 函数体单独抽出来跑（不 require 全模块）。"""
    print("\n=== [0] core.finalize_commit_text 纯函数单测 ===")
    from lupa import LuaRuntime
    src = open(os.path.join(DEV, "lua", "core.lua"), encoding="utf-8").read()
    m = re.search(r"(function core\.finalize_commit_text\(s\).*?\nend)", src, re.S)
    assert m, "未找到 finalize_commit_text 函数体"
    lua = LuaRuntime()
    lua.execute("core = {}\n" + m.group(1))
    f = lua.globals().core.finalize_commit_text
    cases = [
        ("单行文本原样", "2026-11-06", "2026-11-06"),
        ("多行无尾 → 补 1 个", "第一行\n第二行", "第一行\n第二行\n"),
        ("多行已有尾 → 原样", "第一行\n第二行\n", "第一行\n第二行\n"),
        ("空串原样", "", ""),
        ("只有换行不重复补", "abc\n", "abc\n"),
        ("幂等", "a\nb\n", f(f("a\nb"))),
    ]
    for name, inp, want in cases:
        got = f(inp)
        results.append(hsp.check(name, got == want, f"got={got!r} want={want!r}"))


def main():
    tmp = tempfile.mkdtemp(prefix="multiline_tail_probe_")
    user_dir = os.path.join(tmp, "user")
    log_dir = os.path.join(tmp, "log")
    os.makedirs(log_dir, exist_ok=True)
    shutil.copytree(hsp.TOUCHWB_REAL, user_dir,
                    ignore=shutil.ignore_patterns("*.userdb"))

    for rel in ("lua/core.lua", "lua/input_statistics.lua", "lua/Submit_text.lua",
                "lua/help_cmd.lua", "lua/schedule.lua", "lua/super_sequence.lua"):
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
    lua_finalize_unit(results)

    # ---------- 1. 候选栏 text 不得含尾部换行 ----------
    print("\n=== [1] 候选栏 text 不带尾部 \\n（前端不渲染空白）===")
    for cmd, needle in list(MULTI.items()) + [("/h", "※ 【TouchWB 命令总览】")]:
        page = cands(lib, sid, cmd)
        first = page[0][0] if page else ""
        results.append(hsp.check(f"{cmd} 首候选命中目标内容", needle in first,
                                 f"first={first[:34]!r} cands={len(page)}"))
        results.append(hsp.check(f"{cmd} 候选栏首条末尾无 \\n",
                                 bool(first) and not first.endswith("\n"),
                                 f"tail={first[-12:]!r}"))
        results.append(hsp.check(f"{cmd} 全部候选末尾均无 \\n",
                                 bool(page) and all(not t.endswith("\n") for t, _ in page)))
    for cmd in SINGLE:
        page = cands(lib, sid, cmd)
        first = page[0][0] if page else ""
        results.append(hsp.check(f"{cmd} 候选是单行且无 \\n",
                                 bool(first) and "\n" not in first,
                                 f"first={first!r}"))

    # ---------- 2. 多行命令：三条路径都恰带 1 个尾换行 ----------
    print("\n=== [2] 多行内容 · 空格 / 数字键 / 点候选 三条路径 ===")
    for cmd, needle in MULTI.items():
        for how in PATHS:
            c = commit(lib, sid, cmd, how)
            results.append(hsp.check(
                f"{cmd} [{how}] 上屏多行且末尾恰 1 个 \\n",
                needle in c and "\n" in c and tail1(c),
                f"len={len(c)} head={c[:26]!r} tail={c[-14:]!r}"))
        # 多路径内容一致（尾换行一致，正文不被改写；/jt 时钟归一化后比较）
        vals = [commit(lib, sid, cmd, how) for how in PATHS]
        results.append(hsp.check(f"{cmd} 三条路径上屏内容完全一致",
                                 norm(vals[0]) == norm(vals[1]) == norm(vals[2]),
                                 f"lens={[len(v) for v in vals]}"))

    # ---------- 3. 单行命令：三条路径都不得出现回车 ----------
    print("\n=== [3] 单行内容 · 三条路径都不加回车 ===")
    for cmd in SINGLE:
        for how in PATHS:
            c = commit(lib, sid, cmd, how)
            results.append(hsp.check(
                f"{cmd} [{how}] 上屏单行无 \\n",
                bool(c) and "\n" not in c, f"commit={c!r}"))

    # ---------- 4. 既有 /h、/tj 不被重复加换行 ----------
    print("\n=== [4] /h 与 /tj 幂等：仍是恰 1 个尾换行 ===")
    for how in PATHS:
        c = commit(lib, sid, "/h", how)
        results.append(hsp.check(f"/h 首候选 [{how}] 完整总览且末尾恰 1 个 \\n",
                                 "【TouchWB 命令总览】" in c and len(c) >= 700 and tail1(c),
                                 f"len={len(c)} tail={c[-8:]!r}"))
    reset(lib, sid)
    hsp.press(lib, sid, "/h")
    hsp.get_commit(lib, sid)
    hsp.press(lib, sid, "2")            # 第 2 候选 = 日期分组行（单行特例）
    c2 = hsp.get_commit(lib, sid)
    results.append(hsp.check("/h 分组行（数字键 2）末尾恰 1 个 \\n",
                             c2.startswith("日期  ⦑/rq⦒") and tail1(c2),
                             f"commit={c2[:30]!r} tail={c2[-8:]!r}"))
    for how in PATHS:
        c = commit(lib, sid, "/tj", how)
        results.append(hsp.check(f"/tj 报告 [{how}] 末尾恰 1 个 \\n",
                                 "◉ 今日统计" in c and "\n" in c and tail1(c),
                                 f"len={len(c)} tail={c[-14:]!r}"))

    # ---------- 5. 上屏后继续打码无残留 ----------
    print("\n=== [5] 多行上屏后继续打字无残留 ===")
    reset(lib, sid)
    hsp.press(lib, sid, "/txtj")
    hsp.press(lib, sid, "{space}")
    first_commit = hsp.get_commit(lib, sid)
    hsp.press(lib, sid, "z")
    second = hsp.get_commit(lib, sid)
    results.append(hsp.check("首屏内容含尾换行", tail1(first_commit),
                             f"tail={first_commit[-10:]!r}"))
    results.append(hsp.check("随后打字不被上屏内容污染",
                             "=== 调序统计 ===" not in second,
                             f"second={second[:40]!r}"))

    print("\n=== 汇总 ===")
    print(f"  {sum(1 for r in results if r)}/{len(results)} 通过")

    reset(lib, sid)
    try:
        lib.RimeDestroySession(sid)
        lib.RimeFinalize()
    except OSError as e:
        # ctypes 收尾偶发 access violation（Lua 状态随 DLL 卸载），非方案代码问题
        print(f"  [清理阶段忽略] {e}")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
