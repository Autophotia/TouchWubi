# -*- coding: utf-8 -*-
"""复现根因：同一 session 喂 predictor 历史 → 上屏「测度」→ 按分号，对比修复前后。"""
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
    tmp = tempfile.mkdtemp(prefix='rc_' + tag + '_')
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
    t.distribution_version = b'0'; t.app_name = ('rc' + tag).encode()
    L.RimeSetup(byref(t)); L.RimeInitialize(byref(t))
    sid = L.RimeCreateSession(); L.RimeSelectSchema(sid, b'ly_wubi_pinyin')

    def commit():
        cmt = RimeCommit(); cmt.data_size = ctypes.sizeof(RimeCommit); out = ''
        if L.RimeGetCommit(sid, byref(cmt)) and cmt.text:
            out = cmt.text.decode('utf-8', 'replace')
        L.RimeFreeCommit(byref(cmt)); return out

    def menu():
        ctx = RimeContext(); ctx.data_size = ctypes.sizeof(RimeContext); mts = []
        if L.RimeGetContext(sid, byref(ctx)):
            n = ctx.menu.num_candidates
            if n > 0 and ctx.menu.candidates:
                for i in range(min(n, 6)):
                    c = ctx.menu.candidates[i]
                    mts.append(c.text.decode('utf-8', 'replace') if c.text else '?')
        L.RimeFreeContext(byref(ctx)); return mts

    def press(seq):
        L.RimeSimulateKeySequence(sid, seq.encode()); return commit()

    print(f"\n[{tag}] 补丁={'是' if patch else '否'}")
    # 喂历史：连续上屏「测试」「测度」，让 predictor 学会预测
    press('imya'); press('{space}')       # 上屏「测试」
    press('imya'); press('2')             # 上屏「测度」（数字2选第2候选）
    press('imya'); press('2')             # 再来一次，强化
    # 关键：再打 imya，数字2上屏「测度」，然后看 menu（predictor 预测）
    press('imya'); press('2')
    print(f"  上屏测度后 menu = {menu()}")
    r = press('{semicolon}')
    print(f"  按分号 = {r!r}   (A_orig 期望含'测度'，B_fixed 期望'；')")
    r = press('{quotedbl}')
    print(f"  按双引号 = {r!r}   (期望'“'，不是乱字)")

    L.RimeDestroySession(sid); L.RimeFinalize()


run('A_orig', patch=False)
run('B_fixed', patch=True)
