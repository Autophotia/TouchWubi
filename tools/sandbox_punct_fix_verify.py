# -*- coding: utf-8 -*-
"""标点乱出字修复验证（决定性版）：初始空状态 predictor 预测候选 ['我','第'] 时按标点。

A = 真机原始（修复前）；B = dev 修复后。
关键：会话刚创建（未上屏任何字）时 predictor 会预测「我、第」，正是用户报告的场景。
"""
import ctypes
from ctypes import c_int, c_char_p, c_size_t, c_void_p, POINTER, Structure, byref
import os, shutil, tempfile

WEASEL_DIR = r"D:\Program Files\Rime\weasel-0.17.4"
SHARED_DATA = os.path.join(WEASEL_DIR, "data")
TOUCHWB_SRC = r"D:\Program Files\Rime\TouchWB"
RIME_DLL = os.path.join(WEASEL_DIR, "rime.dll")
DEV_PAIR = r"D:\AutophotiaIME\dev\space\schemas\TouchWB\lua\pair_punct.lua"
DEV_DEFAULT = r"D:\AutophotiaIME\dev\space\schemas\TouchWB\default.yaml"
DEV_SUPER = r"D:\AutophotiaIME\dev\space\schemas\TouchWB\lua\super_sequence.lua"


class RimeTraits(Structure):
    _fields_ = [
        ("data_size", c_int), ("shared_data_dir", c_char_p), ("user_data_dir", c_char_p),
        ("distribution_name", c_char_p), ("distribution_code_name", c_char_p),
        ("distribution_version", c_char_p), ("app_name", c_char_p),
        ("modules", POINTER(c_char_p)), ("min_log_level", c_int), ("log_dir", c_char_p),
        ("prebuilt_data_dir", c_char_p), ("staging_dir", c_char_p),
    ]


class RimeComposition(Structure):
    _fields_ = [
        ("length", c_int), ("cursor_pos", c_int), ("sel_start", c_int), ("sel_end", c_int),
        ("preedit", c_char_p),
    ]


class RimeCandidate(Structure):
    _fields_ = [("text", c_char_p), ("comment", c_char_p), ("reserved", c_void_p)]


class RimeMenu(Structure):
    _fields_ = [
        ("page_size", c_int), ("page_no", c_int), ("is_last_page", c_int),
        ("highlighted_candidate_index", c_int), ("num_candidates", c_int),
        ("candidates", POINTER(RimeCandidate)), ("select_keys", c_char_p),
    ]


class RimeContext(Structure):
    _fields_ = [
        ("data_size", c_int), ("composition", RimeComposition), ("menu", RimeMenu),
        ("commit_text_preview", c_char_p), ("select_labels", POINTER(c_char_p)),
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
        L.RimeCreateSession.restype = c_size_t
        L.RimeDestroySession.argtypes = [c_size_t]
        L.RimeSelectSchema.argtypes = [c_size_t, c_char_p]
        L.RimeSimulateKeySequence.argtypes = [c_size_t, c_char_p]
        L.RimeGetContext.argtypes = [c_size_t, POINTER(RimeContext)]
        L.RimeGetContext.restype = c_int
        L.RimeFreeContext.argtypes = [POINTER(RimeContext)]
        L.RimeGetCommit.argtypes = [c_size_t, POINTER(RimeCommit)]
        L.RimeFreeCommit.argtypes = [POINTER(RimeCommit)]
        t = RimeTraits()
        t.data_size = ctypes.sizeof(RimeTraits)
        t.shared_data_dir = SHARED_DATA.encode()
        t.user_data_dir = user_dir.encode()
        t.distribution_name = b"Rime"
        t.distribution_code_name = b"sandbox"
        t.distribution_version = b"0.0"
        t.app_name = b"punct_fix2"
        L.RimeSetup(byref(t))
        L.RimeInitialize(byref(t))
        self.sid = L.RimeCreateSession()
        L.RimeSelectSchema(self.sid, schema_id.encode())

    def press(self, seq):
        self.lib.RimeSimulateKeySequence(self.sid, seq.encode())
        cmt = RimeCommit()
        cmt.data_size = ctypes.sizeof(RimeCommit)
        out = ""
        if self.lib.RimeGetCommit(self.sid, byref(cmt)) and cmt.text:
            out = cmt.text.decode("utf-8", "replace")
        self.lib.RimeFreeCommit(byref(cmt))
        return out

    def menu_texts(self):
        ctx = RimeContext()
        ctx.data_size = ctypes.sizeof(RimeContext)
        texts = []
        if self.lib.RimeGetContext(self.sid, byref(ctx)):
            n = ctx.menu.num_candidates
            if n > 0 and ctx.menu.candidates:
                for i in range(min(n, 6)):
                    c = ctx.menu.candidates[i]
                    texts.append(c.text.decode("utf-8", "replace") if c.text else "?")
        self.lib.RimeFreeContext(byref(ctx))
        return texts

    def close(self):
        self.lib.RimeDestroySession(self.sid)
        self.lib.RimeFinalize()


def main():
    dirs = {}
    for tag in ["A_orig", "B_dev"]:
        tmp = tempfile.mkdtemp(prefix=f"punctfix2_{tag}_")
        d = os.path.join(tmp, "user")
        shutil.copytree(TOUCHWB_SRC, d, ignore=_ignore_userdb)
        dirs[tag] = d
    shutil.copyfile(DEV_PAIR, os.path.join(dirs["B_dev"], "lua", "pair_punct.lua"))
    shutil.copyfile(DEV_DEFAULT, os.path.join(dirs["B_dev"], "default.yaml"))
    shutil.copyfile(DEV_SUPER, os.path.join(dirs["B_dev"], "lua", "super_sequence.lua"))

    for schema_id in ["ly_wubi_pinyin", "ly_wubi"]:
        print("=" * 70)
        print(f"方案: {schema_id}")
        print("=" * 70)
        for tag in ["A_orig", "B_dev"]:
            r = Rime(dirs[tag], schema_id)
            menu0 = r.menu_texts()
            # 初始空状态（有预测候选）直接按标点键
            q1 = r.press("{quotedbl}")
            r2 = Rime(dirs[tag], schema_id)  # 每键独立会话，避免状态串扰
            m0 = r2.menu_texts(); s1 = r2.press("{semicolon}")
            r3 = Rime(dirs[tag], schema_id)
            a1 = r3.press("{apostrophe}")
            r4 = Rime(dirs[tag], schema_id)
            q2 = r4.press("{question}")
            r.close(); r2.close(); r3.close(); r4.close()
            print(f"\n[{tag}] 初始预测候选 = {menu0}")
            print(f"   双引号 -> {q1!r}    分号 -> {s1!r}    单引号 -> {a1!r}    问号 -> {q2!r}")

    print("\n[A_orig 目录]", dirs["A_orig"])
    print("[B_dev 目录]", dirs["B_dev"])


if __name__ == "__main__":
    main()
