# -*- coding: utf-8 -*-
"""core.state 迁移冒烟回归：验证 smart_assoc / pair_punct 改从 _G 迁到 core.state 后不回归。

验证点：
  1. require "core" 能正确解析（core.lua / types.lua 随 dev 完整目录一起复制）。
  2. smart_assoc.lua（require core + mark_assoc_seg 写 core.state.assoc_seg）正常加载。
  3. pair_punct.lua（require core + 读 core.state.assoc_seg / punct_exempt / punct_dbg）正常加载。
  4. 打码出候选 + 上屏 + 按标点，整条链路无 Lua 加载/运行错误。
只读实验：复制 dev 方案目录到临时目录，不污染真机数据。
"""
import ctypes
from ctypes import (
    c_int, c_void_p, c_char_p, c_size_t,
    POINTER, Structure, byref,
)
import os, shutil, tempfile, glob

WEASEL_DIR = r"D:\Program Files\Rime\weasel-0.17.4"
SHARED_DATA = os.path.join(WEASEL_DIR, "data")
TOUCHWB_REAL = r"D:\Program Files\Rime\TouchWB"          # 已部署目录（含 build/*.bin + predict.db）
TOUCHWB_DEV = r"D:\AutophotiaIME\dev\space\schemas\TouchWB"  # 源目录（含改动后的 lua）
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
    t.distribution_code_name = b"core_state_smoke"
    t.distribution_version = b"0.0"
    t.app_name = b"sandbox_core_state"
    t.min_log_level = 0  # DEBUG，抓 Lua 加载错误
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
    tmp = tempfile.mkdtemp(prefix="core_state_smoke_")
    user_dir = os.path.join(tmp, "user")
    log_dir = os.path.join(tmp, "log")
    os.makedirs(log_dir, exist_ok=True)
    print(f"[*] 复制真机已部署目录 -> {user_dir}")
    shutil.copytree(TOUCHWB_REAL, user_dir, ignore=shutil.ignore_patterns("*.userdb"))

    # 叠加本次改动/新增的 lua 文件（core/type 迁移 + 造词数据层拆分）
    overlay = {
        "lua/core.lua": "lua/core.lua",
        "lua/types.lua": "lua/types.lua",
        "lua/smart_assoc.lua": "lua/smart_assoc.lua",
        "lua/pair_punct.lua": "lua/pair_punct.lua",
        "lua/Submit_text.lua": "lua/Submit_text.lua",
        "lua/user_coined_db.lua": "lua/user_coined_db.lua",
        "lua/auto_coined.lua": "lua/auto_coined.lua",
        "lua/user_coined_cmd.lua": "lua/user_coined_cmd.lua",
        "lua/super_sequence.lua": "lua/super_sequence.lua",
        "lua/input_statistics.lua": "lua/input_statistics.lua",
    }
    print("[*] 叠加 dev 改动文件：")
    for rel, src_rel in overlay.items():
        src = os.path.join(TOUCHWB_DEV, src_rel)
        dst = os.path.join(user_dir, rel)
        if not os.path.exists(src):
            print(f"    MISS src {src}")
            continue
        shutil.copyfile(src, dst)
        print(f"    OK  {rel}")

    # 确认核心文件就位
    for rel in ["lua/core.lua", "lua/types.lua", "lua/smart_assoc.lua", "lua/pair_punct.lua",
                "build/ly_wubi_pinyin.prism.bin", "predict.db"]:
        p = os.path.join(user_dir, rel)
        print(f"    {'OK ' if os.path.exists(p) else 'MISS'} {rel}")

    lib = load_lib()
    traits = make_traits(user_dir, log_dir)
    lib.RimeSetup(byref(traits))
    lib.RimeInitialize(byref(traits))
    print("[*] RimeInitialize OK")

    sid = lib.RimeCreateSession()
    lib.RimeSelectSchema(sid, b"ly_wubi_pinyin")
    print("[*] schema = ly_wubi_pinyin")

    # 打码出候选（smart_assoc P 加载并跑 mark_assoc_seg）
    print("\n=== 打码 fcu（云）===")
    press(lib, sid, "fcu")
    dump(get_context(lib, sid), "fcu")
    c1 = press(lib, sid, " ")  # 上屏
    print(f"  [commit] {c1!r}")

    # 按标点（pair_punct 读 core.state.*）
    print("\n=== 按分号 / 引号 ===")
    for seq in [";", "{quotedbl}", "{apostrophe}"]:
        c = press(lib, sid, seq)
        print(f"  [{seq}] commit={c!r}")

    # 再打一组，确认多次按键后状态表读写无异常
    print("\n=== 打码 whnt（个性）===")
    press(lib, sid, "whnt")
    dump(get_context(lib, sid), "whnt")
    c2 = press(lib, sid, " ")
    print(f"  [commit] {c2!r}")

    # 造词链路：/zctj 命令触发 user_coined_cmd translator + db.uc_list_manual（读 UserDb）
    print("\n=== 造词命令 /zctj（触发 user_coined_cmd + user_coined_db）===")
    press(lib, sid, "/zctj")
    dump(get_context(lib, sid), "/zctj")
    press(lib, sid, " ")

    # 自造词 translator 链路：打一个 ≥2 字母码触发 user_coined_translator（db.uc_open/uc_query）
    print("\n=== 打码 xy（触发 user_coined_translator）===")
    press(lib, sid, "xy")
    dump(get_context(lib, sid), "xy")
    press(lib, sid, " ")

    # 输入统计链路：/tj 触发 input_statistics（顶层 MOBILE_MODE = core.is_mobile()）
    print("\n=== 统计命令 /tj（触发 input_statistics）===")
    press(lib, sid, "/tj")
    dump(get_context(lib, sid), "/tj")
    press(lib, sid, " ")

    lib.RimeDestroySession(sid)
    lib.RimeFinalize()

    # 检查日志里的 Lua 错误
    print("\n=== 日志检查 ===")
    logs = glob.glob(os.path.join(log_dir, "*"))
    err_hits = []
    for lp in logs:
        try:
            with open(lp, "r", encoding="utf-8", errors="replace") as f:
                for line in f:
                    low = line.lower()
                    if "error" in low or "lua" in low and ("fail" in low or "not found" in low or "require" in low):
                        err_hits.append((os.path.basename(lp), line.strip()))
        except Exception as e:
            print(f"  [read log failed] {e}")
    if err_hits:
        print(f"  ⚠ 发现 {len(err_hits)} 条可疑日志：")
        for name, line in err_hits[:20]:
            print(f"     [{name}] {line[:160]}")
    else:
        print("  未发现 Lua error / require 失败日志")

    print("\n[*] done. user_dir =", user_dir)
    print("[*] log_dir =", log_dir)


if __name__ == "__main__":
    main()
