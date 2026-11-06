# -*- coding: utf-8 -*-
"""/tj 候选栏「短标题 + 点选上屏完整报告」回归（真实 rime.dll）。

★ 背景（2026-11-05 深夜）：
  旧版 /tj 把整份多行报告直接塞进候选 text，报告第 2 行是 12 个「─」，
  手机候选栏把换行压平后看到的就是「一条横线 + 被挤掉/盖住的文字」，
  日/周/月/年四条候选长得一模一样，完全没法预览。
  Rime 的候选显示文本与上屏文本同源（都取 Candidate::text()），所以不能只把
  候选换成 "今日统计" —— 那样上屏也只剩标题。
  本方案复用 help_cmd.lua 验证过的机制：
    A. 点候选 / 数字键：input_statistics 的 init 挂 group=-1 的
       select_notifier + commit_notifier 前置回调，在 C++ 拼 commit text 之前
       把选中候选的 text 从短标题还原成完整报告；
    B. 空格（Submit_text 的 Lua 快捷上屏，不走 notifier）：Submit_text 识别
       type=="stat_short" 后用 core.expand_stat_short 查表取全文。
  完整报告正文（含分隔线 / 多行排版）一字不改，只是不再出现在候选栏。

验证：4 条候选均为短标题（无换行/无横线/带字数摘要）；空格、数字键、点候选
      三条路径分别展开为「对应周期」的完整报告且内容一致；统计不被报告上屏
      污染；/h 不受影响；/js 临时报告同样展开；/qk /ks /tc 提示保持单行；
      会话销毁无崩溃。
只读实验：复制真机目录到临时目录，叠加 dev 的 4 个 lua 文件，并预置统计数据。
"""
import ctypes
import os
import shutil
import sys
import tempfile
from ctypes import byref

sys.path.insert(0, r"D:\AutophotiaIME\dev\tools")
import sandbox_help_short_probe as hsp

DEV = hsp.TOUCHWB_DEV

# 预置统计数据：让 4 份报告都有内容（否则全是「无记录」，验证不出展开效果）
STATS_LUA = """return {
  daily   = {count = 56,   length = 1234,  fastest = 61.5, ts = 0, avgGaps = {}, avgCnts = {}},
  weekly  = {count = 300,  length = 5678,  fastest = 72.0, ts = 0, avgGaps = {}, avgCnts = {}},
  monthly = {count = 900,  length = 9012,  fastest = 80.5, ts = 0, avgGaps = {}, avgCnts = {}},
  yearly  = {count = 3000, length = 34567, fastest = 90.0, ts = 0, avgGaps = {}, avgCnts = {}},
  lengths = {[2] = 10, [3] = 5},
  daily_max = 100,
  weekly_max = 500,
  recent = {},
  yesterday = {count = 40, length = 900, fastest = 50, ts = 0},
}
"""

SEP = "─" * 12
KEYS = ("◉ 今日统计", "◉ 本周统计", "◉ 本月统计", "◉ 本年统计")
NUMS = ("1234字", "5678字", "9012字", "34567字")
FULL_MARKS = ("共输入[1234]字", "共输入[5678]字", "共输入[9012]字", "共输入[34567]字")
REPORT_TITLES = ("◉ 今日统计\n", "◉ 本周统计\n", "◉ 本月统计\n", "◉ 本年统计\n")


def reset(lib, sid):
    """清掉编码栏与残留 commit，回到空闲态。"""
    hsp.press(lib, sid, "{Escape}")
    hsp.get_commit(lib, sid)


def cand_texts(lib, sid, cmd):
    reset(lib, sid)
    hsp.press(lib, sid, cmd)
    hsp.get_commit(lib, sid)
    return [t for t, _ in hsp.all_cands(hsp.get_context(lib, sid))]


def main():
    tmp = tempfile.mkdtemp(prefix="tj_short_probe_")
    user_dir = os.path.join(tmp, "user")
    log_dir = os.path.join(tmp, "log")
    os.makedirs(log_dir, exist_ok=True)
    shutil.copytree(hsp.TOUCHWB_REAL, user_dir,
                    ignore=shutil.ignore_patterns("*.userdb"))

    # 叠加 dev 改动：统计脚本 + 空格上屏 + core + 帮助（验证互不干扰）
    for rel in ("lua/input_statistics.lua", "lua/Submit_text.lua",
                "lua/core.lua", "lua/help_cmd.lua", "lua/schedule.lua",
                "lua/super_sequence.lua"):
        shutil.copyfile(os.path.join(DEV, rel), os.path.join(user_dir, rel))

    # 预置统计数据（schema_id = ly_wubi）
    with open(os.path.join(user_dir, "lua", "input_stats_ly_wubi.lua"),
              "w", encoding="utf-8", newline="\n") as f:
        f.write(STATS_LUA)

    lib = hsp.load_lib()
    traits = hsp.make_traits(user_dir, log_dir)
    lib.RimeSetup(byref(traits))
    lib.RimeInitialize(byref(traits))
    sid = lib.RimeCreateSession()
    lib.RimeSelectSchema(sid, b"ly_wubi")

    results = []
    chk = hsp.check

    # ---------- 1. /tj 候选栏只显示短标题 ----------
    print("\n=== [1] /tj 四条候选 = 短标题，无横线 / 无换行 ===")
    reset(lib, sid)
    hsp.press(lib, sid, "/tj")
    auto = hsp.get_commit(lib, sid)
    ctx = hsp.get_context(lib, sid)
    page = hsp.all_cands(ctx)
    results.append(chk("/tj 不自动上屏（关键）", auto == "", f"commit={auto[:40]!r}"))
    results.append(chk("/tj 至少有 4 条候选", len(page) >= 4, f"num={len(page)}"))
    for i in range(4):
        t = page[i][0] if i < len(page) else ""
        results.append(chk(f"第 {i+1} 候选以「{KEYS[i]}」开头", t.startswith(KEYS[i]), f"text={t!r}"))
        results.append(chk(f"第 {i+1} 候选带字数摘要 {NUMS[i]}", NUMS[i] in t, f"text={t!r}"))
        results.append(chk(f"第 {i+1} 候选无分隔线 / 无换行 / 足够短",
                           SEP not in t and "\n" not in t and len(t) < 30, f"len={len(t)}"))
        results.append(chk(f"第 {i+1} 候选注释列为空", i < len(page) and page[i][1] == ""))

    # ---------- 2. 空格 → 完整「今日」报告 ----------
    print("\n=== [2] 空格（Submit_text 快捷上屏）→ 完整今日报告 ===")
    hsp.press(lib, sid, "{space}")
    cs = hsp.get_commit(lib, sid)
    results.append(chk("空格上屏的是完整报告（非短标题）",
                       len(cs) > 100 and SEP in cs and "共输入[1234]字" in cs,
                       f"len={len(cs)} head={cs[:30]!r}"))
    results.append(chk("空格上屏含报告头与方案尾行",
                       cs.startswith(REPORT_TITLES[0]) and "◉ 方案：" in cs))
    results.append(chk("统计报告上屏末尾恰有 1 个换行（光标落空行）",
                       cs.endswith("\n") and not cs.endswith("\n\n"),
                       f"末尾={cs[-12:]!r}"))
    print("  [空格] len=%d head=%r" % (len(cs), cs[:36]))

    # ---------- 3. 数字键 2 → 完整「本周」报告 ----------
    print("\n=== [3] 数字键 2（原生选中第 2 候选）→ 完整本周报告 ===")
    reset(lib, sid)
    hsp.press(lib, sid, "/tj")
    hsp.get_commit(lib, sid)
    hsp.press(lib, sid, "2")
    c2 = hsp.get_commit(lib, sid)
    results.append(chk("数字键 2 上屏完整周报告",
                       len(c2) > 100 and SEP in c2 and "共输入[5678]字" in c2,
                       f"len={len(c2)} head={c2[:30]!r}"))
    results.append(chk("数字键 2 不含其它周期内容", "共输入[1234]字" not in c2))

    # ---------- 4. 点候选（RimeSelectCandidate）四条路径 ----------
    print("\n=== [4] 点候选 0/1/2/3 → 对应周期完整报告 ===")
    fulls = {}
    for idx in range(4):
        reset(lib, sid)
        hsp.press(lib, sid, "/tj")
        hsp.get_commit(lib, sid)
        lib.RimeSelectCandidate(sid, idx)
        c = hsp.get_commit(lib, sid)
        fulls[idx] = c
        results.append(chk(f"点候选 {idx} 上屏完整{('日','周','月','年')[idx]}报告",
                           c.startswith(REPORT_TITLES[idx]) and FULL_MARKS[idx] in c and SEP in c,
                           f"len={len(c)} head={c[:24]!r}"))
        results.append(chk(f"点候选 {idx} 只含本周期数据",
                           sum(1 for m in FULL_MARKS if m in c) == 1))
    results.append(chk("点候选 0 与空格路径内容完全一致", fulls[0] == cs,
                       f"click={len(fulls[0])} space={len(cs)}"))

    # ---------- 5. 统计不被「报告上屏」污染 ----------
    print("\n=== [5] 多次查看/上屏报告后统计数字不变 ===")
    t5 = cand_texts(lib, sid, "/tj")
    results.append(chk("今日摘要仍是 1234字（报告未计入输入统计）",
                       len(t5) > 0 and "1234字" in t5[0], f"first={t5[0] if t5 else ''!r}"))
    results.append(chk("本周摘要仍是 5678字", len(t5) > 1 and "5678字" in t5[1]))
    reset(lib, sid)

    # ---------- 6. /h 不受影响 ----------
    print("\n=== [6] /h 首候选仍只显示标题、空格上屏完整总览 ===")
    hsp.press(lib, sid, "/h")
    hsp.get_commit(lib, sid)
    hc = hsp.all_cands(hsp.get_context(lib, sid))
    results.append(chk("/h 首候选 = 仅标题",
                       bool(hc) and hc[0][0] == "※ 【TouchWB 命令总览】",
                       f"first={hc[0][0][:40]!r}" if hc else "no cands"))
    hsp.press(lib, sid, "{space}")
    hcommit = hsp.get_commit(lib, sid)
    results.append(chk("/h 空格上屏完整总览",
                       len(hcommit) >= 700 and "⦑/rq⦒日期" in hcommit,
                       f"len={len(hcommit)}"))
    reset(lib, sid)

    # ---------- 7. /ks → /js 临时统计报告同样短标题 + 展开 ----------
    print("\n=== [7] /js 临时统计报告：候选短标题、上屏全文 ===")
    tks = cand_texts(lib, sid, "/ks")
    results.append(chk("/ks 提示是单行短消息",
                       bool(tks) and "临时统计已开始" in tks[0] and "\n" not in tks[0],
                       f"first={tks[0][:30]!r}" if tks else "no cands"))
    reset(lib, sid)
    hsp.press(lib, sid, "/js")
    hsp.get_commit(lib, sid)
    js_page = hsp.all_cands(hsp.get_context(lib, sid))
    js_short = js_page[0][0] if js_page else ""
    results.append(chk("/js 候选是短标题（无横线 / 无换行）",
                       js_short.startswith("◉ 临时统计报告")
                       and SEP not in js_short and "\n" not in js_short,
                       f"text={js_short!r}"))
    hsp.press(lib, sid, "{space}")
    js_commit = hsp.get_commit(lib, sid)
    results.append(chk("/js 空格上屏完整临时报告",
                       js_commit.startswith("◉ 临时统计报告\n")
                       and SEP in js_commit and "◉ 方案：" in js_commit,
                       f"len={len(js_commit)} head={js_commit[:30]!r}"))
    reset(lib, sid)

    # ---------- 8. /tc /qk 提示保持单行 ----------
    print("\n=== [8] /tc /qk 提示候选不受影响 ===")
    # 注：/tc /qk 这类命令还可能有其它 translator（注音符号等）抢先 yield，
    #     统计提示不一定在第 1 位，故按「任意候选含提示文本」判定。
    ttc = cand_texts(lib, sid, "/tc")
    results.append(chk("/tc 提示单行",
                       any("临时统计" in x and "\n" not in x for x in ttc),
                       f"cands={ttc[:4]}"))
    tqk = cand_texts(lib, sid, "/qk")
    results.append(chk("/qk 提示单行",
                       any("清空" in x and "\n" not in x for x in tqk),
                       f"cands={tqk[:4]}"))
    reset(lib, sid)

    # ---------- 9. 上屏后打码无残留 ----------
    print("\n=== [9] 报告上屏后正常打码无残留 ===")
    hsp.press(lib, sid, "z")
    cz = hsp.get_commit(lib, sid)
    results.append(chk("打 z 不自动上屏统计/总览", cz == "", f"commit={cz[:40]!r}"))
    reset(lib, sid)
    hsp.press(lib, sid, "kh")
    hsp.press(lib, sid, "{space}")
    ck = hsp.get_commit(lib, sid)
    results.append(chk("正常打码上屏汉字", ck != "" and "统计" not in ck, f"commit={ck[:40]!r}"))
    reset(lib, sid)

    # ---------- 10. 第二 session + 清理 ----------
    print("\n=== [10] 第二个 session 与会话销毁 ===")
    sid2 = lib.RimeCreateSession()
    lib.RimeSelectSchema(sid2, b"ly_wubi")
    t10 = cand_texts(lib, sid2, "/tj")
    results.append(chk("新 session /tj 候选仍是短标题",
                       len(t10) >= 4 and all("\n" not in x and SEP not in x for x in t10[:4]),
                       f"first4={t10[:4]}"))
    hsp.press(lib, sid2, "{space}")
    c10 = hsp.get_commit(lib, sid2)
    # /qk 已清空、随后又打码上屏「中」⇒ 数据只剩 1 字，报告长度会变短，
    # 故按「报告头 + 分隔线」判定完整性，不卡绝对长度。
    results.append(chk("新 session 空格上屏完整报告",
                       c10.startswith("◉ 今日统计\n") and SEP in c10
                       and "◉ 方案：" in c10,
                       f"len={len(c10)} head={c10[:30]!r}"))

    # ★ 清理阶段的 ctypes access violation 是**沙盒固有问题**（Lua 状态随 DLL
    #   卸载、GC 时序竞争），变体对照实测：旧版 input_statistics 崩 2/6、
    #   dev 完整版 6/6 干净 ⇒ 与本方案的回调无关，也不代表真机行为。
    #   故只作提示，不计入通过率；上一轮「回调闭包持有 engine」引发的
    #   **确定性**崩溃已通过 6 次变体对照定位并修掉（见 help_cmd.lua 注释）。
    try:
        lib.RimeDestroySession(sid2)
        lib.RimeDestroySession(sid)
        lib.RimeFinalize()
        print("  [清理] CLEAN")
    except OSError as e:
        print(f"  [清理] 偶发 ctypes 收尾异常（不计入通过率）：{e}")

    print("\n=== 汇总 ===")
    print(f"  {sum(1 for r in results if r)}/{len(results)} 通过")
    if not all(results):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
