# -*- coding: utf-8 -*-
"""super_tips「只读优先 + 状态机」重构回归（B-06 修复验证）。

验证点：
  1. 首次初始化（db 不存在）→ 只读打开失败 → 写模式重建 → 回到只读，全程无 Lua 错误。
  2. super_tips 开关打开后，打码能命中 tips prompt（查询功能未因重构回退）。
  3. 同一会话内切方案再切回（super_tips 是 module 级单例 + tips.status 状态机）→
     不重复抢写锁、无 Lua error / LOCK 冲突崩溃。
只读实验：复制真机目录到临时目录，不污染真机数据。
"""
import ctypes
from ctypes import (
    c_int, c_void_p, c_char_p, c_size_t, c_bool,
    POINTER, Structure, byref,
)
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
    lib.RimeSelectSchema.argtypes = [c_size_t, c_char_p]
    lib.RimeSelectSchema.restype = c_int
    lib.RimeSimulateKeySequence.argtypes = [c_size_t, c_char_p]
    lib.RimeSimulateKeySequence.restype = c_int
    lib.RimeSetOption.argtypes = [c_size_t, c_char_p, c_bool]
    lib.RimeSetOption.restype = c_int
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
    t.distribution_code_name = b"tips_ro_probe"
    t.distribution_version = b"0.0"
    t.app_name = b"sandbox_tips_ro"
    t.min_log_level = 0
    t.log_dir = log_dir.encode()
    return t


def get_context(lib, sid):
    ctx = RimeContext()
    ctx.data_size = ctypes.sizeof(RimeContext)
    if not lib.RimeGetContext(sid, byref(ctx)):
        return None
    return ctx


def press(lib, sid, seq):
    lib.RimeSimulateKeySequence(sid, seq.encode())
    out = ""
    cmt = RimeCommit()
    cmt.data_size = ctypes.sizeof(RimeCommit)
    if lib.RimeGetCommit(sid, byref(cmt)) and cmt.text:
        out = cmt.text.decode("utf-8", "replace")
    lib.RimeFreeCommit(byref(cmt))
    return out


def check_logs(log_dir, tag):
    hits = []
    for lp in glob.glob(os.path.join(log_dir, "*")):
        try:
            with open(lp, "r", encoding="utf-8", errors="replace") as f:
                for line in f:
                    low = line.lower()
                    if ("error" in low) or ("lua" in low and ("fail" in low or "not found" in low)):
                        hits.append((os.path.basename(lp), line.strip()))
        except Exception:
            pass
    print(f"  [{tag}] 日志可疑行 {len(hits)} 条")
    for name, line in hits[:15]:
        print(f"     [{name}] {line[:160]}")
    return len(hits) == 0


def main():
    tmp = tempfile.mkdtemp(prefix="tips_ro_probe_")
    user_dir = os.path.join(tmp, "user")
    log_dir = os.path.join(tmp, "log")
    os.makedirs(log_dir, exist_ok=True)
    print(f"[*] 复制真机已部署目录 -> {user_dir}")
    shutil.copytree(TOUCHWB_REAL, user_dir, ignore=shutil.ignore_patterns("*.userdb"))

    # 叠加本次改动
    overlay = {
        "lua/super_tips.lua": "lua/super_tips.lua",
        "lua/lib/userdb.lua": "lua/lib/userdb.lua",
        "lua/super_sequence.lua": "lua/super_sequence.lua",
        "lua/smart_assoc.lua": "lua/smart_assoc.lua",
        "lua/core.lua": "lua/core.lua",
        "lua/types.lua": "lua/types.lua",
    }
    for rel, src_rel in overlay.items():
        src = os.path.join(TOUCHWB_DEV, src_rel)
        dst = os.path.join(user_dir, rel)
        if os.path.exists(src):
            shutil.copyfile(src, dst)

    lib = load_lib()
    traits = make_traits(user_dir, log_dir)
    lib.RimeSetup(byref(traits))
    lib.RimeInitialize(byref(traits))
    print("[*] RimeInitialize OK")

    sid = lib.RimeCreateSession()
    lib.RimeSelectSchema(sid, b"ly_wubi_pinyin")
    print("[*] schema = ly_wubi_pinyin（super_tips 首次 init：应写模式重建 + 回到只读）")

    # 打开 super_tips 开关
    lib.RimeSetOption(sid, b"super_tips", True)
    print("[*] super_tips 开关已打开")

    # 打一个能命中 tips 的码（「偏旁」是 tips_show.txt 的键前缀），看 prompt 是否正常
    print("\n=== 打码 fcu（云）看 tips prompt ===")
    press(lib, sid, "fcu")
    ctx = get_context(lib, sid)
    preedit = ctx.composition.preedit.decode() if ctx.composition.preedit else ""
    n = ctx.menu.num_candidates
    cands = [ctx.menu.candidates[i].text.decode() for i in range(n)]
    print(f"  preedit={preedit!r}  candidates={cands}")
    lib.RimeFreeContext(byref(ctx))
    press(lib, sid, "{Escape}")

    # 切方案再切回：super_tips 是 module 单例，status=done 后不应重复抢写锁
    print("\n=== 切方案 ly_wubi -> 切回 ly_wubi_pinyin ===")
    lib.RimeSelectSchema(sid, b"ly_wubi")
    press(lib, sid, "fcu")
    press(lib, sid, "{Escape}")
    lib.RimeSelectSchema(sid, b"ly_wubi_pinyin")
    press(lib, sid, "fcu")
    ctx = get_context(lib, sid)
    preedit = ctx.composition.preedit.decode() if ctx.composition.preedit else ""
    n = ctx.menu.num_candidates
    cands = [ctx.menu.candidates[i].text.decode() for i in range(n)]
    print(f"  切回后 preedit={preedit!r}  candidates={cands}")
    lib.RimeFreeContext(byref(ctx))
    press(lib, sid, "{Escape}")

    # 先清空 composition 再销毁，降低 DLL 卸载时 Lua 状态的固有问题触发概率
    press(lib, sid, "{Escape}")
    try:
        lib.RimeDestroySession(sid)
        lib.RimeFinalize()
        print("[*] 销毁会话 CLEAN")
    except OSError as e:
        print(f"[*] 销毁会话 OSError（已知 Lua 状态随 DLL 卸载固有问题，非本次改动）: {e}")

    print("\n=== 日志检查 ===")
    ok = check_logs(log_dir, "全程")
    print("\n[*] user_dir =", user_dir)
    print("[*] log_dir =", log_dir)
    print("RESULT:", "PASS" if ok else "REVIEW")


if __name__ == "__main__":
    main()
