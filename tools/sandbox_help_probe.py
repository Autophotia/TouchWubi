# -*- coding: utf-8 -*-
"""/h 帮助命令 候选完整性验证（真实 rime.dll）。

打 /h 翻页，打印全部候选分组，确认新增的 PC 调序/快捷键/输入技巧都在。
只读实验：复制真机目录到临时目录。
"""
import ctypes
from ctypes import c_int, c_void_p, c_char_p, c_size_t, c_bool, POINTER, Structure, byref
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
    return lib


def make_traits(user_dir, log_dir):
    t = RimeTraits()
    t.data_size = ctypes.sizeof(RimeTraits)
    t.shared_data_dir = SHARED_DATA.encode()
    t.user_data_dir = user_dir.encode()
    t.distribution_name = b"Rime"
    t.distribution_code_name = b"help_probe"
    t.distribution_version = b"0.0"
    t.app_name = b"sandbox_help"
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
    print(f"  [{label}] preedit={preedit!r}  page={ctx.menu.page_no} last={ctx.menu.is_last_page} n={n}")
    for i in range(n):
        c = ctx.menu.candidates[i]
        text = c.text.decode() if c.text else ""
        comment = c.comment.decode() if c.comment else ""
        print(f"      {i}: {text}  |  {comment}")


def press(lib, sid, seq):
    lib.RimeSimulateKeySequence(sid, seq.encode())


def main():
    tmp = tempfile.mkdtemp(prefix="help_probe_")
    user_dir = os.path.join(tmp, "user")
    log_dir = os.path.join(tmp, "log")
    os.makedirs(log_dir, exist_ok=True)
    shutil.copytree(TOUCHWB_REAL, user_dir, ignore=shutil.ignore_patterns("*.userdb"))
    # ★ 首候选短标题依赖 core.state 与 Submit_text 的空格补段，一并叠加 dev 版
    for rel in ["lua/help_cmd.lua", "lua/Submit_text.lua", "lua/core.lua",
                "lua/input_statistics.lua", "lua/schedule.lua",
                "lua/super_sequence.lua"]:
        shutil.copyfile(os.path.join(TOUCHWB_DEV, rel), os.path.join(user_dir, rel))

    lib = load_lib()
    traits = make_traits(user_dir, log_dir)
    lib.RimeSetup(byref(traits))
    lib.RimeInitialize(byref(traits))
    sid = lib.RimeCreateSession()
    lib.RimeSelectSchema(sid, b"ly_wubi")

    press(lib, sid, "/h")
    dump(get_context(lib, sid), "/h 第1页")

    # 翻页（Right = Page_Down）看全
    press(lib, sid, "{Right}")
    dump(get_context(lib, sid), "/h 第2页")
    press(lib, sid, "{Right}")
    dump(get_context(lib, sid), "/h 第3页")

    lib.RimeDestroySession(sid)
    lib.RimeFinalize()


if __name__ == "__main__":
    main()
