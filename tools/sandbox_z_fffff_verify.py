# -*- coding: utf-8 -*-
"""精简探针：只测 ly_wubi / ly_wubi_14 的 ffff/fffff/tanez/taned，script vs table。"""
import ctypes
from ctypes import c_int, c_void_p, c_char_p, c_size_t, POINTER, Structure, byref
import os, shutil, tempfile, re, sys

WEASEL_DIR = r"D:\Program Files\Rime\weasel-0.17.4"
SHARED_DATA = os.path.join(WEASEL_DIR, "data")
TOUCHWB_SRC = r"D:\Program Files\Rime\TouchWB"
RIME_DLL = os.path.join(WEASEL_DIR, "rime.dll")
DUMP = r"D:\zf_dump.txt"

DUMP_LUA = r'''local LOG = [[D:\zf_dump.txt]]
local function log(msg)
    local f = io.open(LOG, "a")
    if f then f:write(msg .. "\n"); f:close() end
end
local function filter(input, env)
    local ctx = env.engine.context
    local input_str = tostring(ctx.input or "")
    local n = 0
    for cand in input:iter() do
        n = n + 1
        log(string.format("input=%q [%d] text=%q type=%s start=%s _end=%s q=%s comment=%q",
            input_str, n, tostring(cand.text), tostring(cand.type),
            tostring(cand.start), tostring(cand._end), tostring(cand.quality),
            tostring(cand.comment)))
        yield(cand)
    end
    log(string.format("input=%q [END] total=%d", input_str, n))
end
return { func = filter }
'''


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
        t.app_name = b"zf_verify"
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
    with open(os.path.join(user_dir, "lua", "dump_zf.lua"), "w", encoding="utf-8") as f:
        f.write(DUMP_LUA)
    for name in ["ly_wubi.schema.yaml", "ly_wubi_14.schema.yaml"]:
        p = os.path.join(user_dir, name)
        c = open(p, encoding="utf-8").read()
        c = c.replace(
            "    - lua_filter@*new_spelling",
            "    - lua_filter@*dump_zf\n    - lua_filter@*new_spelling",
        )
        if mode == "table":
            c = c.replace(
                "    - script_translator@wubi_prefix",
                "    - table_translator@wubi_prefix",
            )
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
        out[seq] = (pre, cands)
    r.close()
    return out


def fmt(cands):
    return "  ".join(f"{t}[{cm}]" if cm else t for t, cm in cands)


def main():
    if os.path.exists(DUMP):
        os.remove(DUMP)

    dirs = {}
    for tag in ["S_script", "T_table"]:
        tmp = tempfile.mkdtemp(prefix=f"zf_{tag}_")
        d = os.path.join(tmp, "user")
        shutil.copytree(TOUCHWB_SRC, d, ignore=_ignore_userdb)
        dirs[tag] = d

    setup(dirs["S_script"], "script")
    setup(dirs["T_table"], "table")

    c = open(os.path.join(dirs["T_table"], "ly_wubi.schema.yaml"), encoding="utf-8").read()
    print(f"[*] T_table script残留={'script_translator@wubi_prefix' in c}  table={'table_translator@wubi_prefix' in c}", flush=True)

    cases = {
        "ly_wubi":    ["ffff", "fffff", "taned", "tanez"],
        "ly_wubi_14": ["ffff", "fffff", "taned", "tanez"],
    }

    for schema_id, inputs in cases.items():
        print("\n" + "=" * 90, flush=True)
        print(f"方案: {schema_id}", flush=True)
        print("=" * 90, flush=True)
        S = run_group(dirs["S_script"], schema_id, inputs)
        T = run_group(dirs["T_table"], schema_id, inputs)
        for seq in inputs:
            sp, sc = S[seq]
            tp, tc = T[seq]
            mark = "（同）" if (sc == tc) else "（★差异）"
            print(f"\n[输入 {seq!r}]", flush=True)
            print(f"  S script preedit={sp!r}  {fmt(sc) or '(空)'}", flush=True)
            print(f"  T table  preedit={tp!r}  {fmt(tc) or '(空)'}  {mark}", flush=True)

    print("\n" + "=" * 90, flush=True)
    print("dump（过滤前候选流）:", flush=True)
    print("=" * 90, flush=True)
    if os.path.exists(DUMP):
        lines = [l for l in open(DUMP, encoding="utf-8").read().splitlines() if l.strip()]
        want = ('input="ffff"', 'input="fffff"', 'input="tanez"', 'input="taned"')
        for l in lines:
            if any(w in l for w in want):
                print(l[:200], flush=True)

    print("\n[S目录]", dirs["S_script"], flush=True)
    print("[T目录]", dirs["T_table"], flush=True)


if __name__ == "__main__":
    main()
