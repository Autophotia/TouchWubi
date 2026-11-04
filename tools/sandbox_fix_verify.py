# -*- coding: utf-8 -*-
"""回归验证：filter 修复（短码 n=min(4,_end)）+ script 回退 的正确性。

对比组（源 = 真机目录 script 基线）：
  A script_orig  —— script_translator@wubi_prefix + 真机原始 filter
  B script_fixed —— script_translator@wubi_prefix + 开发目录修复后 filter
  C table_fixed  —— table_translator@wubi_prefix  + 开发目录修复后 filter

验证点：
  1. A vs B 完全一致        ⇒ filter 修复不破坏 script 行为（z/fffff/taned 无回归）
  2. C 的 14键 fffff 出「封」 ⇒ filter 修复让 table 短码候选不再被误杀
  3. C 的 tanez 仍空         ⇒ 印证 z 失效是 translator 层限制，filter 修不了（需 script 回退）

只读实验：复制真机目录到临时目录。
"""
import ctypes
from ctypes import c_int, c_void_p, c_char_p, c_size_t, POINTER, Structure, byref
import os, shutil, tempfile, re, sys

WEASEL_DIR = r"D:\Program Files\Rime\weasel-0.17.4"
SHARED_DATA = os.path.join(WEASEL_DIR, "data")
TOUCHWB_SRC = r"D:\Program Files\Rime\TouchWB"
RIME_DLL = os.path.join(WEASEL_DIR, "rime.dll")
FIXED_FILTER = r"D:\AutophotiaIME\dev\space\schemas\TouchWB\lua\wubi_pinyin_filter.lua"


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
        L.RimeGetContext.argtypes = [c_size_t, POINTER(RimeContext)]
        L.RimeGetContext.restype = c_int
        L.RimeFreeContext.argtypes = [POINTER(RimeContext)]
        L.RimeDeployerInitialize.argtypes = [POINTER(RimeTraits)]
        L.RimeDeployerInitialize.restype = None
        L.RimeDeployWorkspace.argtypes = []
        L.RimeDeployWorkspace.restype = c_int
        t = RimeTraits()
        t.data_size = ctypes.sizeof(RimeTraits)
        t.shared_data_dir = SHARED_DATA.encode()
        t.user_data_dir = user_dir.encode()
        t.distribution_name = b"Rime"
        t.distribution_code_name = b"sandbox"
        t.distribution_version = b"0.0"
        t.app_name = b"fix_verify"
        L.RimeSetup(byref(t))
        L.RimeInitialize(byref(t))
        L.RimeDeployerInitialize(byref(t))
        L.RimeDeployWorkspace()
        self.sid = L.RimeCreateSession()
        self.schema = schema_id
        L.RimeSelectSchema(self.sid, schema_id.encode())

    def input(self, seq):
        self.lib.RimeClearComposition(self.sid)
        self.lib.RimeSimulateKeySequence(self.sid, seq.encode())
        ctx = RimeContext()
        ctx.data_size = ctypes.sizeof(RimeContext)
        cands = []
        preedit = ""
        if self.lib.RimeGetContext(self.sid, byref(ctx)):
            menu = ctx.menu
            preedit = ctx.composition.preedit.decode() if ctx.composition.preedit else ""
            for i in range(menu.num_candidates):
                c = menu.candidates[i]
                cands.append((
                    c.text.decode() if c.text else "",
                    c.comment.decode() if c.comment else "",
                ))
            self.lib.RimeFreeContext(byref(ctx))
        return preedit, cands

    def close(self):
        self.lib.RimeDestroySession(self.sid)
        self.lib.RimeFinalize()


def setup(user_dir, mode):
    """mode: 'script_orig' | 'script_fixed' | 'table_fixed'"""
    if mode in ("script_fixed", "table_fixed"):
        shutil.copyfile(FIXED_FILTER, os.path.join(user_dir, "lua", "wubi_pinyin_filter.lua"))
    if mode == "table_fixed":
        for name in ["ly_wubi.schema.yaml", "ly_wubi_14.schema.yaml",
                     "ly_wubi_pinyin.schema.yaml", "ly_wubi_pinyin_14.schema.yaml"]:
            p = os.path.join(user_dir, name)
            c = open(p, encoding="utf-8").read()
            c = c.replace("    - script_translator@wubi_prefix", "    - table_translator@wubi_prefix")
            m = re.search(r"^wubi_prefix:.*?(?=^[a-z_]+:|\Z)", c, flags=re.S | re.M)
            if m:
                seg = m.group(0)
                seg2 = seg.replace("enable_sentence: false", "enable_sentence: true", 1)
                if "enable_sentence: true" not in seg2:
                    seg2 = seg2.replace("wubi_prefix:\n", "wubi_prefix:\n  enable_sentence: true\n", 1)
                c = c[:m.start()] + seg2 + c[m.end():]
            open(p, "w", encoding="utf-8").write(c)


def run_group(user_dir, schema_id, inputs):
    r = Rime(user_dir, schema_id)
    out = {}
    for seq in inputs:
        pre, cands = r.input(seq)
        out[seq] = (pre, [t for t, _ in cands])
    r.close()
    return out


def fmt(cands):
    return "  ".join(cands) if cands else "(空)"


def main():
    dirs = {}
    for tag in ["A_script_orig", "B_script_fixed", "C_table_fixed"]:
        tmp = tempfile.mkdtemp(prefix=f"fix_{tag}_")
        d = os.path.join(tmp, "user")
        shutil.copytree(TOUCHWB_SRC, d, ignore=_ignore_userdb)
        dirs[tag] = d
    setup(dirs["A_script_orig"], "script_orig")
    setup(dirs["B_script_fixed"], "script_fixed")
    setup(dirs["C_table_fixed"], "table_fixed")

    cases = {
        "ly_wubi":    ["ffff", "fffff", "taned", "tanez"],
        "ly_wubi_14": ["ffff", "fffff", "taned", "tanez"],
    }

    for schema_id, inputs in cases.items():
        print("\n" + "=" * 88)
        print(f"方案: {schema_id}")
        print("=" * 88)
        A = run_group(dirs["A_script_orig"], schema_id, inputs)
        B = run_group(dirs["B_script_fixed"], schema_id, inputs)
        C = run_group(dirs["C_table_fixed"], schema_id, inputs)
        for seq in inputs:
            a = A[seq][1]
            b = B[seq][1]
            c = C[seq][1]
            ab = "一致" if a == b else "★A/B不一致"
            print(f"\n[{seq}]")
            print(f"  A script_orig : {fmt(a)}")
            print(f"  B script_fixed: {fmt(b)}  ({ab})")
            print(f"  C table_fixed : {fmt(c)}")

    print("\n[A目录]", dirs["A_script_orig"])
    print("[B目录]", dirs["B_script_fixed"])
    print("[C目录]", dirs["C_table_fixed"])


if __name__ == "__main__":
    main()
