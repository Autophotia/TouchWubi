# -*- coding: utf-8 -*-
"""rime.dll (librime 1.13.1) 探针：验证真实 rime 环境可调用，跑通「加载方案→模拟输入→取候选」链路。
用途：为「坑1 lua_segmentor 时序」「坑2 derive 别名词频」两个沙盒提供真实引擎地基。
只读实验：复制 TouchWB 用户目录到临时目录，不污染真机数据。
"""
import ctypes
from ctypes import (
    c_int, c_void_p, c_char_p, c_size_t,
    POINTER, Structure, byref,
)
import os, shutil, tempfile

WEASEL_DIR = r"D:\Program Files\Rime\weasel-0.17.4"
SHARED_DATA = os.path.join(WEASEL_DIR, "data")
TOUCHWB_SRC = r"D:\Program Files\Rime\TouchWB"
RIME_DLL = os.path.join(WEASEL_DIR, "rime.dll")

# ---------- 结构体（librime 1.13.1 rime_api.h 精确字段） ----------
class RimeTraits(Structure):
    _fields_ = [
        ("data_size", c_int),
        ("shared_data_dir", c_char_p),      # v0.9
        ("user_data_dir", c_char_p),
        ("distribution_name", c_char_p),
        ("distribution_code_name", c_char_p),
        ("distribution_version", c_char_p),
        ("app_name", c_char_p),             # v1.0
        ("modules", POINTER(c_char_p)),     # const char**
        ("min_log_level", c_int),           # v1.6
        ("log_dir", c_char_p),
        ("prebuilt_data_dir", c_char_p),
        ("staging_dir", c_char_p),
    ]

class RimeCandidate(Structure):
    _fields_ = [
        ("text", c_char_p),
        ("comment", c_char_p),
        ("reserved", c_void_p),
    ]

class RimeMenu(Structure):
    _fields_ = [
        ("page_size", c_int),
        ("page_no", c_int),
        ("is_last_page", c_int),
        ("highlighted_candidate_index", c_int),
        ("num_candidates", c_int),
        ("candidates", POINTER(RimeCandidate)),
        ("select_keys", c_char_p),
    ]

class RimeComposition(Structure):
    _fields_ = [
        ("length", c_int),
        ("cursor_pos", c_int),
        ("sel_start", c_int),
        ("sel_end", c_int),
        ("preedit", c_char_p),
    ]

class RimeContext(Structure):
    _fields_ = [
        ("data_size", c_int),
        ("composition", RimeComposition),
        ("menu", RimeMenu),
        ("commit_text_preview", c_char_p),  # v0.9.2
        ("select_labels", POINTER(c_char_p)),  # v1.0
    ]

class RimeCommit(Structure):
    _fields_ = [
        ("data_size", c_int),
        ("text", c_char_p),
    ]

class RimeSchemaListItem(Structure):
    _fields_ = [
        ("schema_id", c_char_p),
        ("name", c_char_p),
        ("reserved", c_void_p),
    ]

class RimeSchemaList(Structure):
    _fields_ = [
        ("size", c_size_t),
        ("list", POINTER(RimeSchemaListItem)),
    ]


def load_lib():
    os.add_dll_directory(WEASEL_DIR)
    lib = ctypes.WinDLL(RIME_DLL)
    # 注意：librime 1.13 的 get_schema_list / get_context / get_commit 都是「输出参数 + Bool 返回」模式
    lib.RimeSetup.argtypes = [POINTER(RimeTraits)]
    lib.RimeInitialize.argtypes = [POINTER(RimeTraits)]
    lib.RimeFinalize.argtypes = []
    lib.RimeCreateSession.restype = c_size_t
    lib.RimeCreateSession.argtypes = []
    lib.RimeDestroySession.argtypes = [c_size_t]
    lib.RimeDestroySession.restype = c_int
    lib.RimeGetSchemaList.argtypes = [POINTER(RimeSchemaList)]
    lib.RimeGetSchemaList.restype = c_int
    lib.RimeFreeSchemaList.argtypes = [POINTER(RimeSchemaList)]
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


def make_traits(user_dir):
    t = RimeTraits()
    t.data_size = ctypes.sizeof(RimeTraits)
    t.shared_data_dir = SHARED_DATA.encode()
    t.user_data_dir = user_dir.encode()
    t.distribution_name = b"Rime"
    t.distribution_code_name = b"probe"
    t.distribution_version = b"0.0"
    t.app_name = b"sandbox_probe"
    return t


def get_context(lib, sid):
    ctx = RimeContext()
    ctx.data_size = ctypes.sizeof(RimeContext)
    ok = lib.RimeGetContext(sid, byref(ctx))
    if not ok:
        return None
    return ctx


def dump_candidates(ctx, label=""):
    menu = ctx.menu
    preedit = ctx.composition.preedit.decode() if ctx.composition.preedit else ""
    print(f"  [{label}] preedit={preedit!r}  num_candidates={menu.num_candidates}")
    for i in range(menu.num_candidates):
        c = menu.candidates[i]
        text = c.text.decode() if c.text else ""
        comment = c.comment.decode() if c.comment else ""
        print(f"     {i}: text={text!r}  comment={comment!r}")


def main():
    tmp = tempfile.mkdtemp(prefix="rime_probe_")
    user_dir = os.path.join(tmp, "user")
    print(f"[*] 复制用户目录 -> {user_dir}")
    shutil.copytree(TOUCHWB_SRC, user_dir)
    print(f"[*] shared_data_dir = {SHARED_DATA}")

    lib = load_lib()
    traits = make_traits(user_dir)
    lib.RimeSetup(byref(traits))
    lib.RimeInitialize(byref(traits))
    print("[*] RimeInitialize OK")

    sl = RimeSchemaList()
    ok = lib.RimeGetSchemaList(byref(sl))
    print(f"[*] RimeGetSchemaList ok={ok}  size={sl.size}")
    for i in range(sl.size):
        item = sl.list[i]
        print(f"     schema_id={item.schema_id.decode()!r}  name={item.name.decode()!r}")
    lib.RimeFreeSchemaList(byref(sl))

    sid = lib.RimeCreateSession()
    print(f"[*] session_id = {sid}")
    lib.RimeSelectSchema(sid, b"ly_wubi_pinyin_14")

    for seq in [b"wubi", b"pinyin"]:
        print(f"\n=== 模拟输入: {seq.decode()} ===")
        lib.RimeSimulateKeySequence(sid, seq)
        ctx = get_context(lib, sid)
        if ctx:
            dump_candidates(ctx, seq.decode())
            lib.RimeFreeContext(byref(ctx))
        cmt = RimeCommit()
        if lib.RimeGetCommit(sid, byref(cmt)) and cmt.text:
            print(f"  [commit] {cmt.text.decode()!r}")
            lib.RimeFreeCommit(byref(cmt))

    lib.RimeDestroySession(sid)
    lib.RimeFinalize()
    print("\n[*] done. user_dir =", user_dir)


if __name__ == "__main__":
    main()
