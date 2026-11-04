# -*- coding: utf-8 -*-
"""综合验证：number 键盘 ascii_mode=1 下 @ 键完整链路 + = 键回归。"""
import ctypes, os, shutil, tempfile
from ctypes import c_int, c_char_p, c_size_t, c_void_p, POINTER, Structure, byref

WEASEL_DIR = r'D:/Program Files\Rime\weasel-0.17.4'
SHARED_DATA = os.path.join(WEASEL_DIR, 'data')
TOUCHWB_SRC = r'D:/Program Files\Rime\TouchWB'
RIME_DLL = os.path.join(WEASEL_DIR, 'rime.dll')

class RimeTraits(Structure):
    _fields_ = [('data_size', c_int), ('shared_data_dir', c_char_p), ('user_data_dir', c_char_p),
        ('distribution_name', c_char_p), ('distribution_code_name', c_char_p),
        ('distribution_version', c_char_p), ('app_name', c_char_p),
        ('modules', POINTER(c_char_p)), ('min_log_level', c_int), ('log_dir', c_char_p),
        ('prebuilt_data_dir', c_char_p), ('staging_dir', c_char_p)]
class RimeComposition(Structure):
    _fields_ = [('length', c_int), ('cursor_pos', c_int), ('sel_start', c_int),
        ('sel_end', c_int), ('preedit', c_char_p)]
class RimeCandidate(Structure):
    _fields_ = [('text', c_char_p), ('comment', c_char_p), ('reserved', c_void_p)]
class RimeMenu(Structure):
    _fields_ = [('page_size', c_int), ('page_no', c_int), ('is_last_page', c_int),
        ('highlighted_candidate_index', c_int), ('num_candidates', c_int),
        ('candidates', POINTER(RimeCandidate)), ('select_keys', c_char_p)]
class RimeContext(Structure):
    _fields_ = [('data_size', c_int), ('composition', RimeComposition), ('menu', RimeMenu),
        ('commit_text_preview', c_char_p), ('select_labels', POINTER(c_char_p))]
class RimeCommit(Structure):
    _fields_ = [('data_size', c_int), ('text', c_char_p)]

os.add_dll_directory(WEASEL_DIR)
tmp = tempfile.mkdtemp(prefix='atfull_')
d = os.path.join(tmp, 'android', 'user'); os.makedirs(d)
logdir = os.path.join(tmp, 'log'); os.makedirs(logdir)
shutil.copytree(TOUCHWB_SRC, d, dirs_exist_ok=True, ignore=lambda *a: [n for n in a[1] if n.endswith('.userdb')])

lib = ctypes.WinDLL(RIME_DLL)
L = lib
L.RimeSetup.argtypes = [POINTER(RimeTraits)]; L.RimeInitialize.argtypes = [POINTER(RimeTraits)]
L.RimeCreateSession.restype = c_size_t; L.RimeDestroySession.argtypes = [c_size_t]
L.RimeSelectSchema.argtypes = [c_size_t, c_char_p]
L.RimeSimulateKeySequence.argtypes = [c_size_t, c_char_p]
L.RimeGetContext.argtypes = [c_size_t, POINTER(RimeContext)]; L.RimeGetContext.restype = c_int
L.RimeFreeContext.argtypes = [POINTER(RimeContext)]
L.RimeGetCommit.argtypes = [c_size_t, POINTER(RimeCommit)]; L.RimeFreeCommit.argtypes = [POINTER(RimeCommit)]
L.RimeSetOption.argtypes = [c_size_t, c_char_p, c_int]; L.RimeSetOption.restype = c_int
L.RimeGetOption.argtypes = [c_size_t, c_char_p]; L.RimeGetOption.restype = c_int

t = RimeTraits(); t.data_size = ctypes.sizeof(RimeTraits)
t.shared_data_dir = SHARED_DATA.encode(); t.user_data_dir = d.encode()
t.distribution_name = b'Rime'; t.distribution_code_name = b'sb'
t.distribution_version = b'0'; t.app_name = b'atfull'
t.min_log_level = 0; t.log_dir = logdir.encode()
L.RimeSetup(byref(t)); L.RimeInitialize(byref(t))
sid = L.RimeCreateSession(); L.RimeSelectSchema(sid, b'ly_wubi_pinyin')

def commit():
    cmt = RimeCommit(); cmt.data_size = ctypes.sizeof(RimeCommit); out = ''
    if L.RimeGetCommit(sid, byref(cmt)) and cmt.text:
        out = cmt.text.decode('utf-8', 'replace')
    L.RimeFreeCommit(byref(cmt)); return out

def ctx_snapshot():
    ctx = RimeContext(); ctx.data_size = ctypes.sizeof(RimeContext)
    preedit = ''; mts = []; clen = 0
    if L.RimeGetContext(sid, byref(ctx)):
        if ctx.composition.preedit:
            preedit = ctx.composition.preedit.decode('utf-8', 'replace')
        clen = ctx.composition.length
        n = ctx.menu.num_candidates
        if n > 0 and ctx.menu.candidates:
            for i in range(min(n, 10)):
                c = ctx.menu.candidates[i]
                mts.append(repr(c.text.decode('utf-8', 'replace') if c.text else '?'))
    L.RimeFreeContext(byref(ctx))
    return preedit, mts, clen

def press(seq, label):
    L.RimeSimulateKeySequence(sid, seq.encode())
    cmt = commit()
    preedit, mts, clen = ctx_snapshot()
    am = L.RimeGetOption(sid, b"ascii_mode")
    print(f"  [{label}] commit={cmt!r}  preedit={preedit!r}  clen={clen}  ascii_mode={am}  menu={mts[:6]}")
    return cmt

L.RimeSetOption(sid, b"ascii_mode", 1)

print("===== 场景A：上滑 @（send @）=====")
press("{at}", "@键")

print("\n===== 场景B：@ 后输入 qq 空格（期望上屏 @qq.com）=====")
L.RimeSimulateKeySequence(sid, b"{Escape}")
L.RimeSetOption(sid, b"ascii_mode", 1)
press("{at}", "@键")
press("q", "q")
press("q", "q")
press("{space}", "空格")

print("\n===== 场景C：= 后空格（回归，期望上屏 =）=====")
L.RimeSimulateKeySequence(sid, b"{Escape}")
L.RimeSetOption(sid, b"ascii_mode", 1)
press("{equal}", "=键")
press("{space}", "空格")

print("\n===== 场景D：@ 上屏后按数字（期望恢复 ascii_mode=1）=====")
L.RimeSimulateKeySequence(sid, b"{Escape}")
L.RimeSetOption(sid, b"ascii_mode", 1)
press("{at}", "@键")
press("{space}", "空格上屏@")
press("9", "数字9")

L.RimeDestroySession(sid); L.RimeFinalize()
