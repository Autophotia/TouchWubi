#!/usr/bin/env bash
# TouchWB 发布打包脚本（规则基线：releases/TouchWB_S117_2026-10-16.zip，2026-10-21 定制）
# 用法：bash dev/tools/pack-release.sh
# 输出：releases/TouchWB_S<序号>_<日期>.zip（序号取已有最大 S 编号 +1，如 S117 → S118）
#
# 打包规则（对照参考包逐条固化，共 62 个文件）：
#   结构：zip 内含 TouchWB/ 根目录
#   包含：README/default/info/weasel/symbols、
#         icons/、opencc/、lua/（22个，含 2026-10-29 新增 auto_coined.lua）、6+1 schema、4 套词库、
#         themes/14key_wubi、themes/26key_wubi、predict.db
#   排除：user.yaml、installation.yaml（本机安装配置）
#         custom_phrase.txt 及 .db*（自造词动态库）、user_coined_ext.txt / user_coined_auto.txt（运行时自动生成）、
#         *.userdb/、log/
#         lua/input_stats_*.lua 及 .bak（未挂载死代码）、*.bak
#         lua/sequence_*.txt（调序运行时数据，存于用户数据目录）
#         themes/public/**（空间级公共主题资源，随 app 提供）
#         build/**（编译产物，仅生成裁剪版 build/default.yaml）
#   生成：build/default.yaml 仅含 schema_list 四项（ly_wubi_pinyin / ly_wubi_pinyin_14 / ly_wubi / ly_wubi_14）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$ROOT/dev/space/schemas/TouchWB"
OUT="$ROOT/releases"

[ -d "$SRC" ] || { echo "错误：找不到方案目录 $SRC"; exit 1; }
mkdir -p "$OUT"

# 序号 = releases 中已有 TouchWB_S*.zip 的最大 S 编号 + 1（README 2026-10-08 定名规则）
max=0
for f in "$OUT"/TouchWB_S*_*.zip; do
  [ -e "$f" ] || continue
  b="$(basename "$f")"
  n="${b#TouchWB_S}"; n="${n%%_*}"
  [[ "$n" =~ ^[0-9]+$ ]] || continue
  n=$((10#$n))
  [ "$n" -gt "$max" ] && max=$n
done
next="$(printf "S%03d" $((max + 1)))"
stamp="$(date +%Y-%m-%d)"
target="$OUT/TouchWB_${next}_${stamp}.zip"

# 探测可用的 Python
PY="$(command -v python3 || command -v python || command -v py || true)"
[ -n "$PY" ] || { echo "错误：需要 python3/python/py 之一"; exit 1; }

echo "源目录：$SRC"
echo "输出到：$target"

"$PY" - "$SRC" "$target" <<'PYEOF'
import os, sys, zipfile, fnmatch

src, target = sys.argv[1], sys.argv[2]

# ---- 排除规则（文件/目录，相对方案根目录）----
EXCLUDE_FILES = {
    '.gitignore', 'user.yaml', 'installation.yaml',
    'custom_phrase.txt', 'custom_phrase.db', 'custom_phrase.db-shm', 'custom_phrase.db-wal',
    'user_coined_ext.txt', 'user_coined_auto.txt',
}
EXCLUDE_DIRS = {'.git', 'log', 'tmp'}
EXCLUDE_GLOBS = ('*.bak', '*.tmp', '*.db-shm', '*.db-wal', '.DS_Store', 'Thumbs.db', 'desktop.ini')
EXCLUDE_PREFIX_DIRS = ('themes/public',)           # 整棵子树排除
EXCLUDE_LUA_PREFIX = ('input_stats_', 'sequence_')  # lua/ 下按文件名前缀排除

# ---- build/default.yaml 裁剪内容（参考包口径，113 字节）----
BUILD_DEFAULT = (
    "schema_list:\n"
    "  - schema: ly_wubi_pinyin\n"
    "  - schema: ly_wubi_pinyin_14\n"
    "  - schema: ly_wubi\n"
    "  - schema: ly_wubi_14\n"
)

def excluded(rel):
    parts = rel.split('/')
    base = parts[-1]
    if base in EXCLUDE_FILES:
        return True
    if any(d in EXCLUDE_DIRS or d.endswith('.userdb') for d in parts[:-1]):
        return True
    if 'build' in parts[:-1]:
        return True
    if any(rel == d or rel.startswith(d + '/') for d in EXCLUDE_PREFIX_DIRS):
        return True
    if any(fnmatch.fnmatch(base, g) for g in EXCLUDE_GLOBS):
        return True
    if len(parts) == 2 and parts[0] == 'lua' and any(base.startswith(p) for p in EXCLUDE_LUA_PREFIX):
        return True
    return False

count, total = 0, 0
with zipfile.ZipFile(target, 'w', zipfile.ZIP_DEFLATED) as z:
    for root, dirs, files in os.walk(src):
        rel_root = os.path.relpath(root, src).replace('\\', '/')
        dirs[:] = sorted(d for d in dirs if d not in EXCLUDE_DIRS and not d.endswith('.userdb'))
        for fn in sorted(files):
            rel = fn if rel_root == '.' else rel_root + '/' + fn
            if excluded(rel):
                continue
            fp = os.path.join(root, fn)
            z.write(fp, 'TouchWB/' + rel)
            count += 1
            total += os.path.getsize(fp)
    # 生成裁剪版 build/default.yaml
    z.writestr('TouchWB/build/default.yaml', BUILD_DEFAULT)
    count += 1
    total += len(BUILD_DEFAULT.encode('utf-8'))

print('打包完成：%d 个文件（含生成的 build/default.yaml），压缩前 %.1f MB' % (count, total / 1048576))
if count != 62:
    print('⚠️ 文件数与参考包基线（62）不一致，请核对排除规则或新增资产')
PYEOF

size="$(du -h "$target" | cut -f1)"
echo "已生成：$target（$size）"
echo "提示：上传 git 请在方案目录执行  git save \"<提交说明>\""
