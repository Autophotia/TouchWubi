# -*- coding: utf-8 -*-
"""/h 首候选「仅显示标题、点选上屏整份命令总览」安全验证（真实 rime.dll）。
※ 文件名沿用历史（原 /hz 独立命令已于 2026-11-05 晚取消）。

★ 回归重点（2026-11-05 卡死事故）：
  1. 打 /h 只出候选，**绝不自动上屏**（commit 必须为空）；
  2. 第 1 候选 = 仅标题「※ 【TouchWB 命令总览】」（候选栏不显示内容预览），
     按空格（或点候选）后才上屏**整份总览**（help_cmd 的前置 notifier 回调
     在点候选/数字键路径还原候选文本；空格路径由 Submit_text 直接提交）；
  3. 之后打 z / 打码，不再出现「上屏字母 z」「又上屏总览」等残留乱象；
  4. 再次打 /h 正常、不卡顿。
★ 顺序回归：第 1 候选 = 总览；第 2 候选 = 日期行；第 3 候选 = 农历行。
★ 格式回归：命令用 ⦑ ⦒ 包裹、不含 ~、注释列为空；候选栏文本不带换行，
  但上屏的整份总览与每条分组行末尾恰带 1 个换行（光标自动落到空行，
  与 /tj 统计报告一致）；
  总览与分组行同源（全部行都在）；/hz 不再作为独立命令存在。
★ 真机说明：上屏完整性取决于目标编辑器（notepad-- 截断 / notepad++ 渲染慢 /
  EmEditor 完整且瞬间），属编辑器限制、非代码 bug；本脚本只验证引擎层 commit。
只读实验：复制真机目录到临时目录。
"""
import ctypes
from ctypes import c_int, c_void_p, c_char_p, c_size_t, POINTER, Structure, byref
import os, shutil, tempfile

WEASEL_DIR = r"D:\Program Files\Rime\weasel-0.17.4"
SHARED_DATA = os.path.join(WEASEL_DIR, "data")
TOUCHWB_REAL = r"D:\Program Files\Rime\TouchWB"
TOUCHWB_DEV = r"D:\AutophotiaIME\dev\space\schemas\TouchWB"
RIME_DLL = os.path.join(WEASEL_DIR, "rime.dll")


class RimeTraits(Structure):
    _fields_ = [
        ("data_size", c_int), ("shared_data_dir", c_char_p), ("user_data_dir", c_char_p),
        ("distribution_name", c_char_p), ("distribution_code_name", c_char_p),
        ("distribution_version", c_char_p), ("app_name", c_char_p),
        ("modules", POINTER(c_char_p)), ("min_log_level", c_int), ("log_dir", c_char_p),
        ("prebuilt_data_dir", c_char_p), ("staging_dir", c_char_p),
    ]


class RimeCommit(Structure):
    _fields_ = [("data_size", c_int), ("text", c_char_p)]


class RimeCandidate(Structure):
    _fields_ = [("text", c_char_p), ("comment", c_char_p), ("reserved", c_void_p)]


class RimeMenu(Structure):
    _fields_ = [
        ("page_size", c_int), ("page_no", c_int), ("is_last_page", c_int),
        ("highlighted_candidate_index", c_int), ("num_candidates", c_int),
        ("candidates", POINTER(RimeCandidate)), ("select_keys", c_char_p),
    ]


class RimeComposition(Structure):
    _fields_ = [
        ("length", c_int), ("cursor_pos", c_int), ("sel_start", c_int),
        ("sel_end", c_int), ("preedit", c_char_p),
    ]


class RimeContext(Structure):
    _fields_ = [
        ("data_size", c_int), ("composition", RimeComposition), ("menu", RimeMenu),
        ("commit_text_preview", c_char_p), ("select_labels", POINTER(c_char_p)),
    ]


def load_lib():
    os.add_dll_directory(WEASEL_DIR)
    lib = ctypes.WinDLL(RIME_DLL)
    lib.RimeSetup.argtypes = [POINTER(RimeTraits)]
    lib.RimeInitialize.argtypes = [POINTER(RimeTraits)]
    lib.RimeFinalize.argtypes = []
    lib.RimeCreateSession.restype = c_size_t
    lib.RimeDestroySession.argtypes = [c_size_t]
    lib.RimeSelectSchema.argtypes = [c_size_t, c_char_p]
    lib.RimeSimulateKeySequence.argtypes = [c_size_t, c_char_p]
    lib.RimeGetContext.argtypes = [c_size_t, POINTER(RimeContext)]
    lib.RimeGetContext.restype = c_int
    lib.RimeFreeContext.argtypes = [POINTER(RimeContext)]
    lib.RimeGetCommit.argtypes = [c_size_t, POINTER(RimeCommit)]
    lib.RimeGetCommit.restype = c_int
    # ★ 必须设 argtypes：sid 是 64 位 c_size_t，不设会被当成 c_int 传参错位
    lib.RimeSelectCandidate.argtypes = [c_size_t, c_int]
    lib.RimeSelectCandidate.restype = c_int
    return lib


def make_traits(user_dir, log_dir):
    t = RimeTraits()
    t.data_size = ctypes.sizeof(RimeTraits)
    t.shared_data_dir = SHARED_DATA.encode()
    t.user_data_dir = user_dir.encode()
    t.distribution_name = b"Rime"
    t.distribution_code_name = b"hz_probe"
    t.distribution_version = b"0.0"
    t.app_name = b"sandbox_hz"
    t.min_log_level = 0
    t.log_dir = log_dir.encode()
    return t


def get_context(lib, sid):
    ctx = RimeContext()
    ctx.data_size = ctypes.sizeof(RimeContext)
    if not lib.RimeGetContext(sid, byref(ctx)):
        return None
    return ctx


def get_commit(lib, sid):
    c = RimeCommit()
    c.data_size = ctypes.sizeof(RimeCommit)
    lib.RimeGetCommit(sid, byref(c))
    return c.text.decode() if c.text else ""


def first_cand(ctx):
    if ctx is None or ctx.menu.num_candidates <= 0:
        return ""
    c = ctx.menu.candidates[0]
    return c.text.decode() if c.text else ""


def all_cands(ctx):
    """返回当前页 [(text, comment), ...]"""
    if ctx is None:
        return []
    out = []
    for i in range(ctx.menu.num_candidates):
        c = ctx.menu.candidates[i]
        out.append((c.text.decode() if c.text else "",
                    c.comment.decode() if c.comment else ""))
    return out


def collect_pages(lib, sid, max_pages=6):
    """从当前页开始翻页收集全部候选（{Right} = Page_Down）。"""
    out, seen_pages = [], 0
    for _ in range(max_pages):
        ctx = get_context(lib, sid)
        if ctx is None:
            break
        out.extend(all_cands(ctx))
        seen_pages += 1
        if ctx.menu.is_last_page:
            break
        press(lib, sid, "{Right}")
    return out


def dump(ctx, label):
    if ctx is None:
        print(f"  [{label}] <no context>")
        return
    preedit = ctx.composition.preedit.decode() if ctx.composition.preedit else ""
    n = ctx.menu.num_candidates
    fc = first_cand(ctx)
    print(f"  [{label}] preedit={preedit!r} page={ctx.menu.page_no} n={n} 首候选={fc[:60]!r}")


def press(lib, sid, seq):
    lib.RimeSimulateKeySequence(sid, seq.encode())


def check(name, cond, extra=""):
    print(("  [PASS] " if cond else "  [FAIL] ") + name + (("  " + extra) if extra else ""))
    return cond


def main():
    tmp = tempfile.mkdtemp(prefix="hz_probe_")
    user_dir = os.path.join(tmp, "user")
    log_dir = os.path.join(tmp, "log")
    os.makedirs(log_dir, exist_ok=True)
    shutil.copytree(TOUCHWB_REAL, user_dir, ignore=shutil.ignore_patterns("*.userdb"))
    # ★ 叠加 dev 改动：首候选短标题 + 正文补段涉及 help_cmd / Submit_text / core
    # 叠加本次涉及的全部 dev lua（2026-11-05 深夜起 /tj 也走短标题展开，
    # 不叠加 input_statistics 会留下「旧统计 + 新 Submit_text」的半新半旧组合）
    for rel in ("lua/help_cmd.lua", "lua/Submit_text.lua", "lua/core.lua",
                "lua/input_statistics.lua", "lua/schedule.lua",
                "lua/super_sequence.lua"):
        shutil.copyfile(os.path.join(TOUCHWB_DEV, rel), os.path.join(user_dir, rel))

    lib = load_lib()
    traits = make_traits(user_dir, log_dir)
    lib.RimeSetup(byref(traits))
    lib.RimeInitialize(byref(traits))
    sid = lib.RimeCreateSession()
    lib.RimeSelectSchema(sid, b"ly_wubi")

    results = []

    # ---------- 1. /h 只出候选、不自动上屏；首候选 = 整份总览 ----------
    print("\n=== [1] 打 /h：只出候选，第 1 候选 = 整份总览 ===")
    press(lib, sid, "/h")
    c1 = get_commit(lib, sid)
    ctx1 = get_context(lib, sid)
    dump(ctx1, "/h 后")
    fc1 = first_cand(ctx1)
    results.append(check("/h 不自动上屏（关键）", c1 == "", f"commit={c1[:40]!r}"))
    results.append(check("第 1 候选 = 仅标题（不再显示内容预览）",
                         fc1 == "※ 【TouchWB 命令总览】",
                         f"首候选前 40 字={fc1[:40]!r}"))
    results.append(check("第 1 候选不含日期/⦑ 等预览内容",
                         "日期" not in fc1 and "⦑" not in fc1, f"长度={len(fc1)}"))
    results.append(check("首候选（候选栏）仍不带尾部换行",
                         not fc1.endswith("\n"), f"末尾={fc1[-12:]!r}"))
    pre1 = ctx1.composition.preedit.decode() if ctx1 and ctx1.composition.preedit else ""
    results.append(check("/h 输入仍在编码栏", pre1 == "/h", f"preedit={pre1!r}"))

    # 候选顺序：1=总览，2=日期，3=农历（GROUPS 首行不得再插别的行）
    page1 = all_cands(ctx1)
    c2_text = page1[1][0] if len(page1) > 1 else ""
    c3_text = page1[2][0] if len(page1) > 2 else ""
    results.append(check("第 2 候选是「日期」分组行",
                         c2_text.startswith("日期  ⦑/rq⦒"), f"第2候选={c2_text[:24]!r}"))
    results.append(check("第 3 候选是「农历」分组行",
                         c3_text.startswith("农历  ⦑/jt⦒"), f"第3候选={c3_text[:24]!r}"))

    # 翻页收集全部候选：验证「⦑命令⦒含义」格式 + 注释列为空 + /hz 已移除
    h_cands = collect_pages(lib, sid)
    # /h 末尾还跟着 symbols.yaml 的注音候选（ĥ ȟ …），它们没有 ⦑，不算分组行；
    # 首候选是总览（以 ※ 开头），也要排除。
    seen, group_lines = set(), []
    for t, _ in h_cands:
        if "⦑" in t and not t.startswith("※") and t not in seen:
            seen.add(t)
            group_lines.append(t)
    results.append(check("/h 命令均用 ⦑⦒ 包裹、不含 ~",
                         len(group_lines) >= 18
                         and all("⦑" in t and "⦒" in t and "~" not in t
                                 for t in group_lines),
                         f"分组行={len(group_lines)} 全部候选={len(h_cands)}"))
    results.append(check("/h 不再单独显示注释（注释列为空）",
                         all(cm == "" for _, cm in h_cands)))
    results.append(check("GROUPS 已不含独立 /hz 命令",
                         all("/hz" not in t for t in group_lines)))
    results.append(check("/h 日期行符合约定格式",
                         "日期  ⦑/rq⦒日期 ⦑/sj⦒时间 ⦑/xq⦒星期 ⦑/dt⦒日期时间" in group_lines))
    results.append(check("/h 造词行符合约定格式",
                         "造词  ⦑/zctj⦒统计 ⦑/zcscNN⦒序号删除 ⦑/zccx⦒撤销" in group_lines))
    print("  ---- /h 分组行（前 3 行）----")
    for line in group_lines[:3]:
        print("  " + line)
    press(lib, sid, "{Escape}")
    get_commit(lib, sid)

    # ---------- 2. 按空格才上屏整份总览（首候选） ----------
    print("\n=== [2] 重新打 /h + 空格：上屏整份总览 ===")
    press(lib, sid, "/h")
    c2 = get_commit(lib, sid)
    results.append(check("/h 再次不自动上屏", c2 == "", f"commit={c2[:40]!r}"))
    press(lib, sid, "{space}")
    c3 = get_commit(lib, sid)
    results.append(check("空格上屏总览", "【TouchWB 命令总览】" in c3, f"commit 长度={len(c3)}"))
    results.append(check("上屏总览末尾恰有 1 个换行（光标落空行）",
                         c3.endswith("\n") and not c3.endswith("\n\n"),
                         f"末尾={c3[-12:]!r}"))
    results.append(check("总览命令均用 ⦑⦒ 包裹、无 ~",
                         all(k in c3 for k in ("⦑/rq⦒日期", "⦑/zctj⦒统计",
                                               "⦑/zcql⦒清临时词", "⦑Ctrl+J⦒前移",
                                               "⦑Ctrl+0⦒方案切换", "⦑Ctrl+0⦒功能切换",
                                               "自动造词"))
                         and "~" not in c3))
    results.append(check("总览长度完整（>=700 字，引擎层）", len(c3) >= 700, f"长度={len(c3)}"))
    results.append(check("首候选与分组行同源（每组全在总览里）",
                         all(t in c3 for t in group_lines),
                         f"分组行={len(group_lines)} 总览长度={len(c3)}"))
    print("  ---- 上屏文本（前 240 字 / 共 %d 字）----" % len(c3))
    print("  " + c3[:240])

    # ---------- 2b. 每条分组行上屏后也恰有 1 个尾部换行 ----------
    print("\n=== [2b] /h 分组行：候选栏无换行、上屏末尾有 1 个换行 ===")
    press(lib, sid, "{Escape}")
    get_commit(lib, sid)
    press(lib, sid, "/h")
    get_commit(lib, sid)
    page2b = all_cands(get_context(lib, sid))
    line2 = page2b[1][0] if len(page2b) > 1 else ""
    results.append(check("候选栏「日期」分组行本身不带换行",
                         line2.startswith("日期  ⦑/rq⦒") and "\n" not in line2,
                         f"第2候选={line2[:24]!r}"))
    press(lib, sid, "2")                       # 数字键选中第 2 候选（原生路径）
    c2b = get_commit(lib, sid)
    results.append(check("数字键 2 上屏 = 分组行 + 1 个换行",
                         c2b == line2 + "\n", f"len={len(c2b)} 末尾={c2b[-12:]!r}"))
    press(lib, sid, "{Escape}")
    get_commit(lib, sid)
    press(lib, sid, "/h")
    get_commit(lib, sid)
    lib.RimeSelectCandidate(sid, 1)            # 点候选第 2 条（手机点候选栏）
    c2c = get_commit(lib, sid)
    results.append(check("点候选上屏 = 分组行 + 1 个换行",
                         c2c == line2 + "\n", f"len={len(c2c)} 末尾={c2c[-12:]!r}"))
    press(lib, sid, "{Escape}")
    get_commit(lib, sid)

    # ---------- 3. 之后打 z / 打码：不得再冒出总览或字母 z 乱象 ----------
    print("\n=== [3] 上屏后连续输入：无残留乱象 ===")
    press(lib, sid, "z")
    c4a = get_commit(lib, sid)
    ctx4a = get_context(lib, sid)
    dump(ctx4a, "打 z 后")
    results.append(check("打 z 不自动上屏总览", "命令总览" not in c4a, f"commit={c4a[:40]!r}"))
    results.append(check("打 z 不自动上屏字母 z", c4a == "", f"commit={c4a[:40]!r}"))
    press(lib, sid, "{Escape}")
    get_commit(lib, sid)

    press(lib, sid, "kh")
    press(lib, sid, "{space}")
    c4b = get_commit(lib, sid)
    results.append(check("正常打码上屏汉字（非总览）", "命令总览" not in c4b and c4b != "", f"commit={c4b[:40]!r}"))

    # ---------- 4. /hz 不再是独立命令 ----------
    print("\n=== [4] 打 /hz：不应再产出总览候选 ===")
    press(lib, sid, "{Escape}")
    get_commit(lib, sid)
    press(lib, sid, "/hz")
    c6 = get_commit(lib, sid)
    ctx6 = get_context(lib, sid)
    fc6 = first_cand(ctx6)
    dump(ctx6, "/hz 后")
    results.append(check("/hz 不自动上屏", c6 == "", f"commit={c6[:40]!r}"))
    results.append(check("/hz 不再产出总览候选", "命令总览" not in fc6,
                         f"首候选={fc6[:40]!r}"))
    press(lib, sid, "{Escape}")
    get_commit(lib, sid)

    # ---------- 5. 再打一次 /h，确认不卡、无残留 ----------
    print("\n=== [5] 再打 /h：正常出候选 ===")
    press(lib, sid, "/h")
    c5 = get_commit(lib, sid)
    ctx5 = get_context(lib, sid)
    dump(ctx5, "/h 再次")
    results.append(check("/h 再次不自动上屏", c5 == "", f"commit={c5[:40]!r}"))
    results.append(check("/h 再次首候选仍是仅标题",
                         first_cand(ctx5) == "※ 【TouchWB 命令总览】"))

    print("\n=== 汇总 ===")
    print(f"  {sum(1 for r in results if r)}/{len(results)} 通过")
    # ★ 上面 [5] 打完 /h 后候选栏仍是活动态，先 Escape 清空再销毁，减少
    #   Lua notifier 回调与 C++ 析构竞争。仍残留的偶发 ctypes access violation
    #   是沙盒收尾固有问题（变体对照：旧版统计脚本同样会崩），不代表真机行为，
    #   故只提示、不计入断言（25/25 才是本脚本的行为结论）。
    press(lib, sid, "{Escape}")
    get_commit(lib, sid)
    try:
        lib.RimeDestroySession(sid)
        lib.RimeFinalize()
        print("  [清理] CLEAN")
    except OSError as e:
        print(f"  [清理] 偶发 ctypes 收尾异常（不计入断言）：{e}")
    if not all(results):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
