# -*- coding: utf-8 -*-
"""自动造词「自动造词」无法召回转正 复现（真实 rime.dll）。

复现用户报告：连打「自动造词长度」等，4 字临时词「自动造词」(tfty) 无法召回转正，
而「自动乖戾/自动千户/自动选词」(同为 tfty)、「自动第二遍」(tftf) 都能。

按键序列：
  1. 开 auto_coined 开关
  2. 打「自动」thfc+空格 → commit 自动
  3. 打「造词」tfyn + 数字2（造词是第2候选）→ commit 造词
  4. 打「长度」taya+空格 → commit 长度
  5. 看 debug 日志里造出了哪些临时词
  6. 打 tfty → 看候选（召回自动X）
只读实验：复制真机目录到临时目录。
"""
import ctypes
from ctypes import c_int, c_void_p, c_char_p, c_size_t, c_bool, POINTER, Structure, byref
import os, shutil, tempfile, glob

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
    lib.RimeSelectSchema.argtypes = [c_size_t, c_char_p]
    lib.RimeSelectSchema.restype = c_int
    lib.RimeSetOption.argtypes = [c_size_t, c_char_p, c_bool]
    lib.RimeSetOption.restype = c_bool
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
    t.distribution_code_name = b"coin_zdc_probe"
    t.distribution_version = b"0.0"
    t.app_name = b"sandbox_zdc"
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
    cands = []
    for i in range(n):
        c = ctx.menu.candidates[i]
        text = c.text.decode() if c.text else ""
        comment = c.comment.decode() if c.comment else ""
        cands.append(f"{text}({comment})" if comment else text)
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
    tmp = tempfile.mkdtemp(prefix="coin_zdc_")
    user_dir = os.path.join(tmp, "user")
    log_dir = os.path.join(tmp, "log")
    os.makedirs(log_dir, exist_ok=True)
    print(f"[*] 复制真机目录 -> {user_dir}")
    shutil.copytree(TOUCHWB_REAL, user_dir, ignore=shutil.ignore_patterns("*.userdb"))

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
        else:
            print(f"    MISS {rel}")

    # 注入 debug tags：auto_coined + COIN:
    core_path = os.path.join(user_dir, "lua", "core.lua")
    with open(core_path, "r", encoding="utf-8") as f:
        s = f.read()
    s2 = s.replace("    debug_tags = {},",
                   '    debug_tags = { ["auto_coined"] = true, ["COIN:"] = true },')
    with open(core_path, "w", encoding="utf-8") as f:
        f.write(s2)
    print("[*] 注入 debug_tags = { auto_coined, COIN: }")

    lib = load_lib()
    traits = make_traits(user_dir, log_dir)
    lib.RimeSetup(byref(traits))
    lib.RimeInitialize(byref(traits))
    sid = lib.RimeCreateSession()
    lib.RimeSelectSchema(sid, b"ly_wubi")
    print("[*] schema = ly_wubi")

    print("\n=== 开 auto_coined ===")
    ok = lib.RimeSetOption(sid, b"auto_coined", c_bool(True))
    print(f"  RimeSetOption(auto_coined,true) = {ok}")

    # 打「自动」thfc + 空格
    print("\n=== 自动 (thfc + space) ===")
    press(lib, sid, "thfc")
    dump(get_context(lib, sid), "thfc 后")
    c = press(lib, sid, " ")
    print(f"  [commit] {c!r}")

    # 打「造词」tfyn + 数字2
    print("\n=== 造词 (tfyn + 2) ===")
    press(lib, sid, "tfyn")
    dump(get_context(lib, sid), "tfyn 后")
    c = press(lib, sid, "2")
    print(f"  [commit] {c!r}")
    dump(get_context(lib, sid), "选2 后")

    # 打「长度」taya + 空格
    print("\n=== 长度 (taya + space) ===")
    press(lib, sid, "taya")
    dump(get_context(lib, sid), "taya 后")
    c = press(lib, sid, " ")
    print(f"  [commit] {c!r}")

    # 召回：打 tfty
    print("\n=== 召回 tfty ===")
    press(lib, sid, "tfty")
    dump(get_context(lib, sid), "tfty 后")

    # 选中第1候选（自动造词☯）转正
    print("\n=== 选中「自动造词☯」转正 ===")
    c = press(lib, sid, "1")
    print(f"  [commit] {c!r}")
    dump(get_context(lib, sid), "选1 后")

    # /zctj 验证转正
    print("\n=== /zctj 验证转正 ===")
    press(lib, sid, "/zctj")
    dump(get_context(lib, sid), "/zctj")

    # 召回 tftf 对照
    print("\n=== 召回 tftf（对照）===")
    press(lib, sid, "{Escape}")
    press(lib, sid, "tftf")
    dump(get_context(lib, sid), "tftf 后")

    lib.RimeDestroySession(sid)
    lib.RimeFinalize()

    print("\n=== touchwb_debug.log（造词相关）===")
    dbg = os.path.join(user_dir, "touchwb_debug.log")
    if os.path.exists(dbg):
        with open(dbg, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                if "temp" in line or "skip main" in line or "promote" in line or "recall" in line:
                    print("  " + line.rstrip("\n"))
    else:
        print("  (无 touchwb_debug.log)")

    print("\n[*] user_dir =", user_dir)


if __name__ == "__main__":
    main()
