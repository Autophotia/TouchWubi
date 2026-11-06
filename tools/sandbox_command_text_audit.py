# -*- coding: utf-8 -*-
"""全命令候选「上屏文本」审计：多行 → 末尾应有 1 个空行；单行 → 不应有。

用真实 rime.dll 逐个命令打码并按空格上屏首候选，输出：
  候选栏文本是否含换行 / 上屏文本行数 / 末尾换行情况。
只读：复制真机目录到临时目录，叠加 dev lua 文件，不改动真机。
"""
import ctypes
import os
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sandbox_help_short_probe as hsp

DEV = hsp.TOUCHWB_DEV

# 先跑只读/展示类，破坏性命令（清空类）放最后，避免影响前面命令的数据
CMDS = [
    "/h", "/tj", "/js", "/tc", "/ks",
    "/rq", "/sj", "/xq", "/dt", "/jt", "/jq", "/gz", "/nl",
    "/zctj", "/zccx", "/zcsc1", "/zcdr",
    "/lxzt", "/lxdj", "/lxdc", "/lxdr",
    "/txzj", "/txdc", "/txdr", "/txtj",
    "/tg", "/dz", "/xh", "/bd", "/1", "/2", "/10",
    "/zcqk", "/zcql", "/qk", "/lxqk", "/lxql", "/txqk", "/txzq",
]


def main():
    tmp = tempfile.mkdtemp(prefix="cmd_text_audit_")
    user_dir = os.path.join(tmp, "user")
    log_dir = os.path.join(tmp, "log")
    os.makedirs(log_dir, exist_ok=True)
    shutil.copytree(hsp.TOUCHWB_REAL, user_dir,
                    ignore=shutil.ignore_patterns("*.userdb"))
    for rel in ("lua/help_cmd.lua", "lua/Submit_text.lua", "lua/core.lua",
                "lua/input_statistics.lua", "lua/schedule.lua",
                "lua/super_sequence.lua"):
        shutil.copyfile(os.path.join(DEV, rel), os.path.join(user_dir, rel))

    lib = hsp.load_lib()
    t = hsp.make_traits(user_dir, log_dir)
    lib.RimeSetup(ctypes.byref(t))
    lib.RimeInitialize(ctypes.byref(t))
    sid = lib.RimeCreateSession()
    lib.RimeSelectSchema(sid, b"ly_wubi")

    print(f"{'cmd':10s} {'cand_nl':8s} {'cand_first':34s} "
          f"{'len':>6s} {'lines':>5s} {'tail':>6s}  commit_head")
    print("-" * 118)
    rows = []
    for cmd in CMDS:
        hsp.press(lib, sid, "{Escape}")
        hsp.get_commit(lib, sid)
        hsp.press(lib, sid, cmd)
        cands = hsp.all_cands(hsp.get_context(lib, sid))
        head = cands[0][0] if cands else ""
        hsp.press(lib, sid, "{space}")
        commit = hsp.get_commit(lib, sid)
        lines = commit.count("\n") + 1 if commit else 0
        tail = ("-" if not commit else
                "1NL" if commit.endswith("\n") and not commit.endswith("\n\n") else
                "2NL+" if commit.endswith("\n\n") else "none")
        rows.append((cmd, head, commit))
        print(f"{cmd:10s} {str(chr(10) in head):8s} {head[:32]!r:34s} "
              f"{len(commit):6d} {lines:5d} {tail:>6s}  {commit[:36]!r}")

    # /h 分组行（第 2 候选）单独测：数字键 2 上屏
    print("\n--- /h 分组行（数字键 2 = 第 2 候选）---")
    hsp.press(lib, sid, "{Escape}")
    hsp.get_commit(lib, sid)
    hsp.press(lib, sid, "/h")
    hsp.press(lib, sid, "2")
    g = hsp.get_commit(lib, sid)
    print(f"len={len(g)} lines={g.count(chr(10)) + 1} tail={g[-6:]!r} head={g[:30]!r}")

    # 点候选路径（RimeSelectCandidate 第 1 候选）
    print("\n--- /h 首候选点候选路径 ---")
    hsp.press(lib, sid, "{Escape}")
    hsp.get_commit(lib, sid)
    hsp.press(lib, sid, "/h")
    lib.RimeSelectCandidate(sid, 0)
    c = hsp.get_commit(lib, sid)
    print(f"len={len(c)} lines={c.count(chr(10)) + 1} tail={c[-6:]!r} head={c[:30]!r}")

    print("\n--- 多行但不带尾部换行的命令（需修）---")
    bad = [(cmd, commit) for cmd, _, commit in rows
           if commit and "\n" in commit and not commit.endswith("\n")]
    for cmd, commit in bad:
        print(f"  {cmd:10s} len={len(commit)} tail={commit[-24:]!r}")
    if not bad:
        print("  （无）")

    print("\n--- 单行却带尾部换行的命令（需确认是否该去掉）---")
    weird = [(cmd, commit) for cmd, _, commit in rows
             if commit and "\n" not in commit.rstrip("\n") and commit.endswith("\n")]
    for cmd, commit in weird:
        print(f"  {cmd:10s} {commit[:40]!r}")
    if not weird:
        print("  （无）")

    try:
        hsp.press(lib, sid, "{Escape}")
        hsp.get_commit(lib, sid)
        lib.RimeDestroySession(sid)
        lib.RimeFinalize()
        print("\nCLEAN")
    except OSError as e:
        print("\n[清理阶段忽略]", e)


if __name__ == "__main__":
    main()
