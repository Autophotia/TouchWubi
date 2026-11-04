# -*- coding: utf-8 -*-
"""自动调频（auto_freq）PC 端回归验证。

验证点：PC 端（非移动端）下，数字键 / 分号(send2) / 引号(send3) 三种上屏方式
连续上屏同一个词两次后，该词是否被自动调频提到第一候选。

每个用例用不同编码，避免调频记录互相污染（无需 /txzq 清空）。

用法：python3 tools/sandbox_af_verify.py
"""
import ctypes, os, shutil, tempfile
from ctypes import c_int, c_char_p, c_size_t, c_void_p, POINTER, Structure, byref

WEASEL_DIR = r'D:\Program Files\Rime\weasel-0.17.4'
SHARED_DATA = os.path.join(WEASEL_DIR, 'data')
TOUCHWB_SRC = r'D:\Program Files\Rime\TouchWB'
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
tmp = tempfile.mkdtemp(prefix='afver_')
d = os.path.join(tmp, 'user')  # PC 端：路径不含 /android/ ⇒ is_mobile_device()=false
os.makedirs(d)
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
t.distribution_version = b'0'; t.app_name = b'afver'
t.min_log_level = 0; t.log_dir = logdir.encode()
L.RimeSetup(byref(t)); L.RimeInitialize(byref(t))
sid = L.RimeCreateSession(); L.RimeSelectSchema(sid, b'ly_wubi_pinyin')

def commit():
    cmt = RimeCommit(); cmt.data_size = ctypes.sizeof(RimeCommit); out = ''
    if L.RimeGetCommit(sid, byref(cmt)) and cmt.text:
        out = cmt.text.decode('utf-8', 'replace')
    L.RimeFreeCommit(byref(cmt)); return out

def menu():
    ctx = RimeContext(); ctx.data_size = ctypes.sizeof(RimeContext)
    mts = []
    if L.RimeGetContext(sid, byref(ctx)):
        n = ctx.menu.num_candidates
        if n > 0 and ctx.menu.candidates:
            for i in range(min(n, 8)):
                c = ctx.menu.candidates[i]
                mts.append(c.text.decode('utf-8', 'replace') if c.text else '?')
    L.RimeFreeContext(byref(ctx))
    return mts

def press(seq, label):
    L.RimeSimulateKeySequence(sid, seq.encode())
    cmt = commit()
    m = menu()
    print(f"  [{label}] commit={cmt!r} menu={m}")
    return cmt, m

def esc():
    L.RimeSimulateKeySequence(sid, b"{Escape}")
    commit()

print("auto_freq 开关 =", L.RimeGetOption(sid, b"auto_freq"))

print("\n===== 1. 引号 send3 连续上屏「小幅度」（imya 第3候选）=====")
press("imya", "敲码")
press("{apostrophe}", "引号第1次")
press("imya", "敲码")
press("{apostrophe}", "引号第2次")
_, m = press("imya", "敲码看顺序")
assert m[0] == '小幅度', f"FAIL: 引号路径未提权, menu={m}"
print("  PASS：引号 send3 自动调频生效，小幅度排第一")

print("\n===== 2. 数字键 3 连续上屏「云」（fcu 第3候选）=====")
esc()
press("fcu", "敲码")
press("3", "数字3第1次")
press("fcu", "敲码")
press("3", "数字3第2次")
_, m = press("fcu", "敲码看顺序")
assert m[0] == '云', f"FAIL: 数字键路径未提权, menu={m}"
print("  PASS：数字键 3 自动调频生效，云排第一")

print("\n===== 3. 分号 send2 连续上屏「个性」（whnt 第2候选）=====")
esc()
press("whnt", "敲码")
press("{semicolon}", "分号第1次")
press("whnt", "敲码")
press("{semicolon}", "分号第2次")
_, m = press("whnt", "敲码看顺序")
assert m[0] == '个性', f"FAIL: 分号路径未提权, menu={m}"
print("  PASS：分号 send2 自动调频生效，个性排第一")

print("\n===== 4. 数字键 2 连续上屏「的」（rq 第2候选）=====")
esc()
press("rq", "敲码")
press("2", "数字2第1次")
press("rq", "敲码")
press("2", "数字2第2次")
_, m = press("rq", "敲码看顺序")
assert m[0] == '的', f"FAIL: 数字键2路径未提权, menu={m}"
print("  PASS：数字键 2 自动调频生效，的排第一")

L.RimeDestroySession(sid); L.RimeFinalize()
print("\n全部 4 条 PC 端上屏路径验证通过 ✓")
