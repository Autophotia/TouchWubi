# -*- coding: utf-8 -*-
"""验证标点乱字修复（每场景独立 session 避免污染；数字键上屏复现根因）。"""
import ctypes, os, shutil, tempfile
from ctypes import c_int, c_char_p, c_size_t, c_void_p, POINTER, Structure, byref

WEASEL_DIR = r'D:\Program Files\Rime\weasel-0.17.4'
SHARED_DATA = os.path.join(WEASEL_DIR, 'data')
TOUCHWB_SRC = r'D:\Program Files\Rime\TouchWB'
RIME_DLL = os.path.join(WEASEL_DIR, 'rime.dll')
DEV_DEFAULT = r'D:\AutophotiaIME\dev\space\schemas\TouchWB\default.yaml'
DEV_SUBMIT = r'D:\AutophotiaIME\dev\space\schemas\TouchWB\lua\Submit_text.lua'
DEV_PAIR = r'D:\AutophotiaIME\dev\space\schemas\TouchWB\lua\pair_punct.lua'

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


def run(tag, patch):
    tmp = tempfile.mkdtemp(prefix='pf3_' + tag + '_')
    d = os.path.join(tmp, 'user')
    shutil.copytree(TOUCHWB_SRC, d, ignore=lambda *a: [n for n in a[1] if n.endswith('.userdb')])
    if patch:
        shutil.copyfile(DEV_DEFAULT, os.path.join(d, 'default.yaml'))
        shutil.copyfile(DEV_SUBMIT, os.path.join(d, 'lua', 'Submit_text.lua'))
        shutil.copyfile(DEV_PAIR, os.path.join(d, 'lua', 'pair_punct.lua'))

    lib = ctypes.WinDLL(RIME_DLL)
    L = lib
    L.RimeSetup.argtypes = [POINTER(RimeTraits)]; L.RimeInitialize.argtypes = [POINTER(RimeTraits)]
    L.RimeCreateSession.restype = c_size_t; L.RimeDestroySession.argtypes = [c_size_t]
    L.RimeSelectSchema.argtypes = [c_size_t, c_char_p]
    L.RimeSimulateKeySequence.argtypes = [c_size_t, c_char_p]
    L.RimeGetContext.argtypes = [c_size_t, POINTER(RimeContext)]; L.RimeGetContext.restype = c_int
    L.RimeFreeContext.argtypes = [POINTER(RimeContext)]
    L.RimeGetCommit.argtypes = [c_size_t, POINTER(RimeCommit)]; L.RimeFreeCommit.argtypes = [POINTER(RimeCommit)]

    t = RimeTraits(); t.data_size = ctypes.sizeof(RimeTraits)
    t.shared_data_dir = SHARED_DATA.encode(); t.user_data_dir = d.encode()
    t.distribution_name = b'Rime'; t.distribution_code_name = b'sb'
    t.distribution_version = b'0'; t.app_name = ('g' + tag).encode()
    L.RimeSetup(byref(t)); L.RimeInitialize(byref(t))

    def new_session():
        return L.RimeCreateSession()

    def commit(sid):
        cmt = RimeCommit(); cmt.data_size = ctypes.sizeof(RimeCommit); out = ''
        if L.RimeGetCommit(sid, byref(cmt)) and cmt.text:
            out = cmt.text.decode('utf-8', 'replace')
        L.RimeFreeCommit(byref(cmt)); return out

    def press(sid, seq):
        L.RimeSimulateKeySequence(sid, seq.encode()); return commit(sid)

    print(f"\n{'='*64}\n[{tag}] 补丁={'是' if patch else '否'}")

    # 场景A：打 imya → 数字2上屏「测度」→ 分号（根因：predictor 预测 + last_2th 缓存）
    s = new_session(); L.RimeSelectSchema(s, b'ly_wubi_pinyin')
    press(s, 'imya'); press(s, '2')
    r = press(s, '{semicolon}')
    print(f"  [A] 数字2上屏测度后按分号 = {r!r}   (A_orig 期望 '测度'，B_fixed 期望 '；')")
    L.RimeDestroySession(s)

    # 场景B：打码中 imya → 分号（功能保留：应选第2候选「测度」）
    s = new_session(); L.RimeSelectSchema(s, b'ly_wubi_pinyin')
    press(s, 'imya')
    r = press(s, '{semicolon}')
    print(f"  [B] 打码中按分号 = {r!r}   (期望 '测度')")
    L.RimeDestroySession(s)

    # 场景C：打码中 imya → 单引号（功能保留：应选第3候选「小幅度」）
    s = new_session(); L.RimeSelectSchema(s, b'ly_wubi_pinyin')
    press(s, 'imya')
    r = press(s, '{apostrophe}')
    print(f"  [C] 打码中按单引号 = {r!r}   (期望 '小幅度')")
    L.RimeDestroySession(s)

    # 场景D：打 imya → 空格上屏「测试」→ 分号
    s = new_session(); L.RimeSelectSchema(s, b'ly_wubi_pinyin')
    press(s, 'imya'); press(s, '{space}')
    r = press(s, '{semicolon}')
    print(f"  [D] 空格上屏测试后按分号 = {r!r}   (期望 '；')")
    L.RimeDestroySession(s)

    # 场景E：空状态按双引号
    s = new_session(); L.RimeSelectSchema(s, b'ly_wubi_pinyin')
    r = press(s, '{quotedbl}')
    print(f"  [E] 空状态按双引号 = {r!r}   (期望 '“')")
    L.RimeDestroySession(s)

    L.RimeFinalize()


run('A_orig', patch=False)
run('B_fixed', patch=True)
