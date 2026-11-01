# -*- coding: utf-8 -*-
"""沙盒2：14 键 derive 变体命中的候选，词频是否被清除？
源码结论（calculus.cc + dictionary.cc）：普通 derive 不设 type/credibility，weight 保留。
本沙盒用真实 rime.dll 实证：
  输入「主要字母 q」= 精确命中 q 编码词 + derive 变体命中 w 编码词（derive/w/q/ 让 w 编码词也能用 q 查到）
  输入「次要字母 w」= 精确命中 w 编码词
对比两批「w 编码词」的相对顺序是否一致 —— 一致 ⇒ derive 保留词频。
"""
import ctypes
from ctypes import c_int, c_void_p, c_char_p, c_size_t, POINTER, Structure, byref
import os, shutil, tempfile

WEASEL_DIR = r"D:\Program Files\Rime\weasel-0.17.4"
SHARED_DATA = os.path.join(WEASEL_DIR, "data")
TOUCHWB_SRC = r"D:\Program Files\Rime\TouchWB"
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
    _fields_ = [("page_size", c_int), ("page_no", c_int), ("is_last_page", c_int),
                ("highlighted_candidate_index", c_int), ("num_candidates", c_int),
                ("candidates", POINTER(RimeCandidate)), ("select_keys", c_char_p)]
class RimeComposition(Structure):
    _fields_ = [("length", c_int), ("cursor_pos", c_int), ("sel_start", c_int),
                ("sel_end", c_int), ("preedit", c_char_p)]
class RimeContext(Structure):
    _fields_ = [("data_size", c_int), ("composition", RimeComposition), ("menu", RimeMenu),
                ("commit_text_preview", c_char_p), ("select_labels", POINTER(c_char_p))]


class Rime:
    def __init__(self, user_dir):
        os.add_dll_directory(WEASEL_DIR)
        self.lib = ctypes.WinDLL(RIME_DLL)
        L = self.lib
        L.RimeSetup.argtypes = [POINTER(RimeTraits)]
        L.RimeInitialize.argtypes = [POINTER(RimeTraits)]
        L.RimeFinalize.argtypes = []
        L.RimeCreateSession.restype = c_size_t
        L.RimeDestroySession.argtypes = [c_size_t]
        L.RimeSelectSchema.argtypes = [c_size_t, c_char_p]
        L.RimeSelectSchema.restype = c_int
        L.RimeSimulateKeySequence.argtypes = [c_size_t, c_char_p]
        L.RimeSimulateKeySequence.restype = c_int
        L.RimeClearComposition.argtypes = [c_size_t]
        L.RimeClearComposition.restype = c_int
        L.RimeGetContext.argtypes = [c_size_t, POINTER(RimeContext)]
        L.RimeGetContext.restype = c_int
        L.RimeFreeContext.argtypes = [POINTER(RimeContext)]

        t = RimeTraits()
        t.data_size = ctypes.sizeof(RimeTraits)
        t.shared_data_dir = SHARED_DATA.encode()
        t.user_data_dir = user_dir.encode()
        t.distribution_name = b"Rime"
        t.distribution_code_name = b"sandbox"
        t.distribution_version = b"0.0"
        t.app_name = b"derive_freq_test"
        L.RimeSetup(byref(t))
        L.RimeInitialize(byref(t))
        self.sid = L.RimeCreateSession()
        L.RimeSelectSchema(self.sid, b"ly_wubi_pinyin_14")

    def clear(self):
        self.lib.RimeClearComposition(self.sid)

    def input(self, seq):
        self.clear()
        self.lib.RimeSimulateKeySequence(self.sid, seq.encode())
        ctx = RimeContext()
        ctx.data_size = ctypes.sizeof(RimeContext)
        if not self.lib.RimeGetContext(self.sid, byref(ctx)):
            return "", []
        menu = ctx.menu
        cands = []
        for i in range(menu.num_candidates):
            c = menu.candidates[i]
            cands.append((
                c.text.decode() if c.text else "",
                c.comment.decode() if c.comment else "",
            ))
        preedit = ctx.composition.preedit.decode() if ctx.composition.preedit else ""
        self.lib.RimeFreeContext(byref(ctx))
        return preedit, cands

    def close(self):
        self.lib.RimeDestroySession(self.sid)
        self.lib.RimeFinalize()


def main():
    tmp = tempfile.mkdtemp(prefix="derive_freq_")
    user_dir = os.path.join(tmp, "user")
    shutil.copytree(TOUCHWB_SRC, user_dir)
    r = Rime(user_dir)

    # 主要字母 -> 次要字母（derive 方向：次要→主要）
    pairs = [("q", "w"), ("e", "r"), ("t", "y"), ("u", "i"), ("o", "p"),
             ("a", "s"), ("d", "f"), ("g", "h"), ("j", "k"), ("x", "c"),
             ("v", "b"), ("n", "m")]

    print("=" * 78)
    print("对比：主要字母(精确) vs 次要字母(derive)。格式：text(comment)")
    print("=" * 78)
    for primary, secondary in pairs:
        pre1, c1 = r.input(primary)
        pre2, c2 = r.input(secondary)
        s1 = "  ".join(f"{t}[{cm}]" for t, cm in c1[:10])
        s2 = "  ".join(f"{t}[{cm}]" for t, cm in c2[:10])
        print(f"\n[{primary}] preedit={pre1!r}")
        print(f"     {s1}")
        print(f"[{secondary}] preedit={pre2!r}")
        print(f"     {s2}")

    r.close()
    print("\n[临时目录]", user_dir)


if __name__ == "__main__":
    main()
