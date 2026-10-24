#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
assoc_fixed.txt 古诗文/生僻字联想补充脚本（方案一，纯 Python 无风险）

从古诗文语料（chinese-poetry 格式）自动提取「高频字级接续（bigram）」，
生成 assoc_fixed.txt 的补充条目，让联想能补全「不会拆的生僻字」
（如「南湖采白 → 蘋」「人心不可谓 → 兮」）。

用法:
    # 只生成补充文件（无风险，不改任何现有文件）
    python assoc_supplement.py --corpus <语料目录> \
        --fixed ../space/schemas/TouchWB/lua/assoc_fixed.txt \
        --common ../space/schemas/TouchWB/lua/assoc_common.txt \
        --out assoc_fixed_supplement.txt

    # 生成合并后的完整文件（写到新文件，绝不覆盖现有 assoc_fixed.txt）
    python assoc_supplement.py ... --merge --out assoc_fixed.merged.txt

流程:
    语料 → 逐句扫描 → 字级 bigram 频次统计 → 频次过滤 + 生僻字优先 + 去重 → 补充条目

无风险:
    - 只读现有 assoc_fixed.txt / assoc_common.txt
    - 默认只写新文件，绝不原地改任何现有 lua/schema/词典

设计依据（dev/联想增强与predict.db精简方案.md）:
    - bigram 粒度：单字 → 单字
    - 频次阈值：≥3（默认，可调）
    - 后续字筛选：排除常用字（assoc_common.txt 白名单内），重点收生僻字
    - 首字限常用字（白名单内），避免生僻首字撑爆条目
    - FIXED_MAX = 6（smart_assoc.lua 的 fixed_candidates 按文件顺序取前 6 个）
"""

import argparse
import json
import os
import re
from collections import Counter, defaultdict

import zhconv  # 繁转简（chinese-poetry 核心语料为繁体）

CJK = re.compile(r'[\u4e00-\u9fff]')
SENT_SPLIT = re.compile('[，。！？；：、,.!?;:""\'\'（）()《》〈〉\\[\\]【】\\s…—··]+')

# 语料目录里需要跳过的子目录（避免重复计数/解析噪声）：
#   strains      = 平仄格律标记（不是诗句文字）
#   御定全唐詩    = 全唐诗的繁体重复副本（繁转简后会与全唐诗重复计数）
#   rank/images/loader = 非诗句数据
SKIP_DIRS = {'strains', '御定全唐詩', 'rank', 'images', 'loader', '.git'}

# 古诗文高频虚词/助词：即使落在 assoc_common.txt（8000 常用字）内，也当作
# 「古诗文特有用字」放行（否则「谓→兮」这类接续会被「生僻优先」误排除）。
LITERARY_PARTICLES = set('兮乎焉哉矣欤耶邪耳夫盖曷盍汝吾尔余予之者也')


def load_common(path):
    """常用字白名单（assoc_common.txt 为单行连排）"""
    with open(path, encoding='utf-8') as f:
        return set(f.read().strip())


def load_fixed(path):
    """现有 assoc_fixed.txt：首字<TAB>后续词1 后续词2 ... -> {首字: [后续词, ...]}（保序）"""
    fixed = {}
    with open(path, encoding='utf-8') as f:
        for line in f:
            line = line.rstrip('\n').rstrip('\r')
            if not line or line.startswith('#'):
                continue
            k, _, v = line.partition('\t')
            if not k:
                continue
            fixed[k] = [w for w in v.split() if w]
    return fixed


def iter_sentences(corpus_dir):
    """遍历语料 JSON，产出句子（汉字列表）"""
    for root, dirs, files in os.walk(corpus_dir):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for fn in files:
            if not fn.endswith('.json'):
                continue
            fp = os.path.join(root, fn)
            try:
                with open(fp, encoding='utf-8') as f:
                    data = json.load(f)
            except Exception:
                continue
            for s in _walk(data):
                yield s


def _walk(node):
    """递归提取诗句字符串（paragraphs/content/para 为诗句字段，避开 strains=平仄标记、title/author 等元数据）"""
    if isinstance(node, dict):
        for key in ('paragraphs', 'content', 'para'):
            if key in node:
                for item in _as_list(node[key]):
                    yield from _sentences(item)
    elif isinstance(node, list):
        for item in node:
            yield from _walk(item)


def _as_list(v):
    return v if isinstance(v, list) else [v]


def _sentences(text):
    """切句 + 繁转简 + 只留汉字"""
    if not isinstance(text, str):
        return
    text = zhconv.convert(text, 'zh-cn')  # 繁转简（繁体语料 → 简体，与词库一致）
    for s in SENT_SPLIT.split(text):
        chars = CJK.findall(s)
        if len(chars) >= 2:
            yield chars


def count_bigrams(corpus_dir):
    cnt = Counter()
    n_sentence = 0
    for chars in iter_sentences(corpus_dir):
        n_sentence += 1
        for i in range(len(chars) - 1):
            cnt[(chars[i], chars[i + 1])] += 1
    return cnt, n_sentence


def main():
    ap = argparse.ArgumentParser(description='assoc_fixed.txt 古诗文生僻字联想补充脚本')
    ap.add_argument('--corpus', required=True, help='chinese-poetry 语料目录')
    ap.add_argument('--fixed', required=True, help='现有 assoc_fixed.txt')
    ap.add_argument('--common', required=True, help='常用字白名单 assoc_common.txt')
    ap.add_argument('--min-count', type=int, default=3, help='bigram 频次阈值（默认 3）')
    ap.add_argument('--max-per-key', type=int, default=6, help='每首字最多补几条（对齐 smart_assoc FIXED_MAX=6）')
    ap.add_argument('--out', default='assoc_fixed_supplement.txt', help='输出文件')
    ap.add_argument('--merge', action='store_true', help='输出合并后的完整 assoc_fixed（默认只输出新增补充）')
    args = ap.parse_args()

    common = load_common(args.common)
    fixed = load_fixed(args.fixed)
    print('[1/3] 常用字 %d，现有首字 %d' % (len(common), len(fixed)))

    bigrams, n_sentence = count_bigrams(args.corpus)
    print('[2/3] 扫描句子 %d，去重 bigram %d' % (n_sentence, len(bigrams)))

    # 过滤 + 去重
    supp = defaultdict(set)   # 首字 -> set(后续生僻字)
    for (a, b), c in bigrams.items():
        if c < args.min_count:
            continue
        if a not in common:          # 首字限常用字
            continue
        if b in common and b not in LITERARY_PARTICLES:
            continue                 # 后续字排除常用字（重点收生僻字；虚词放行）
        if b in set(fixed.get(a, [])):   # 与现有条目去重
            continue
        supp[a].add(b)

    # 每首字按频次降序，最多 max_per_key 条
    supp_sorted = {}
    for a in sorted(supp):
        bs = sorted(supp[a], key=lambda b: -bigrams[(a, b)])[:args.max_per_key]
        if bs:
            supp_sorted[a] = bs

    n_added = sum(len(v) for v in supp_sorted.values())
    print('[3/3] 生成 %d 个首字的补充，共 %d 条新接续' % (len(supp_sorted), n_added))

    if args.merge:
        # 合并：后续词 < FIXED_MAX 的首字 → 追加到末尾（不挤占）
        #       后续词 >= FIXED_MAX 的首字 → 插到第 FIXED_MAX 位（挤掉最低频的 1 个）
        out_lines = []
        for a in sorted(set(fixed) | set(supp_sorted)):
            cur = fixed.get(a, [])
            extra = supp_sorted.get(a, [])
            if not cur:
                merged = extra
            elif not extra:
                merged = cur
            elif len(cur) < args.max_per_key:
                merged = cur + extra
            else:
                pos = args.max_per_key - 1
                merged = cur[:pos] + extra + cur[pos:]
            out_lines.append('%s\t%s' % (a, ' '.join(merged)))
        with open(args.out, 'w', encoding='utf-8') as f:
            f.write('\n'.join(out_lines) + '\n')
        print('合并后写入 %s（%d 行）' % (args.out, len(out_lines)))
    else:
        with open(args.out, 'w', encoding='utf-8') as f:
            for a in sorted(supp_sorted):
                f.write('%s\t%s\n' % (a, ' '.join(supp_sorted[a])))
        print('补充条目写入 %s' % args.out)


if __name__ == '__main__':
    main()
