# -*- coding: utf-8 -*-
"""沙盒1：排在 fallback_segmentor 之后的 lua_segmentor 是否为死代码？

源码证据（engine.cc CalculateSegmentation）：
    for (auto& entry : segmentors_) {
      if (!entry.enabled) continue;
      if (!entry.component->Proceed(segments)) break;   // 返回 false 即 break
    }
FallbackSegmentor::Proceed 恒返回 false ⇒ 排在它后面的 segmentor 每轮都被 break 挡掉。

实证设计（三处落盘标记）：
  A. 顶层标记：pair_punct.lua require 时执行 —— 证明「模块已加载 + io 库可用」
  B. processor.func 标记：正对照 —— 证明「lua func 调用机制 + 注入有效」
  C. segmentor.func 标记：实验 —— 是否被调用（死代码判定）
预期：A ✅、B ✅、C ❌ ⇒ 死代码成立。
"""
import ctypes
from ctypes import c_int, c_void_p, c_char_p, c_size_t, POINTER, Structure, byref
import os, shutil, tempfile

WEASEL_DIR = r"D:\Program Files\Rime\weasel-0.17.4"
SHARED_DATA = os.path.join(WEASEL_DIR, "data")
TOUCHWB_SRC = r"D:\Program Files\Rime\TouchWB"
RIME_DLL = os.path.join(WEASEL_DIR, "rime.dll")
M_TOP = r"D:\seg_top.txt"
M_PROC = r"D:\seg_proc.txt"
M_SEG = r"D:\seg_seg.txt"

class RimeTraits(Structure):
    _fields_ = [
        ("data_size", c_int), ("shared_data_dir", c_char_p), ("user_data_dir", c_char_p),
        ("distribution_name", c_char_p), ("distribution_code_name", c_char_p),
        ("distribution_version", c_char_p), ("app_name", c_char_p),
        ("modules", POINTER(c_char_p)), ("min_log_level", c_int), ("log_dir", c_char_p),
        ("prebuilt_data_dir", c_char_p), ("staging_dir", c_char_p),
    ]


def write_marker(path):
    return f'local _m = io.open([[{path}]], "w"); if _m then _m:write("CALLED\\n"); _m:close() end'


def inject(user_dir):
    pp = os.path.join(user_dir, "lua", "pair_punct.lua")
    c = open(pp, encoding="utf-8").read()
    # A. 顶层标记
    c = write_marker(M_TOP) + "\n" + c
    # B. processor.func 正对照（真实签名 (key, env)）
    old_b = "function processor.func(key, env)\n"
    assert old_b in c
    c = c.replace(old_b, old_b + "    " + write_marker(M_PROC) + "\n", 1)
    # C. segmentor.func 实验
    old_c = "function segmentor.func(segmentation, env)\n"
    assert old_c in c
    c = c.replace(old_c, old_c + "    " + write_marker(M_SEG) + "\n", 1)
    open(pp, "w", encoding="utf-8").write(c)


def main():
    tmp = tempfile.mkdtemp(prefix="seg_final_")
    user_dir = os.path.join(tmp, "user")
    shutil.copytree(TOUCHWB_SRC, user_dir)
    inject(user_dir)

    for m in (M_TOP, M_PROC, M_SEG):
        if os.path.exists(m):
            os.remove(m)

    os.add_dll_directory(WEASEL_DIR)
    lib = ctypes.WinDLL(RIME_DLL)
    lib.RimeSetup.argtypes = [POINTER(RimeTraits)]
    lib.RimeInitialize.argtypes = [POINTER(RimeTraits)]
    lib.RimeFinalize.argtypes = []
    lib.RimeCreateSession.restype = c_size_t
    lib.RimeDestroySession.argtypes = [c_size_t]
    lib.RimeSelectSchema.argtypes = [c_size_t, c_char_p]
    lib.RimeSimulateKeySequence.argtypes = [c_size_t, c_char_p]

    t = RimeTraits()
    t.data_size = ctypes.sizeof(RimeTraits)
    t.shared_data_dir = SHARED_DATA.encode()
    t.user_data_dir = user_dir.encode()
    t.distribution_name = b"Rime"
    t.distribution_code_name = b"sandbox"
    t.distribution_version = b"0.0"
    t.app_name = b"seg_deadcode"
    lib.RimeSetup(byref(t))
    lib.RimeInitialize(byref(t))

    sid = lib.RimeCreateSession()
    lib.RimeSelectSchema(sid, b"ly_wubi_pinyin_14")
    for s in ["(", ")", "[", "]", "ab", "wubi", "`", "#", "{", "}"]:
        lib.RimeSimulateKeySequence(sid, s.encode())
    lib.RimeDestroySession(sid)
    lib.RimeFinalize()

    top = os.path.exists(M_TOP)
    proc = os.path.exists(M_PROC)
    seg = os.path.exists(M_SEG)

    print("=" * 64)
    print(f"  A 顶层（模块加载+io可用）: {'✅' if top else '❌'}")
    print(f"  B processor.func（正对照）: {'✅ 被调用' if proc else '❌'}")
    print(f"  C segmentor.func（实验）  : {'✅ 被调用' if seg else '❌ 未被调用'}")
    print("=" * 64)
    if top and proc and not seg:
        print("裁决：死代码成立。lua 模块正常加载、processor 正常被调用，唯独 segmentor 从不执行")
        print("      —— 与源码一致：fallback_segmentor 恒返回 false → break 挡掉其后的 lua_segmentor。")
    else:
        print(f"裁决：结果异常（top={top} proc={proc} seg={seg}），需排查。")
    print("[临时目录]", user_dir)


if __name__ == "__main__":
    main()
