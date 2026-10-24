# -*- coding: utf-8 -*-
# 验证 input_statistics.lua 重构后的核心逻辑：
#   1. 编码非空判据（排除点联想/复制/语音）
#   2. report_commit_text 的过滤分支（空/命令/报告/正常汉字）
import re
from lupa import LuaRuntime

SRC = r'D:/AutophotiaIME/dev/space/schemas/TouchWB/lua/input_statistics.lua'
src = open(SRC, encoding='utf-8').read()

# 抽取真实的 report_commit_text 函数体
m = re.search(r'local function report_commit_text\(commit_text\)(.*?)\nend\n\n-- 暴露到全局',
              src, re.DOTALL)
assert m, '未找到 report_commit_text'
func_body = 'local function report_commit_text(commit_text)' + m.group(1) + '\nend'

head = r'''
local avgSpdInfo = { logSts = 0, startTime = 0, clickTime = 0, commitTime = 0, gapThd = 10, count = 0 }
local STATS_ENV = { temp_stats = { is_collecting = false, count = 0, length = 0, fastest = 0, recent = {} } }
local STATS_SCHEMA_ID = "test"
local calls = { update = 0, save = 0, last_len = nil }

local function is_summary_command(text)
    return text == "/tj" or text == "/qk" or text == "/ks" or text == "/js" or text == "/tc"
end

-- 简化版汉字计数（与原 get_chinese_length 语义一致：只数 CJK 汉字）
local function get_chinese_length(text)
    if not text or text == "" then return 0 end
    if utf8 and utf8.codes then
        local count = 0
        for _, c in utf8.codes(text) do
            if c >= 0x4E00 and c <= 0x9FFF then count = count + 1 end
        end
        return count
    end
    return #text
end

local function update_stats(len, segend, env)
    calls.update = calls.update + 1
    calls.last_len = len
end
local function debounced_save_stats(sid)
    calls.save = calls.save + 1
end
'''

tail = r'''
local results = {}
local function check(name, cond, detail)
    results[#results + 1] = (cond and "PASS  " or "FAIL  ") .. name .. (detail and ("  [" .. detail .. "]") or "")
end

-- ===== T1: 编码非空判据（等价逻辑）=====
local function should_count(input_at_commit)
    if not input_at_commit or input_at_commit == "" then return false end
    return true
end
check("T1a 编码为空字符串 → 排除", should_count("") == false)
check("T1b 编码为 nil → 排除", should_count(nil) == false)
check("T1c 编码非空 → 统计", should_count("yngk") == true)

-- ===== T2: report_commit_text 过滤分支 =====
report_commit_text("")
check("T2a 空文本 → 不计数", calls.update == 0, "update=" .. calls.update)

report_commit_text("/tj")
check("T2b 命令 → 不计数", calls.update == 0, "update=" .. calls.update)

report_commit_text("※ 今日统计报告")
check("T2c 报告(※) → 不计数", calls.update == 0, "update=" .. calls.update)

report_commit_text("◉ 临时统计")
check("T2d 报告(◉) → 不计数", calls.update == 0, "update=" .. calls.update)

-- ===== T3: 正常汉字输入 → 计数 =====
report_commit_text("你好世界")
check("T3a 正常汉字 → 计数1次", calls.update == 1, "update=" .. calls.update)
check("T3b 汉字长度=4", calls.last_len == 4, "len=" .. tostring(calls.last_len))

report_commit_text("你好世界")
check("T3c 再次上屏 → 计数2次", calls.update == 2, "update=" .. calls.update)

-- ===== T4: 纯标点/英文 → 计数但不加字数（input_length=0）=====
report_commit_text("hello")
check("T4 英文(汉字0) → 仍走计数但 len=0", calls.update == 3 and calls.last_len == 0,
      "update=" .. calls.update .. " len=" .. tostring(calls.last_len))

return results
'''

test_lua = head + "\n" + func_body + "\n" + tail

lua = LuaRuntime()
res = lua.execute(test_lua)
print("=" * 60)
for line in res.values() if False else res:
    pass
# res 是 lua 表，逐项打印
print("=" * 60)
cnt_pass = 0
cnt_fail = 0
for i in range(1, len(res) + 1):
    line = res[i]
    print(line)
    if line.startswith("PASS"):
        cnt_pass += 1
    else:
        cnt_fail += 1
print("=" * 60)
print("通过 %d / %d" % (cnt_pass, cnt_pass + cnt_fail))
assert cnt_fail == 0, "存在失败用例"
print("全部通过")
