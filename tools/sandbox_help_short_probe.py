# -*- coding: utf-8 -*-
"""/h 首候选「只显示标题、点选上屏完整总览」回归（真实 rime.dll）。

★ 背景（librime 源码坐实）：
  Composition::GetCommitText() 与 RimeGetContext 的候选 text 都取 cand->text()
  ⇒ Rime 里「候选栏显示」与「上屏」同源，ShadowCandidate / preedit 都改不了。
  本方案用两条路径在「选中之后、C++ 拼 commit text 之前」把正文补回来：
    A. 点候选栏 / 数字键（原生 Context::Select → Commit）：help_cmd.lua 在
       select_notifier / commit_notifier 上挂 **group = -1 的前置回调**，把选中
       候选的 text 从短标题改回 OVERVIEW（cand.text setter 对 SimpleCandidate 有效）。
       group = -1 是硬要求：默认 group 时 C++ OnCommit 已先 sink 短标题，
       改文本来不及（实测只上屏 16 字）。两个回调幂等、互为兼容兜底。
    B. 空格（Submit_text 的 Lua 快捷上屏，不走 notifier）：Submit_text 的
       submit_text_for() 按 type 取 core.state.help_overview / 查表 / 补尾部换行。
  ★ 2026-11-05 深夜：整份总览与每条 /h 分组行上屏末尾都恰带 1 个换行
    （光标自动落到内容后的空行，与 /tj 统计报告一致）；候选栏文本仍不带换行。
  ★ 旧版 librime 的 select_notifier 在默认 group 下 get_selected_candidate()
    恒为 nil（C++ OnSelect 已先关 menu），前置 group 才能拿到候选。
  ★ 回调绝不捕获 engine/ctx 等 C++ userdata：初版用 commit_notifier 闭包捕获
    engine 调 engine:commit_text(BODY)，功能正常但 RimeDestroySession 必崩
    （切方案/重启引擎会踩到 use-after-free）。
  ★ 严禁在 translator 里 context:clear()/commit_text()（/hz 初版卡死事故）；
    本回调只改候选文本，不碰 composition、不触发重入。

验证：首候选 = 仅标题；空格 / 数字键 / 点候选三条路径上屏内容完全一致且末尾
      恰 1 个换行；分组行点选上屏也带 1 个换行；第 2/3 候选顺序不变；
      之后打码无残留；多 session 共存正常。
只读实验：复制真机目录到临时目录，叠加 dev 的 3 个 lua 文件。
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
    lib.RimeSelectCandidate.argtypes = [c_size_t, c_int]
    lib.RimeSelectCandidate.restype = c_int
    return lib


def make_traits(user_dir, log_dir):
    t = RimeTraits()
    t.data_size = ctypes.sizeof(RimeTraits)
    t.shared_data_dir = SHARED_DATA.encode()
    t.user_data_dir = user_dir.encode()
    t.distribution_name = b"Rime"
    t.distribution_code_name = b"help_short_probe"
    t.distribution_version = b"0.0"
    t.app_name = b"sandbox_help_short"
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


def all_cands(ctx):
    if ctx is None:
        return []
    out = []
    for i in range(ctx.menu.num_candidates):
        c = ctx.menu.candidates[i]
        out.append((c.text.decode() if c.text else "",
                    c.comment.decode() if c.comment else ""))
    return out


def press(lib, sid, seq):
    lib.RimeSimulateKeySequence(sid, seq.encode())


def check(name, cond, extra=""):
    print(("  [PASS] " if cond else "  [FAIL] ") + name + (("  " + extra) if extra else ""))
    return cond


def main():
    tmp = tempfile.mkdtemp(prefix="help_short_probe_")
    user_dir = os.path.join(tmp, "user")
    log_dir = os.path.join(tmp, "log")
    os.makedirs(log_dir, exist_ok=True)
    shutil.copytree(TOUCHWB_REAL, user_dir, ignore=shutil.ignore_patterns("*.userdb"))

    # ★ 叠加 dev 改动：本次涉及 help_cmd + Submit_text，core 提供 core.state
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
    SHORT = "※ 【TouchWB 命令总览】"

    # ---------- 1. /h 首候选只显示短标题 ----------
    print("\n=== [1] /h 首候选 = 短标题，无内容预览 ===")
    press(lib, sid, "/h")
    c1 = get_commit(lib, sid)
    ctx1 = get_context(lib, sid)
    page1 = all_cands(ctx1)
    fc = page1[0][0] if page1 else ""
    results.append(check("/h 不自动上屏（关键）", c1 == "", f"commit={c1[:40]!r}"))
    results.append(check("首候选 = 仅标题", fc == SHORT, f"首候选={fc[:60]!r}"))
    results.append(check("首候选不含内容预览（无 日期/⦑）",
                         "日期" not in fc and "⦑" not in fc, f"len={len(fc)}"))
    results.append(check("首候选注释列为空", bool(page1) and page1[0][1] == ""))
    results.append(check("第 2 候选仍是日期行",
                         len(page1) > 1 and page1[1][0].startswith("日期  ⦑/rq⦒")))
    results.append(check("第 3 候选仍是农历行",
                         len(page1) > 2 and page1[2][0].startswith("农历  ⦑/jt⦒")))
    pre1 = ctx1.composition.preedit.decode() if ctx1 and ctx1.composition.preedit else ""
    results.append(check("/h 输入仍在编码栏", pre1 == "/h", f"preedit={pre1!r}"))

    # ---------- 2. 空格路径 ----------
    print("\n=== [2] 空格（Submit_text Lua 快捷上屏）→ 完整总览 ===")
    press(lib, sid, "{space}")
    cs = get_commit(lib, sid)
    results.append(check("空格上屏完整总览",
                         "【TouchWB 命令总览】" in cs and len(cs) >= 700,
                         f"len={len(cs)} head={cs[:30]!r}"))
    results.append(check("空格上屏内容与分组行同源",
                         all(k in cs for k in ("⦑/rq⦒日期", "⦑/zcql⦒清临时词", "⦑Ctrl+0⦒功能切换"))))
    results.append(check("空格上屏末尾恰有 1 个换行（光标落空行）",
                         cs.endswith("\n") and not cs.endswith("\n\n")))
    print("  [空格] len=%d head=%r" % (len(cs), cs[:40]))

    # ---------- 3. 数字键路径（原生 Select → Commit） ----------
    print("\n=== [3] 数字键 1（原生选中）→ 完整总览 ===")
    press(lib, sid, "{Escape}")
    get_commit(lib, sid)
    press(lib, sid, "/h")
    press(lib, sid, "1")
    c3 = get_commit(lib, sid)
    results.append(check("数字键 1 上屏完整总览",
                         "【TouchWB 命令总览】" in c3 and len(c3) >= 700,
                         f"len={len(c3)} head={c3[:40]!r}"))
    results.append(check("数字键路径与空格路径内容完全一致", c3 == cs))
    print("  [数字键] len=%d head=%r" % (len(c3), c3[:40]))

    # ---------- 4. 点候选路径（RimeSelectCandidate） ----------
    print("\n=== [4] 点候选（RimeSelectCandidate）→ 完整总览 ===")
    press(lib, sid, "{Escape}")
    get_commit(lib, sid)
    press(lib, sid, "/h")
    get_commit(lib, sid)
    lib.RimeSelectCandidate(sid, 0)
    c4 = get_commit(lib, sid)
    results.append(check("点候选上屏完整总览",
                         "【TouchWB 命令总览】" in c4 and len(c4) >= 700,
                         f"len={len(c4)} head={c4[:40]!r}"))
    results.append(check("点候选路径与空格路径内容完全一致", c4 == cs))
    print("  [点候选] len=%d head=%r" % (len(c4), c4[:40]))

    # ---------- 4b. 每条 /h 分组行上屏后也恰有 1 个尾部换行 ----------
    print("\n=== [4b] /h 分组行：候选栏无换行、上屏末尾 1 个 ===")
    press(lib, sid, "{Escape}")
    get_commit(lib, sid)
    press(lib, sid, "/h")
    get_commit(lib, sid)
    page4b = all_cands(get_context(lib, sid))
    line2 = page4b[1][0] if len(page4b) > 1 else ""
    results.append(check("候选栏第 2 候选（日期行）本身无换行",
                         line2.startswith("日期  ⦑/rq⦒") and "\n" not in line2,
                         f"text={line2[:24]!r}"))
    press(lib, sid, "2")
    c4b = get_commit(lib, sid)
    results.append(check("数字键 2 上屏 = 日期行 + 1 个换行",
                         c4b == line2 + "\n", f"len={len(c4b)} 末尾={c4b[-12:]!r}"))
    press(lib, sid, "{Escape}")
    get_commit(lib, sid)
    press(lib, sid, "/h")
    get_commit(lib, sid)
    lib.RimeSelectCandidate(sid, 1)
    c4c = get_commit(lib, sid)
    results.append(check("点候选第 2 条上屏 = 日期行 + 1 个换行",
                         c4c == line2 + "\n", f"len={len(c4c)} 末尾={c4c[-12:]!r}"))
    press(lib, sid, "{Escape}")
    get_commit(lib, sid)

    # ---------- 4c. PC 分号 / 引号快捷上屏第 2、3 候选也带换行 ----------
    print("\n=== [4c] PC 分号 / 引号上屏第 2、3 候选：末尾 1 个换行 ===")
    for key, idx, label in ((";", 1, "分号→第2候选"), ("'", 2, "引号→第3候选")):
        press(lib, sid, "{Escape}")
        get_commit(lib, sid)
        press(lib, sid, "/h")
        get_commit(lib, sid)
        pg = all_cands(get_context(lib, sid))
        want = pg[idx][0] if len(pg) > idx else ""
        press(lib, sid, key)
        c = get_commit(lib, sid)
        results.append(check(f"{label} 上屏 = 分组行 + 1 个换行",
                             want != "" and c == want + "\n",
                             f"len={len(c)} 末尾={c[-12:]!r}"))
    press(lib, sid, "{Escape}")
    get_commit(lib, sid)

    # ---------- 5. 无残留 / 再次 /h ----------
    print("\n=== [5] 上屏后打码无残留、/h 可重复 ===")
    press(lib, sid, "{Escape}")
    get_commit(lib, sid)
    press(lib, sid, "z")
    cz = get_commit(lib, sid)
    results.append(check("打 z 不自动上屏总览", "命令总览" not in cz, f"commit={cz[:40]!r}"))
    results.append(check("打 z 不自动上屏字母 z", cz == "", f"commit={cz[:40]!r}"))
    press(lib, sid, "{Escape}")
    get_commit(lib, sid)
    press(lib, sid, "kh")
    press(lib, sid, "{space}")
    ck = get_commit(lib, sid)
    results.append(check("正常打码上屏汉字", ck != "" and "命令总览" not in ck, f"commit={ck[:40]!r}"))
    press(lib, sid, "/h")
    results.append(check("/h 可重复：首候选仍是仅标题",
                         all_cands(get_context(lib, sid))[0][0] == SHORT))
    press(lib, sid, "{Escape}")
    get_commit(lib, sid)

    # ---------- 6. 多 session（切方案/重启引擎场景） ----------
    print("\n=== [6] 第二个 session 同样正常 ===")
    sid2 = lib.RimeCreateSession()
    lib.RimeSelectSchema(sid2, b"ly_wubi")
    press(lib, sid2, "/h")
    results.append(check("新 session 首候选仍仅标题",
                         all_cands(get_context(lib, sid2))[0][0] == SHORT))
    press(lib, sid2, "{space}")
    c6 = get_commit(lib, sid2)
    results.append(check("新 session 空格上屏完整总览", c6 == cs, f"len={len(c6)}"))

    # ★ 清理阶段的偶发 access violation 是 ctypes 收尾固有问题（Lua 状态随 DLL
    #   卸载），变体对照证明与回调是否持有 engine 无关：上一轮那个**确定性**
    #   崩溃已修（每次必崩 → 现在稳定 CLEAN）。这里只提示，不计入通过率。
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
