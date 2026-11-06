# -*- coding: utf-8 -*-
"""手动造词「空格上屏 vs 点选上屏」差异复现（真实 rime.dll）。

复现用户报告：手机端手动造词空格上屏不累积、点选上屏累积；PC 端空格/数字/分号引号全失败。
用真实 librime 模拟按键序列，观察 Submit_text 的手动造词累积（update_notifier）行为。

按键序列（徐码式手动造词）：
  1. 长按Z → 反引号 `
  2. 输「中」编码 kh → 空格上屏「中」
  3. 长按Z → 反引号 `
  4. 输「国」编码 lg → 空格上屏「国」
  5. 长按Z → 反引号 ` → 空格保存整词「中国」
  6. /zctj 列出词条，看是否成功写入「中国」

只读实验：复制真机已部署目录到临时目录，不污染真机数据。
"""
import ctypes
from ctypes import c_int, c_void_p, c_char_p, c_size_t, POINTER, Structure, byref
import os, shutil, tempfile, glob, sys

WEASEL_DIR = r"D:\Program Files\Rime\weasel-0.17.4"
SHARED_DATA = os.path.join(WEASEL_DIR, "data")
TOUCHWB_REAL = r"D:\Program Files\Rime\TouchWB"
TOUCHWB_DEV = r"D:\AutophotiaIME\dev\space\schemas\TouchWB"
RIME_DLL = os.path.join(WEASEL_DIR, "rime.dll")


class RimeTraits(Structure):
    _fields_ = [
        ("data_size", c_int),
        ("shared_data_dir", c_char_p),
        ("user_data_dir", c_char_p),
        ("distribution_name", c_char_p),
        ("distribution_code_name", c_char_p),
        ("distribution_version", c_char_p),
        ("app_name", c_char_p),
        ("modules", POINTER(c_char_p)),
        ("min_log_level", c_int),
        ("log_dir", c_char_p),
        ("prebuilt_data_dir", c_char_p),
        ("staging_dir", c_char_p),
    ]


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


class RimeCommit(Structure):
    _fields_ = [("data_size", c_int), ("text", c_char_p)]


def load_lib():
    os.add_dll_directory(WEASEL_DIR)
    lib = ctypes.WinDLL(RIME_DLL)
    lib.RimeSetup.argtypes = [POINTER(RimeTraits)]
    lib.RimeInitialize.argtypes = [POINTER(RimeTraits)]
    lib.RimeFinalize.argtypes = []
    lib.RimeCreateSession.restype = c_size_t
    lib.RimeCreateSession.argtypes = []
    lib.RimeDestroySession.argtypes = [c_size_t]
    lib.RimeDestroySession.restype = c_int
    lib.RimeSelectSchema.argtypes = [c_size_t, c_char_p]
    lib.RimeSelectSchema.restype = c_int
    lib.RimeSimulateKeySequence.argtypes = [c_size_t, c_char_p]
    lib.RimeSimulateKeySequence.restype = c_int
    lib.RimeGetContext.argtypes = [c_size_t, POINTER(RimeContext)]
    lib.RimeGetContext.restype = c_int
    lib.RimeFreeContext.argtypes = [POINTER(RimeContext)]
    lib.RimeGetCommit.argtypes = [c_size_t, POINTER(RimeCommit)]
    lib.RimeGetCommit.restype = c_int
    lib.RimeFreeCommit.argtypes = [POINTER(RimeCommit)]
    return lib


def make_traits(user_dir, log_dir):
    t = RimeTraits()
    t.data_size = ctypes.sizeof(RimeTraits)
    t.shared_data_dir = SHARED_DATA.encode()
    t.user_data_dir = user_dir.encode()
    t.distribution_name = b"Rime"
    t.distribution_code_name = b"coin_space_probe"
    t.distribution_version = b"0.0"
    t.app_name = b"sandbox_coin_space"
    t.min_log_level = 0
    t.log_dir = log_dir.encode()
    return t


def get_context(lib, sid):
    ctx = RimeContext()
    ctx.data_size = ctypes.sizeof(RimeContext)
    if not lib.RimeGetContext(sid, byref(ctx)):
        return None
    return ctx


def dump(ctx, label):
    if ctx is None:
        print(f"  [{label}] <no context>")
        return
    preedit = ctx.composition.preedit.decode() if ctx.composition.preedit else ""
    n = ctx.menu.num_candidates
    cands = [ctx.menu.candidates[i].text.decode() for i in range(n)]
    print(f"  [{label}] preedit={preedit!r}  candidates={cands}")


def press(lib, sid, seq):
    lib.RimeSimulateKeySequence(sid, seq.encode())
    out = ""
    cmt = RimeCommit()
    cmt.data_size = ctypes.sizeof(RimeCommit)
    if lib.RimeGetCommit(sid, byref(cmt)) and cmt.text:
        out = cmt.text.decode("utf-8", "replace")
    lib.RimeFreeCommit(byref(cmt))
    return out


def main():
    tmp = tempfile.mkdtemp(prefix="coin_space_")
    user_dir = os.path.join(tmp, "user")
    log_dir = os.path.join(tmp, "log")
    os.makedirs(log_dir, exist_ok=True)
    print(f"[*] 复制真机已部署目录 -> {user_dir}")
    shutil.copytree(TOUCHWB_REAL, user_dir, ignore=shutil.ignore_patterns("*.userdb"))

    # 叠加 dev 改动 lua（模块化重构后）
    overlay = [
        "lua/core.lua", "lua/types.lua", "lua/Submit_text.lua",
        "lua/user_coined_db.lua", "lua/user_coined_cmd.lua",
        "lua/user_coined_translator.lua", "lua/auto_coined.lua",
    ]
    for rel in overlay:
        src = os.path.join(TOUCHWB_DEV, rel)
        dst = os.path.join(user_dir, rel)
        if os.path.exists(src):
            shutil.copyfile(src, dst)
            print(f"    OK  {rel}")
        else:
            print(f"    MISS {rel}")

    # 注入调试：开 Submit_text + COIN 两个 tag，观察 input_text 真实值
    core_path = os.path.join(user_dir, "lua", "core.lua")
    with open(core_path, "r", encoding="utf-8") as f:
        s = f.read()
    s2 = s.replace("    debug_tags = {},",
                   '    debug_tags = { ["Submit_text"] = true, ["COIN:"] = true },')
    if s2 == s:
        print("  ✗ 未找到 debug_tags 占位")
    else:
        with open(core_path, "w", encoding="utf-8") as f:
            f.write(s2)
        print("[*] 已注入 debug_tags = { Submit_text, COIN: }")

    # 在 notifier 回调开头加探针日志，确认 notifier 是否触发、size/bt 值
    st_path = os.path.join(user_dir, "lua", "Submit_text.lua")
    with open(st_path, "r", encoding="utf-8") as f:
        st = f.read()
    anchor = "                local size, bt = nil, nil\n"
    probe = ("                kcoin(\"ntf.probe\", \"FIRE size=\" .. tostring(size) .. \" bt=\" .. tostring(bt) .. \" pend=\" .. tostring(_coin_pending_input) .. \" last_size=\" .. tostring(_coin_last_size))\n"
             "                local size, bt = nil, nil\n")
    if anchor in st and "ntf.probe" not in st:
        st = st.replace(anchor, probe, 1)
        with open(st_path, "w", encoding="utf-8") as f:
            f.write(st)
        print("[*] 已注入 notifier 探针日志")
    else:
        print("[!] notifier 探针注入跳过（anchor 未命中或已注入）")

    lib = load_lib()
    traits = make_traits(user_dir, log_dir)
    lib.RimeSetup(byref(traits))
    lib.RimeInitialize(byref(traits))
    print("[*] RimeInitialize OK")

    sid = lib.RimeCreateSession()
    lib.RimeSelectSchema(sid, b"ly_wubi")
    print("[*] schema = ly_wubi")

    # 反引号键探测
    print("\n=== 反引号键（长按Z）===")
    press(lib, sid, "{grave}")
    dump(get_context(lib, sid), "grave 之后")

    # 输「中」编码 kh
    print("\n=== 输 kh ===")
    press(lib, sid, "kh")
    dump(get_context(lib, sid), "kh 之后")

    # 空格上屏
    print("\n=== 空格上屏 ===")
    c = press(lib, sid, " ")
    print(f"  [commit] {c!r}")
    dump(get_context(lib, sid), "空格上屏后")

    # 反引号 + 国编码 lg
    print("\n=== 反引号 + lg ===")
    press(lib, sid, "{grave}")
    press(lib, sid, "lg")
    dump(get_context(lib, sid), "`lg 之后")
    c = press(lib, sid, " ")
    print(f"  [commit] {c!r}")
    dump(get_context(lib, sid), "空格上屏后")

    # 长按Z再空格保存
    print("\n=== 长按Z + 空格（保存）===")
    press(lib, sid, "{grave}")
    dump(get_context(lib, sid), "保存前 `")
    c = press(lib, sid, " ")
    print(f"  [commit] {c!r}")
    dump(get_context(lib, sid), "保存后")

    # /zctj 检查
    print("\n=== /zctj 列词条 ===")
    press(lib, sid, "{Escape}")
    press(lib, sid, "/zctj")
    dump(get_context(lib, sid), "/zctj")

    lib.RimeDestroySession(sid)
    lib.RimeFinalize()

    # 检查日志里 Lua 错误
    print("\n=== 日志检查 ===")
    logs = glob.glob(os.path.join(log_dir, "*"))
    for lp in logs:
        try:
            with open(lp, "r", encoding="utf-8", errors="replace") as f:
                for line in f:
                    low = line.lower()
                    if ("error" in low or "fail" in low) and ("lua" in low or "require" in low or "not found" in low):
                        print(f"  ⚠ {line.strip()[:180]}")
        except Exception as e:
            print(f"  [read log failed] {e}")

    print("\n[*] done. user_dir =", user_dir)
    print("[*] log_dir =", log_dir)


if __name__ == "__main__":
    main()
