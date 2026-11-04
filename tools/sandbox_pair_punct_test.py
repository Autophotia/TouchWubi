# -*- coding: utf-8 -*-
"""pair_punct 引号交替验证：改动后（dev）vs 改动前（真机原始）。

验证点：
  1. 改动后空状态连按两次 quotedbl：第一次出「“」、第二次出「”」（交替）
  2. 改动前（真机原始 pair_punct.lua）空状态按一次 quotedbl：一次出「“”」（一对）
只读实验：复制真机目录到临时目录。
"""
import ctypes
from ctypes import c_int, c_void_p, c_char_p, c_size_t, POINTER, Structure, byref
import os, shutil, tempfile

WEASEL_DIR = r"D:\Program Files\Rime\weasel-0.17.4"
SHARED_DATA = os.path.join(WEASEL_DIR, "data")
TOUCHWB_SRC = r"D:\Program Files\Rime\TouchWB"
RIME_DLL = os.path.join(WEASEL_DIR, "rime.dll")
DEV_PAIR = r"D:\AutophotiaIME\dev\space\schemas\TouchWB\lua\pair_punct.lua"
DEV_SUBMIT = r"D:\AutophotiaIME\dev\space\schemas\TouchWB\lua\Submit_text.lua"


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


def _ignore_userdb(dirpath, names):
    return [n for n in names if n.endswith(".userdb")]


class Rime:
    def __init__(self, user_dir, schema_id):
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
        L.RimeGetCommit.argtypes = [c_size_t, POINTER(RimeCommit)]
        L.RimeGetCommit.restype = c_int
        L.RimeFreeCommit.argtypes = [POINTER(RimeCommit)]
        t = RimeTraits()
        t.data_size = ctypes.sizeof(RimeTraits)
        t.shared_data_dir = SHARED_DATA.encode()
        t.user_data_dir = user_dir.encode()
        t.distribution_name = b"Rime"
        t.distribution_code_name = b"sandbox"
        t.distribution_version = b"0.0"
        t.app_name = b"pair_punct_test"
        L.RimeSetup(byref(t))
        L.RimeInitialize(byref(t))
        self.sid = L.RimeCreateSession()
        L.RimeSelectSchema(self.sid, schema_id.encode())

    def press(self, seq):
        """模拟按键并返回本次产生的 commit 文本（读后即清空累积）。"""
        self.lib.RimeSimulateKeySequence(self.sid, seq.encode())
        cmt = RimeCommit()
        cmt.data_size = ctypes.sizeof(RimeCommit)
        out = ""
        if self.lib.RimeGetCommit(self.sid, byref(cmt)) and cmt.text:
            out = cmt.text.decode("utf-8", "replace")
        self.lib.RimeFreeCommit(byref(cmt))
        return out

    def close(self):
        self.lib.RimeDestroySession(self.sid)
        self.lib.RimeFinalize()


def main():
    # A：真机原始 pair_punct.lua（改动前：一次一对）
    # B：dev 改动后 pair_punct.lua（交替）
    dirs = {}
    for tag in ["A_orig", "B_dev"]:
        tmp = tempfile.mkdtemp(prefix=f"pair_{tag}_")
        d = os.path.join(tmp, "user")
        shutil.copytree(TOUCHWB_SRC, d, ignore=_ignore_userdb)
        dirs[tag] = d
    shutil.copyfile(DEV_PAIR, os.path.join(dirs["B_dev"], "lua", "pair_punct.lua"))
    shutil.copyfile(DEV_SUBMIT, os.path.join(dirs["B_dev"], "lua", "Submit_text.lua"))

    for schema_id in ["ly_wubi_pinyin", "ly_wubi"]:
        print("\n" + "=" * 70)
        print(f"方案: {schema_id}")
        print("=" * 70)
        for tag in ["A_orig", "B_dev"]:
            r = Rime(dirs[tag], schema_id)
            # 空状态连按两次双引号（{quotedbl} 花括号语法才是单键，否则被当成字母串）
            c1 = r.press("{quotedbl}")
            c2 = r.press("{quotedbl}")
            # 空状态连按两次单引号
            c3 = r.press("{apostrophe}")
            c4 = r.press("{apostrophe}")
            r.close()
            print(f"[{tag}] quotedbl: 第1次={c1!r}  第2次={c2!r}   |  apostrophe: 第1次={c3!r}  第2次={c4!r}")

    print("\n[A_orig 目录]", dirs["A_orig"])
    print("[B_dev 目录]", dirs["B_dev"])


if __name__ == "__main__":
    main()
