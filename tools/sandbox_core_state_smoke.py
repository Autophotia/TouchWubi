# -*- coding: utf-8 -*-
"""core.state 迁移冒烟回归：验证 smart_assoc / pair_punct 改从 _G 迁到 core.state 后不回归。

验证点：
  1. require "core" 能正确解析（core.lua / types.lua 随 dev 完整目录一起复制）。
  2. smart_assoc.lua（require core + mark_assoc_seg 写 core.state.assoc_seg）正常加载。
  3. pair_punct.lua（require core + 读 core.state.assoc_seg / punct_exempt / punct_dbg）正常加载。
  4. 打码出候选 + 上屏 + 按标点，整条链路无 Lua 加载/运行错误。
只读实验：复制 dev 方案目录到临时目录，不污染真机数据。
"""
import ctypes
from ctypes import (
    c_int, c_void_p, c_char_p, c_size_t,
    POINTER, Structure, byref,
)
import os, shutil, tempfile, glob, sys

WEASEL_DIR = r"D:\Program Files\Rime\weasel-0.17.4"
SHARED_DATA = os.path.join(WEASEL_DIR, "data")
TOUCHWB_REAL = r"D:\Program Files\Rime\TouchWB"          # 已部署目录（含 build/*.bin + predict.db）
TOUCHWB_DEV = r"D:\AutophotiaIME\dev\space\schemas\TouchWB"  # 源目录（含改动后的 lua）
RIME_DLL = os.path.join(WEASEL_DIR, "rime.dll")

# 命令行 --targeted：把 core.state.debug_tags 注入为 { assoc=true }，验证「针对性开关只开某模块」
TARGETED = "--targeted" in sys.argv


class RimeTraits(Structure):
    _fields_ = [
        ("data_size", c_int),
        ("shared_data_dir", c_char_p),
        ("user_data_dir", c_char_p),
        ("distribution_name", c_char_p),
        ("distribution_code_name", c_char_p),
        ("distribution_version", c_char_p),
        ("app_name", c_char_p),
        ("modules", POINTER(c_char_p)),
        ("min_log_level", c_int),
        ("log_dir", c_char_p),
        ("prebuilt_data_dir", c_char_p),
        ("staging_dir", c_char_p),
    ]


class RimeCandidate(Structure):
    _fields_ = [("text", c_char_p), ("comment", c_char_p), ("reserved", c_void_p)]


class RimeMenu(Structure):
    _fields_ = [
        ("page_size", c_int), ("page_no", c_int), ("is_last_page", c_int),
        ("highlighted_candidate_index", c_int), ("num_candidates", c_int),
        ("candidates", POINTER(RimeCandidate)), ("select_keys", c_char_p),
    ]


class RimeComposition(Structure):
    _fields_ = [
        ("length", c_int), ("cursor_pos", c_int), ("sel_start", c_int),
        ("sel_end", c_int), ("preedit", c_char_p),
    ]


class RimeContext(Structure):
    _fields_ = [
        ("data_size", c_int), ("composition", RimeComposition), ("menu", RimeMenu),
        ("commit_text_preview", c_char_p), ("select_labels", POINTER(c_char_p)),
    ]


class RimeCommit(Structure):
    _fields_ = [("data_size", c_int), ("text", c_char_p)]


def load_lib():
    os.add_dll_directory(WEASEL_DIR)
    lib = ctypes.WinDLL(RIME_DLL)
    lib.RimeSetup.argtypes = [POINTER(RimeTraits)]
    lib.RimeInitialize.argtypes = [POINTER(RimeTraits)]
    lib.RimeFinalize.argtypes = []
    lib.RimeCreateSession.restype = c_size_t
    lib.RimeCreateSession.argtypes = []
    lib.RimeDestroySession.argtypes = [c_size_t]
    lib.RimeDestroySession.restype = c_int
    lib.RimeSelectSchema.argtypes = [c_size_t, c_char_p]
    lib.RimeSelectSchema.restype = c_int
    lib.RimeSimulateKeySequence.argtypes = [c_size_t, c_char_p]
    lib.RimeSimulateKeySequence.restype = c_int
    lib.RimeGetContext.argtypes = [c_size_t, POINTER(RimeContext)]
    lib.RimeGetContext.restype = c_int
    lib.RimeFreeContext.argtypes = [POINTER(RimeContext)]
    lib.RimeGetCommit.argtypes = [c_size_t, POINTER(RimeCommit)]
    lib.RimeGetCommit.restype = c_int
    lib.RimeFreeCommit.argtypes = [POINTER(RimeCommit)]
    return lib


def make_traits(user_dir, log_dir):
    t = RimeTraits()
    t.data_size = ctypes.sizeof(RimeTraits)
    t.shared_data_dir = SHARED_DATA.encode()
    t.user_data_dir = user_dir.encode()
    t.distribution_name = b"Rime"
    t.distribution_code_name = b"core_state_smoke"
    t.distribution_version = b"0.0"
    t.app_name = b"sandbox_core_state"
    t.min_log_level = 0  # DEBUG，抓 Lua 加载错误
    t.log_dir = log_dir.encode()
    return t


def get_context(lib, sid):
    ctx = RimeContext()
    ctx.data_size = ctypes.sizeof(RimeContext)
    if not lib.RimeGetContext(sid, byref(ctx)):
        return None
    return ctx


def dump(ctx, label):
    if ctx is None:
        print(f"  [{label}] <no context>")
        return
    preedit = ctx.composition.preedit.decode() if ctx.composition.preedit else ""
    n = ctx.menu.num_candidates
    cands = [ctx.menu.candidates[i].text.decode() for i in range(n)]
    print(f"  [{label}] preedit={preedit!r}  candidates={cands}")


def press(lib, sid, seq):
    lib.RimeSimulateKeySequence(sid, seq.encode())
    out = ""
    cmt = RimeCommit()
    cmt.data_size = ctypes.sizeof(RimeCommit)
    if lib.RimeGetCommit(sid, byref(cmt)) and cmt.text:
        out = cmt.text.decode("utf-8", "replace")
    lib.RimeFreeCommit(byref(cmt))
    return out


def main():
    tmp = tempfile.mkdtemp(prefix="core_state_smoke_")
    user_dir = os.path.join(tmp, "user")
    log_dir = os.path.join(tmp, "log")
    os.makedirs(log_dir, exist_ok=True)
    print(f"[*] 复制真机已部署目录 -> {user_dir}")
    shutil.copytree(TOUCHWB_REAL, user_dir, ignore=shutil.ignore_patterns("*.userdb"))
    # 删掉真机残留的调试日志（用户上次 /dbg 测试留下），让本次从干净状态统计去重效果
    for leftover in ["touchwb_debug.log"]:
        p = os.path.join(user_dir, leftover)
        if os.path.exists(p):
            os.remove(p)
            print(f"    已删除残留 {leftover}")

    # 叠加本次改动/新增的 lua 文件（core/type 迁移 + 造词数据层拆分）
    overlay = {
        "lua/core.lua": "lua/core.lua",
        "lua/types.lua": "lua/types.lua",
        "lua/smart_assoc.lua": "lua/smart_assoc.lua",
        "lua/pair_punct.lua": "lua/pair_punct.lua",
        "lua/Submit_text.lua": "lua/Submit_text.lua",
        "lua/user_coined_db.lua": "lua/user_coined_db.lua",
        "lua/auto_coined.lua": "lua/auto_coined.lua",
        "lua/user_coined_cmd.lua": "lua/user_coined_cmd.lua",
        "lua/super_sequence.lua": "lua/super_sequence.lua",
        "lua/input_statistics.lua": "lua/input_statistics.lua",
        "lua/calc_symbol_processor.lua": "lua/calc_symbol_processor.lua",
    }
    print("[*] 叠加 dev 改动文件：")
    for rel, src_rel in overlay.items():
        src = os.path.join(TOUCHWB_DEV, src_rel)
        dst = os.path.join(user_dir, rel)
        if not os.path.exists(src):
            print(f"    MISS src {src}")
            continue
        shutil.copyfile(src, dst)
        print(f"    OK  {rel}")

    if TARGETED:
        # 针对性调试验证：只开 assoc tag，确认 core.dbg 只输出 [assoc]、不泄漏其它模块
        core_path = os.path.join(user_dir, "lua", "core.lua")
        with open(core_path, "r", encoding="utf-8") as f:
            s = f.read()
        s2 = s.replace("    debug_tags = {},", "    debug_tags = { assoc = true },")
        if s2 == s:
            print("  ✗ 未找到 '    debug_tags = {},' 占位，无法注入针对性开关")
        else:
            with open(core_path, "w", encoding="utf-8") as f:
                f.write(s2)
            print("[*] 已注入 debug_tags = { assoc = true }（针对性调试验证）")

    # 确认核心文件就位
    for rel in ["lua/core.lua", "lua/types.lua", "lua/smart_assoc.lua", "lua/pair_punct.lua",
                "build/ly_wubi_pinyin.prism.bin", "predict.db"]:
        p = os.path.join(user_dir, rel)
        print(f"    {'OK ' if os.path.exists(p) else 'MISS'} {rel}")

    lib = load_lib()
    traits = make_traits(user_dir, log_dir)
    lib.RimeSetup(byref(traits))
    lib.RimeInitialize(byref(traits))
    print("[*] RimeInitialize OK")

    sid = lib.RimeCreateSession()
    lib.RimeSelectSchema(sid, b"ly_wubi_pinyin")
    print("[*] schema = ly_wubi_pinyin")

    # 打码出候选（smart_assoc P 加载并跑 mark_assoc_seg）
    print("\n=== 打码 fcu（云）===")
    press(lib, sid, "fcu")
    dump(get_context(lib, sid), "fcu")
    c1 = press(lib, sid, " ")  # 上屏
    print(f"  [commit] {c1!r}")

    # 按标点（pair_punct 读 core.state.*）
    print("\n=== 按分号 / 引号 ===")
    for seq in [";", "{quotedbl}", "{apostrophe}"]:
        c = press(lib, sid, seq)
        print(f"  [{seq}] commit={c!r}")

    # ★ 2026-11-04：= 键符号菜单循环（空状态按 = 应弹「＝ 々 〃」，再按 = 循环而非累积 ==）
    print("\n=== = 键符号菜单循环 ===")
    press(lib, sid, "{Escape}")
    press(lib, sid, "{equal}")
    dump(get_context(lib, sid), "= 第1次(应弹符号菜单)")
    press(lib, sid, "{equal}")
    dump(get_context(lib, sid), "= 第2次(应循环,而非 '==' )")
    press(lib, sid, "{equal}")
    dump(get_context(lib, sid), "= 第3次(继续循环)")
    press(lib, sid, "{Escape}")

    # ★ 计算器仍可用：= 后跟数字启动算式
    print("\n=== 计算器 = 1+1 ===")
    press(lib, sid, "{equal}1+1")
    dump(get_context(lib, sid), "= 1+1")
    press(lib, sid, " ")
    press(lib, sid, "{Escape}")

    # 注：Ctrl+L 调序重置依赖 PC function mode（沙盒 distribution_code_name 非小狼毫、
    #   function mode 未激活 ⇒ Ctrl 组合键被放行进 input，无法在此模拟）。该修复
    #   （process_adjustment 遍历 get_adjustment 全量删除）靠代码 review + 真机验证。

    # 再打一组，确认多次按键后状态表读写无异常
    print("\n=== 打码 whnt（个性）===")
    press(lib, sid, "whnt")
    dump(get_context(lib, sid), "whnt")
    c2 = press(lib, sid, " ")
    print(f"  [commit] {c2!r}")

    # 造词链路：/zctj 命令触发 user_coined_cmd translator + db.uc_list_manual（读 UserDb）
    print("\n=== 造词命令 /zctj（触发 user_coined_cmd + user_coined_db）===")
    press(lib, sid, "/zctj")
    dump(get_context(lib, sid), "/zctj")
    press(lib, sid, " ")

    # 自造词 translator 链路：打一个 ≥2 字母码触发 user_coined_translator（db.uc_open/uc_query）
    print("\n=== 打码 xy（触发 user_coined_translator）===")
    press(lib, sid, "xy")
    dump(get_context(lib, sid), "xy")
    press(lib, sid, " ")

    # 输入统计链路：/tj 触发 input_statistics（顶层 MOBILE_MODE = core.is_mobile()）
    print("\n=== 统计命令 /tj（触发 input_statistics）===")
    press(lib, sid, "/tj")
    dump(get_context(lib, sid), "/tj")
    press(lib, sid, " ")

    # 2026-11-04：/dbg 命令已移除（改为 core.state.debug_tags 按 tag 精准开关）。
    # 这里确认输 /dbg 不再报错、也不再弹 🐞 消息（命令已摘除，静默放行/按普通输入处理）。
    print("\n=== /dbg 已移除：输入 /dbg 不应触发调试开关 ===")
    press(lib, sid, "/dbg")
    dump(get_context(lib, sid), "/dbg (应无 🐞 消息)")
    press(lib, sid, "{Escape}")

    lib.RimeDestroySession(sid)
    lib.RimeFinalize()

    # 检查统一调试日志文件（core.dbg 通道②：用户目录 touchwb_debug.log）
    print("\n=== touchwb_debug.log 检查 ===")
    dbg_log = os.path.join(user_dir, "touchwb_debug.log")
    if TARGETED:
        # 针对性模式：应生成日志，且只含 [assoc]、无 [auto_coined]/[Submit_text]/[COIN:
        if not os.path.exists(dbg_log):
            print("  ⚠ 针对性开启 assoc 后仍未生成日志（门控失效）")
        else:
            with open(dbg_log, "r", encoding="utf-8", errors="replace") as f:
                lines = [ln for ln in f.read().splitlines() if ln.strip()]
            bad = [ln for ln in lines
                   if "[auto_coined]" in ln or "[Submit_text]" in ln or "[COIN:" in ln]
            print(f"  已生成 {len(lines)} 行；非 assoc 行数 = {len(bad)}（应 0）")
            if bad:
                for ln in bad[:5]:
                    print(f"     ⚠ {ln[:140]}")
            else:
                print("  ✅ 针对性开关生效：只输出 [assoc]，未泄漏其它模块")
    else:
        # 默认模式：debug 全关，正常打字不应产生调试日志
        if os.path.exists(dbg_log):
            print("  ⚠ 默认全关却生成了调试日志（core.dbg 门控失效）")
        else:
            print("  ✅ 默认全关，未生成调试日志（core.dbg 门控正常）")

    # 检查日志里的 Lua 错误
    print("\n=== 日志检查 ===")
    logs = glob.glob(os.path.join(log_dir, "*"))
    err_hits = []
    for lp in logs:
        try:
            with open(lp, "r", encoding="utf-8", errors="replace") as f:
                for line in f:
                    low = line.lower()
                    if "error" in low or "lua" in low and ("fail" in low or "not found" in low or "require" in low):
                        err_hits.append((os.path.basename(lp), line.strip()))
        except Exception as e:
            print(f"  [read log failed] {e}")
    if err_hits:
        print(f"  ⚠ 发现 {len(err_hits)} 条可疑日志：")
        for name, line in err_hits[:20]:
            print(f"     [{name}] {line[:160]}")
    else:
        print("  未发现 Lua error / require 失败日志")

    print("\n[*] done. user_dir =", user_dir)
    print("[*] log_dir =", log_dir)


if __name__ == "__main__":
    main()
