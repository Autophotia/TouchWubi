-- ============================================================
-- 【来源与署名】★ 2026-09-30 补署
--   创意来源：万象拼音（万象家族 lua）
--     上游：https://github.com/amzxyz/rime_wanxiang
--   修改：Autophotia（超越输入法 · TouchWB 双键五笔方案）
--         https://github.com/Autophotia/TouchWubi
--
--   溯源：早期雏形取自万象的统计脚本，历经长期反复修改，
--         现今代码结构与上游已有较大差异，维护由本方案负责。
--
--   ★ 创意归万象及上游作者；本方案内的改动由 Autophotia 负责。
--     使用中若发现与上游不同的行为，请联系修改者，
--     不要 upstream 反馈给万象项目。
-- ============================================================
-- 输入统计工具
-- 作者：Autophotia
-- 日期：2025-10-25
-- 
-- 命令列表：
--   显示统计：    /tj     - 候选栏显示「今日/本周/本月/本年统计」4 条短标题，
--                          点选 / 空格上屏对应的完整统计报告
--   清空统计：    /qk     - 清空所有统计数据（保留昨日数据）
--   开始临时统计：/ks     - 开始临时统计会话
--   结束临时统计：/js     - 结束临时统计并生成报告
--   退出临时统计：/tc     - 退出临时统计（不生成报告）
--
-- 特性：
--   📊 支持日、周、月、年多维度统计
--   💾 自动保存统计数据，重启后不丢失（按方案分开存储）
--   📈 自动保存昨日统计数据，方便与昨日进行对比
--   ⏱️ 临时统计功能，可记录特定时间段输入情况
--   ⚡ 极速基于≥3秒输入段中最快的段速度（字/分）
--   📊 均速基于总字数/总连续输入时间（字/分），仅统计持续≥3秒的段
--   🔄 10秒间隙自动切断连续输入段，统计真实净速度
--   💾 保存前自动备份（.bak文件）
--   🎯 只统计「按编码打字上屏」：上屏瞬间输入码非空才计入，
--      点联想词 / 复制粘贴 / 语音转文字（无编码上屏）一律排除。
--
-- 【平台配置】请根据您的使用平台修改以下变量
--   PC版（小狼毫/鼠须管）：MOBILE_MODE = false   （提示不上屏，报告可上屏）
--   手机版（同文/小企鹅）：MOBILE_MODE = true    （所有内容都可上屏）

-- ★★ 【/tj 候选栏短标题 · 2026-11-05 深夜】★★
--   旧版把整份多行报告塞进候选 text：报告第 2 行是 12 个「─」分隔线，
--   手机候选栏把换行压平后，看到的就是「一条横线 + 被挤掉/盖住的文字」，
--   日 / 周 / 月 / 年四条候选长得一模一样，完全没法预览。
--   Rime 的「候选栏显示文本」与「上屏文本」同源（都取 Candidate::text()），
--   所以**不能**只把候选改成 "今日统计" 就完事 —— 那样上屏也只剩标题。
--   本方案复用 help_cmd.lua 已用真实 rime.dll 验证过的机制：
--     · 候选栏：只显示短标题，可带一个紧凑摘要（如 "◉ 今日统计 · 1234字"）；
--     · 点候选 / 数字键：init 里挂 group = -1 的 select/commit 前置回调，
--       抢在 C++ 拼 commit text 之前把选中候选的 text 还原成完整报告；
--     · 空格：走 Submit_text 的 Lua 快捷上屏（不经 notifier），由
--       core.expand_stat_short 查表取全文。
--   报告正文（含分隔线、多行排版）一字不改，只是不再出现在候选栏。
--   ★ 短标题统一以 `◉` 开头：沿用 report_commit_text 的 `^[※◉]` 过滤，
--     保证「查看统计」这个动作本身不会被计入输入统计。
-- ============================================================

local SEPARATOR_LINE = string.rep("─", 12)
local core = require "core"

-- 移动端判定统一走 core.is_mobile()（2026-11-04 去重，见 core.lua）。

-- 移动端判定：core.is_mobile() 内部已防御式访问 rime_api，无需外层 pcall
local MOBILE_MODE = core.is_mobile()

-- 【方案配置说明】
-- 本脚本为翻译器（含 init 初始化），需在 schema.yaml 中添加以下配置：
--
-- engine:
--   translators:
--     - lua_translator@*input_statistics      # 输入统计翻译器
--
-- speller:                                     # 必须配置引导符
--   alphabet: zyxwvutsrqponmlkjihgfedcba`/@=  # 必须包含 /（斜杠）
--   initials: zyxwvutsrqponmlkjihgfedcba`/@=  # 必须包含 /（斜杠）

local input_stats = input_stats or {
    daily = {count = 0, length = 0, fastest = 0, ts = 0, avgGaps = {}, avgCnts = {}},
    weekly = {count = 0, length = 0, fastest = 0, ts = 0, avgGaps = {}, avgCnts = {}},
    monthly = {count = 0, length = 0, fastest = 0, ts = 0, avgGaps = {}, avgCnts = {}},
    yearly = {count = 0, length = 0, fastest = 0, ts = 0, avgGaps = {}, avgCnts = {}},
    lengths = {},
    daily_max = 0,
    weekly_max = 0,
    recent = {},          -- 用于临时统计的最快一分钟，主统计不再使用
    yesterday = {count = 0, length = 0, fastest = 0, ts = 0}
}

-- 连续输入段追踪（局部变量，每个方案独立）
local avgSpdInfo = {
    logSts = 0,           -- 0=空闲/段结束，1=记录中
    startTime = 0,        -- 当前段起始时间
    clickTime = 0,        -- 最后一次按键时间
    commitTime = 0,       -- 当前段最后一次上屏时间
    gapThd = 10,          -- 间隙阈值（秒）
    count = 0             -- 当前段累计字数
}

-- 模块级环境引用（init 时赋值，供 report_commit_text 与 Submit_text 桥接使用）
local STATS_ENV = nil
local STATS_SCHEMA_ID = ""

-- 性能优化：文件保存防抖机制
-- 避免每次输入都写入文件，减少IO开销
local save_debounce = {
    last_save_time = 0,
    min_interval = 30,  -- 最小保存间隔（秒）
    pending_save = false,
    last_schema_id = ""
}

-- 前向声明，避免闭包时 save_stats 为 nil
local save_stats

-- 防抖保存函数
local function debounced_save_stats(schema_id)
    if not schema_id then return false end
    
    local now = os.time()
    local time_since_last_save = now - save_debounce.last_save_time
    
    -- 如果距离上次保存不到最小间隔，标记为待保存
    if time_since_last_save < save_debounce.min_interval then
        save_debounce.pending_save = true
        save_debounce.last_schema_id = schema_id
        return false
    end
    
    -- 执行实际保存
    save_debounce.last_save_time = now
    save_debounce.pending_save = false
    return save_stats(schema_id)
end

-- 强制保存待处理的数据（在退出时调用）
local function flush_pending_save()
    if save_debounce.pending_save and save_debounce.last_schema_id then
        save_stats(save_debounce.last_schema_id)
        save_debounce.pending_save = false
    end
end

-- 安全的字符长度计算函数
local function get_text_length(text)
    if not text or text == "" then
        return 0
    end
    
    if utf8 and utf8.len then
        local utf8_len = utf8.len(text)
        if utf8_len then
            return utf8_len
        end
    end
    
    local count = 0
    local i = 1
    while i <= #text do
        local byte = text:byte(i)
        if byte < 128 then
            count = count + 1
            i = i + 1
        elseif byte >= 192 and byte < 224 then
            count = count + 1
            i = i + 2
        elseif byte >= 224 and byte < 240 then
            count = count + 1
            i = i + 3
        elseif byte >= 240 then
            count = count + 1
            i = i + 4
        else
            i = i + 1
        end
    end
    return count
end

-- 判断是否为汉字（CJK统一表意文字）
local function is_chinese_char(code)
    return (code >= 0x4E00 and code <= 0x9FFF) or   -- CJK统一表意文字
           (code >= 0x3400 and code <= 0x4DBF) or   -- CJK扩展A
           (code >= 0x20000 and code <= 0x2A6DF) or -- CJK扩展B
           (code >= 0x2A700 and code <= 0x2B73F) or -- CJK扩展C
           (code >= 0x2B740 and code <= 0x2B81F) or -- CJK扩展D
           (code >= 0x2B820 and code <= 0x2CEAF) or -- CJK扩展E
           (code >= 0x2CEB0 and code <= 0x2EBEF) or -- CJK扩展F
           (code >= 0x30000 and code <= 0x3134F) or -- CJK扩展G
           (code >= 0x31350 and code <= 0x323AF) or -- CJK扩展H
           (code >= 0x2EBF0 and code <= 0x2EE5F) or -- CJK扩展I
           (code >= 0xF900 and code <= 0xFAFF) or   -- CJK兼容表意文字
           (code >= 0x2F800 and code <= 0x2FA1F) or -- CJK兼容表意文字增补
           (code >= 0x2E80 and code <= 0x2EFF) or   -- CJK部首补充
           (code >= 0x2F00 and code <= 0x2FDF)     -- 康熙部首
end

-- 获取纯汉字长度（排除标点、数字、英文等）
local function get_chinese_length(text)
    if not text or text == "" then
        return 0
    end
    -- 检查 utf8 模块是否可用（LuaJIT 可能没有 utf8.codes）
    if not utf8 or not utf8.codes then
        return get_text_length(text)  -- 回退到总字符数统计
    end
    local count = 0
    for _, code in utf8.codes(text) do
        if is_chinese_char(code) then
            count = count + 1
        end
    end
    return count
end

-- 时间戳工具函数
local function start_of_day(t)
    if not t or not t.year or not t.month or not t.day then
        return 0
    end
    return os.time{year=t.year, month=t.month, day=t.day, hour=0}
end

local function start_of_week(t)
    if not t or not t.year or not t.month or not t.day or not t.wday then
        return 0
    end
    local d = t.wday == 1 and 6 or (t.wday - 2)
    return os.time{year=t.year, month=t.month, day=t.day - d, hour=0}
end

local function start_of_month(t)
    if not t or not t.year or not t.month then
        return 0
    end
    return os.time{year=t.year, month=t.month, day=1, hour=0}
end

local function start_of_year(t)
    if not t or not t.year then
        return 0
    end
    return os.time{year=t.year, month=1, day=1, hour=0}
end

-- 判断是否是统计命令
local function is_summary_command(text)
    return text == "/tj" or text == "/qk" or text == "/ks" or text == "/js" or text == "/tc"
end

-- 获取方案显示名称（优先中文名）
local function get_schema_display_name(env)
    if not env or not env.engine or not env.engine.schema then
        return "未知方案"
    end
    
    local schema = env.engine.schema
    local config = schema.config
    
    if config then
        local name = config:get_string("schema/name")
        if name and name ~= "" then
            return name
        end
    end
    
    return schema.schema_id or "未知方案"
end

-- 计算均速（字/分）：只统计持续≥3秒的输入段，排除零碎敲击
local function calculate_avg_speed(stat)
    local total_gaps = 0
    local total_cnts = 0
    for i = 1, #stat.avgGaps do
        local gap = stat.avgGaps[i] or 0
        local cnt = stat.avgCnts[i] or 0
        if gap >= 3 then  -- 只统计持续≥3秒的输入段
            total_gaps = total_gaps + gap
            total_cnts = total_cnts + cnt
        end
    end
    if total_gaps > 0 then
        return total_cnts / total_gaps * 60
    end
    return 0
end

-- 更新极速（基于≥3秒的输入段速度：所有段中速度最快的那个段）
-- @param seg_time: 段持续时间（秒）
-- @param seg_count: 段内字数
local function update_fastest(stat, seg_time, seg_count)
    if seg_time >= 3 and seg_count > 0 then
        local spd = seg_count / seg_time * 60
        if spd > (stat.fastest or 0) then
            stat.fastest = spd
        end
    end
end

-- 更新统计数据（核心：处理连续输入段）
-- @param input_length: 本次上屏字数（0 表示仅结算段）
-- @param is_segment_end: 1 表示当前段结束，需要将本段时间和字数存入统计
local function update_stats(input_length, is_segment_end, env)
    local now = os.date("*t")

    local day_ts = start_of_day(now)
    local week_ts = start_of_week(now)
    local month_ts = start_of_month(now)
    local year_ts = start_of_year(now)

    -- 确保所有统计对象都存在
    input_stats.daily = input_stats.daily or {count = 0, length = 0, fastest = 0, ts = 0, avgGaps = {}, avgCnts = {}}
    input_stats.weekly = input_stats.weekly or {count = 0, length = 0, fastest = 0, ts = 0, avgGaps = {}, avgCnts = {}}
    input_stats.monthly = input_stats.monthly or {count = 0, length = 0, fastest = 0, ts = 0, avgGaps = {}, avgCnts = {}}
    input_stats.yearly = input_stats.yearly or {count = 0, length = 0, fastest = 0, ts = 0, avgGaps = {}, avgCnts = {}}
    input_stats.yesterday = input_stats.yesterday or {count = 0, length = 0, fastest = 0, ts = 0}
    input_stats.lengths = input_stats.lengths or {}
    input_stats.recent = input_stats.recent or {}

    -- 检查是否是新的一天，如果是则保存昨日数据
    if input_stats.daily.ts ~= 0 and input_stats.daily.ts ~= day_ts then
        input_stats.yesterday = {
            count = input_stats.daily.count,
            length = input_stats.daily.length,
            fastest = input_stats.daily.fastest,
            ts = input_stats.daily.ts
        }
    end

    -- 周期重置逻辑
    if input_stats.daily.ts ~= day_ts then
        -- 每日重置前：将当日极速同步到周/月/年（取最大值）
        local daily_fastest = input_stats.daily.fastest or 0
        if daily_fastest > 0 then
            for _, period in ipairs({"weekly", "monthly", "yearly"}) do
                if not input_stats[period] then break end
                input_stats[period].fastest = math.max(input_stats[period].fastest or 0, daily_fastest)
            end
        end
        input_stats.daily = {count = 0, length = 0, fastest = 0, ts = day_ts, avgGaps = {}, avgCnts = {}}
        input_stats.daily_max = 0
        input_stats.recent = {}
        -- 检测到新的一天，立即保存到文件（确保昨日数据持久化）
        if env and env.engine and env.engine.schema then
            save_stats(env.engine.schema.schema_id)
        end
    end
    
    if input_stats.weekly.ts ~= week_ts then
        if input_stats.weekly.length > (input_stats.weekly_max or 0) then
            input_stats.weekly_max = input_stats.weekly.length
        end
        input_stats.weekly = {count = 0, length = 0, fastest = 0, ts = week_ts, avgGaps = {}, avgCnts = {}}
    end
    
    if input_stats.monthly.ts ~= month_ts then
        input_stats.monthly = {count = 0, length = 0, fastest = 0, ts = month_ts, avgGaps = {}, avgCnts = {}}
        input_stats.weekly_max = 0
    end
    
    if input_stats.yearly.ts ~= year_ts then
        input_stats.yearly = {count = 0, length = 0, fastest = 0, ts = year_ts, avgGaps = {}, avgCnts = {}}
        input_stats.lengths = {}
    end

    -- 处理段结束：将当前连续输入段的时间与字数存入各周期
    if is_segment_end == 1 then
        local delt = avgSpdInfo.clickTime - avgSpdInfo.startTime
        if delt > 0 and avgSpdInfo.count > 0 then
            local function add_to_stat(stat)
                table.insert(stat.avgGaps, delt)
                table.insert(stat.avgCnts, avgSpdInfo.count)
            end
            add_to_stat(input_stats.daily)
            add_to_stat(input_stats.weekly)
            add_to_stat(input_stats.monthly)
            add_to_stat(input_stats.yearly)
            -- 段结束时更新极速（基于≥3秒段速度）
            update_fastest(input_stats.daily, delt, avgSpdInfo.count)
            update_fastest(input_stats.weekly, delt, avgSpdInfo.count)
            update_fastest(input_stats.monthly, delt, avgSpdInfo.count)
            update_fastest(input_stats.yearly, delt, avgSpdInfo.count)
        end
    end

    -- 统计字数（只有 input_length > 0 才计入）
    if input_length > 0 then
        local function add(stat)
            stat.count = stat.count + 1
            stat.length = stat.length + input_length
        end
        add(input_stats.daily)
        add(input_stats.weekly)
        add(input_stats.monthly)
        add(input_stats.yearly)

        if input_length > (input_stats.daily_max or 0) then
            input_stats.daily_max = input_length
        end

        input_stats.lengths[input_length] = (input_stats.lengths[input_length] or 0) + 1
    end
end

-- ★ 上屏计数入口（commit_notifier 与 Submit_text 快捷上屏桥接共用）
--   只统计「按编码打字上屏」的内容；编码非空判据由调用方负责：
--   - commit_notifier：先判 ctx.input 非空再调用（排除点联想/复制/语音）
--   - Submit_text 快捷上屏：空格/分号/引号本就是编码上屏，直接调用
local function report_commit_text(commit_text)
    if not commit_text or commit_text == "" then return end

    -- 排除统计命令
    if is_summary_command(commit_text) then return end

    -- 排除统计报告上屏
    if commit_text:match("^[※◉]") then return end

    -- 只统计汉字长度，排除标点数字
    local input_length = get_chinese_length(commit_text)
    local timeNow = os.time()

    -- 连续输入段处理
    if avgSpdInfo.logSts ~= 1 then
        avgSpdInfo.logSts = 1
        avgSpdInfo.startTime = timeNow
        avgSpdInfo.commitTime = timeNow
        avgSpdInfo.count = input_length
    else
        local delt = timeNow - avgSpdInfo.clickTime
        if delt > avgSpdInfo.gapThd then
            if avgSpdInfo.clickTime - avgSpdInfo.startTime >= 1 and avgSpdInfo.count > 0 then
                update_stats(0, 1, STATS_ENV)
            end
            avgSpdInfo.startTime = timeNow
            avgSpdInfo.count = input_length
        else
            avgSpdInfo.count = avgSpdInfo.count + input_length
        end
        avgSpdInfo.commitTime = timeNow
    end
    avgSpdInfo.clickTime = timeNow

    -- 更新字数统计（不结束段）
    update_stats(input_length, 0, STATS_ENV)

    -- 更新临时统计
    if STATS_ENV and STATS_ENV.temp_stats and STATS_ENV.temp_stats.is_collecting then
        STATS_ENV.temp_stats.count = STATS_ENV.temp_stats.count + 1
        STATS_ENV.temp_stats.length = STATS_ENV.temp_stats.length + input_length

        local ts = os.time()
        table.insert(STATS_ENV.temp_stats.recent, {ts = ts, len = input_length})
        local threshold = ts - 60
        local current_minute_total = 0
        local new_recent = {}
        for _, item in ipairs(STATS_ENV.temp_stats.recent) do
            if item and item.ts and item.ts >= threshold then
                current_minute_total = current_minute_total + (item.len or 0)
                table.insert(new_recent, item)
            end
        end
        STATS_ENV.temp_stats.recent = new_recent
        if current_minute_total > (STATS_ENV.temp_stats.fastest or 0) then
            STATS_ENV.temp_stats.fastest = current_minute_total
        end
    end

    -- 保存统计（防抖）
    debounced_save_stats(STATS_SCHEMA_ID)
end

-- 注入到 core（替代原 _G.InputStats_Report），供 Submit_text.lua 的快捷上屏
-- （空格/分号/引号）补计数。core.stats_report 见 core.lua 注释。
core.stats_report = report_commit_text

-- 序列化工具
local function serialize_table(tbl, indent)
    indent = indent or 0
    local spaces = string.rep(" ", indent)
    local lines = {"{"}
    
    for k, v in pairs(tbl) do
        local key = (type(k) == "string") and ("[\"" .. k .. "\"]") or ("[" .. k .. "]")
        local val
        
        if type(v) == "table" then
            val = serialize_table(v, indent + 4)
        elseif type(v) == "string" then
            val = '"' .. v .. '"'
        else
            val = tostring(v)
        end
        table.insert(lines, string.format("%s    %s = %s,", spaces, key, val))
    end
    table.insert(lines, spaces .. "}")
    return table.concat(lines, "\n")
end

-- 保存统计到文件（按方案分开存储，自动备份）
save_stats = function(schema_id)
    if not schema_id then return false end
    local dir = (rime_api and rime_api.get_user_data_dir and rime_api:get_user_data_dir() or "") .. "/lua/"
    local path = dir .. "input_stats_" .. schema_id .. ".lua"
    local bak_path = path .. ".bak"

    -- 备份旧文件（Windows 兼容：先删除旧 .bak 再重命名）
    local old = io.open(path, "r")
    if old then
        old:close()
        os.remove(bak_path)      -- Windows 上 os.rename 不会覆盖已存在的文件
        os.rename(path, bak_path)
    end

    local file = io.open(path, "w")
    if not file then return false end
    file:write("return " .. serialize_table(input_stats) .. "\n")
    file:close()
    return true
end

-- 加载统计数据（按方案）
local function load_stats_from_lua_file(schema_id)
    if not schema_id then return end
    local path = (rime_api and rime_api.get_user_data_dir and rime_api:get_user_data_dir() or "") .. "/lua/input_stats_" .. schema_id .. ".lua"
    local ok, result = pcall(function()
        local env = {}
        local f = loadfile(path)
        if not f then
            return nil
        end

        if setfenv then
            setfenv(f, env)
            local ret = f()
            if type(ret) == "table" then
                return ret
            end
            return env.input_stats
        else
            local f2 = loadfile(path, "t", env)
            if not f2 then
                return nil
            end
            local ret = f2()
            if type(ret) == "table" then
                return ret
            end
            return env.input_stats
        end
    end)
    
    if ok and type(result) == "table" then
        for k, v in pairs(result) do
            input_stats[k] = v
        end
        -- 确保各周期有 avgGaps/avgCnts
        for _, period in ipairs({"daily", "weekly", "monthly", "yearly"}) do
            input_stats[period] = input_stats[period] or {count = 0, length = 0, fastest = 0, ts = 0, avgGaps = {}, avgCnts = {}}
            input_stats[period].avgGaps = input_stats[period].avgGaps or {}
            input_stats[period].avgCnts = input_stats[period].avgCnts or {}
        end
        input_stats.lengths = input_stats.lengths or {}
        input_stats.recent = input_stats.recent or {}
        input_stats.yesterday = input_stats.yesterday or {count = 0, length = 0, fastest = 0, ts = 0}
        input_stats.daily_max = input_stats.daily_max or 0
        input_stats.weekly_max = input_stats.weekly_max or 0
    else
        -- 初始化空表
        input_stats = {
            daily = {count = 0, length = 0, fastest = 0, ts = 0, avgGaps = {}, avgCnts = {}},
            weekly = {count = 0, length = 0, fastest = 0, ts = 0, avgGaps = {}, avgCnts = {}},
            monthly = {count = 0, length = 0, fastest = 0, ts = 0, avgGaps = {}, avgCnts = {}},
            yearly = {count = 0, length = 0, fastest = 0, ts = 0, avgGaps = {}, avgCnts = {}},
            lengths = {},
            daily_max = 0,
            weekly_max = 0,
            recent = {},
            yesterday = {count = 0, length = 0, fastest = 0, ts = 0}
        }
    end
end

-- 临时统计报告格式化（末尾增加换行）
local function format_custom_summary(temp_stats, schema_name)
    local end_ts = temp_stats.last_slash_time or os.time()
    local duration_sec = end_ts - temp_stats.start_time
    local minutes = duration_sec / 60
    
    local speed = 0
    if minutes > 0 then
        speed = math.floor((temp_stats.length / minutes) * 100) / 100
    end
    
    return string.format(
        "◉ 临时统计报告\n"..
        "%s\n"..
        "◉ 开始时间：%s\n"..
        "◉ 结束时间：%s\n"..
        "◉ 统计时长：%d分 %d秒\n"..
        "◉ 输入条数：%d条\n"..
        "◉ 总字数：%d字\n"..
        "◉ 平均速度：%.2f 字/分钟\n"..
        "◉ 最快一分钟输入：%d字\n"..
        "%s\n"..
        "◉ 方案：%s\n",
        SEPARATOR_LINE,
        os.date("%Y-%m-%d %H:%M:%S", temp_stats.start_time),
        os.date("%Y-%m-%d %H:%M:%S", end_ts),
        math.floor(minutes), math.floor(duration_sec % 60),
        temp_stats.count,
        temp_stats.length,
        speed,
        temp_stats.fastest,
        SEPARATOR_LINE,
        schema_name or "未知方案"
    )
end

-- 日统计报告（末尾增加换行）
local function format_daily_summary(schema_name)
    local s = input_stats.daily or {count = 0, length = 0, fastest = 0, avgGaps = {}, avgCnts = {}}
    local y = input_stats.yesterday or {count = 0, length = 0, fastest = 0}
    
    if s.count == 0 then 
        return "※ 今天没有任何记录"
    end
    
    local avg_speed = calculate_avg_speed(s)
    local fastest = s.fastest or 0  -- 极速为最快段速度（字/分）
    
    -- 计算与昨日的对比
    local comparison_text = ""
    if y and y.length > 0 then
        local diff = s.length - y.length
        local diff_percent = 0
        if y.length > 0 then
            diff_percent = (diff / y.length) * 100
        end
        if diff > 0 then
            comparison_text = string.format("比昨日多%d字 (+%.1f%%)", diff, diff_percent)
        elseif diff < 0 then
            comparison_text = string.format("比昨日少%d字 (%.1f%%)", -diff, diff_percent)
        else
            comparison_text = "与昨日持平"
        end
    else
        comparison_text = "昨日无记录"
    end
    
    return string.format(
        "◉ 今日统计\n"..
        "%s\n"..
        "共上屏[%d]次\n"..
        "共输入[%d]字\n"..
        "极速[%.1f]字/分\n"..
        "均速[%.1f]字/分\n"..
        "%s\n"..
        "%s\n"..
        "◉ 方案：%s\n",
        SEPARATOR_LINE,
        s.count,
        s.length,
        fastest,
        avg_speed,
        comparison_text,
        SEPARATOR_LINE,
        schema_name
    )
end

-- 周统计报告（末尾增加换行）
local function format_weekly_summary(schema_name)
    local s = input_stats.weekly or {count = 0, length = 0, fastest = 0, avgGaps = {}, avgCnts = {}}
    if s.count == 0 then 
        return "※ 本周没有任何记录"
    end
    
    local avg_speed = calculate_avg_speed(s)
    local fastest = s.fastest or 0
    
    return string.format(
        "◉ 本周统计\n"..
        "%s\n"..
        "共上屏[%d]次\n"..
        "共输入[%d]字\n"..
        "极速[%.1f]字/分\n"..
        "均速[%.1f]字/分\n"..
        "周内单日最多一次输入[%d]字\n"..
        "%s\n"..
        "◉ 方案：%s\n",
        SEPARATOR_LINE,
        s.count,
        s.length,
        fastest,
        avg_speed,
        input_stats.daily_max or 0,
        SEPARATOR_LINE,
        schema_name
    )
end

-- 月统计报告（末尾增加换行）
local function format_monthly_summary(schema_name)
    local s = input_stats.monthly or {count = 0, length = 0, fastest = 0, avgGaps = {}, avgCnts = {}}
    if s.count == 0 then 
        return "※ 本月没有任何记录"
    end
    
    local avg_speed = calculate_avg_speed(s)
    local fastest = s.fastest or 0
    
    return string.format(
        "◉ 本月统计\n"..
        "%s\n"..
        "共上屏[%d]次\n"..
        "共输入[%d]字\n"..
        "极速[%.1f]字/分\n"..
        "均速[%.1f]字/分\n"..
        "月内单周最多一次输入[%d]字\n"..
        "%s\n"..
        "◉ 方案：%s\n",
        SEPARATOR_LINE,
        s.count,
        s.length,
        fastest,
        avg_speed,
        input_stats.weekly_max or 0,
        SEPARATOR_LINE,
        schema_name
    )
end

-- 年统计报告（末尾增加换行）
local function format_yearly_summary(schema_name)
    local s = input_stats.yearly or {count = 0, length = 0, fastest = 0, avgGaps = {}, avgCnts = {}}
    if s.count == 0 then 
        return "※ 本年没有任何记录"
    end
    
    local avg_speed = calculate_avg_speed(s)
    local fastest = s.fastest or 0
    
    local fav = 0
    if input_stats.lengths then
        local length_counts = {}
        for length, count in pairs(input_stats.lengths) do
            if type(length) == "number" and type(count) == "number" then
                table.insert(length_counts, {length = length, count = count})
            end
        end
        table.sort(length_counts, function(a, b) return a.count > b.count end)
        fav = length_counts[1] and length_counts[1].length or 0
    end
    
    return string.format(
        "◉ 本年统计\n"..
        "%s\n"..
        "共上屏[%d]次\n"..
        "共输入[%d]字\n"..
        "极速[%.1f]字/分\n"..
        "均速[%.1f]字/分\n"..
        "您最常输入长度为[%d]的词组\n"..
        "%s\n"..
        "◉ 方案：%s\n",
        SEPARATOR_LINE,
        s.count,
        s.length,
        fastest,
        avg_speed,
        fav,
        SEPARATOR_LINE,
        schema_name
    )
end

-- 辅助函数：判断字符串是否为“无数据”的提示消息
local function is_empty_report(str)
    return str == "※ 今天没有任何记录" or
           str == "※ 本周没有任何记录" or
           str == "※ 本月没有任何记录" or
           str == "※ 本年没有任何记录"
end

-- 根据平台生成候选（所有内容都放在 text 中，确保候选词可见）
-- /qk /ks /tc 的提示消息本就是单行短文本，直接放 text，无需展开。
local function create_message_candidate(seg, message)
    return Candidate("stat", seg.start, seg._end, message, "")
end

-- ============================================================================
-- == 短标题 → 完整报告（/tj 四期统计、/js 临时统计）==
-- ============================================================================
-- 固定 key（短标题前缀）→ 完整报告。key 不含动态摘要，故表永远只有 4~5 条，
-- 每次 /tj /js 重新生成时**覆盖而非清空**：防止个别平台「选中前又重新 compose」
-- 把表清掉，导致只上屏短标题。
local SHORT_FULL = {}
local BRIEF_IN_TITLE = true   -- 改 false ⇒ 候选栏只显示纯标题「◉ 今日统计」

local function stat_expand_lookup(text)
    if not text or text == "" then return nil end
    for key, full in pairs(SHORT_FULL) do
        -- 前缀匹配：候选文本 = key .. " · 1234字"；完整报告本身也以 key 开头，
        -- 此时查回自己 ⇒ 调用方判 full == text 即跳过，天然幂等。
        if text:sub(1, #key) == key then return full end
    end
    return nil
end

-- 供 Submit_text 的空格快捷上屏查询（跨模块函数注入，与 core.stats_report 同风格：
-- 挂 core 而非 core.state —— 它是函数，不是瞬时状态信号）。
core.expand_stat_short = stat_expand_lookup

-- 候选栏摘要：只放一个最关心的数字，够短、不会像整份报告那样被候选栏挤没。
local function brief_for(s)
    if not s or (s.count or 0) == 0 then return " · 无记录" end
    return string.format(" · %d字", s.length or 0)
end

-- 候选栏只 yield 短标题；完整报告记入 SHORT_FULL，选中时由 hook_expand 还原。
local function yield_report(seg, key, brief, full)
    SHORT_FULL[key] = full
    local short = BRIEF_IN_TITLE and (key .. brief) or key
    yield(Candidate("stat_short", seg.start, seg._end, short, ""))
end

-- group = -1 前置回调：抢在 C++ Engine::OnCommit 之前把候选 text 改回完整报告，
-- 并给「多行上屏内容」统一补一个尾部换行（见下方 expand 的第 ② 步）。
-- ★ 默认 group 时 C++ 已先 sink 短标题，再改就来不及（实测只上屏标题）。
--   select_notifier 与 commit_notifier 都挂，任一生效即可、互为兼容兜底。
-- ★ 闭包只捕获模块级 Lua 值，**绝不持有 engine / ctx 等 C++ userdata**
--   （否则 RimeDestroySession 时 use-after-free，见 help_cmd.lua 事故说明）。
-- ★ context 级 property 闩锁：切方案会重建 translator（新 env）但 Context 不变，
--   只用 env 标记会重复连接；property 不带 `_` 前缀 ⇒ 不会被瞬时选项清理。
-- ★ 本回调是**全方案通用**的（4 个五笔 schema 都注册了本 translator，init 时
--   无条件安装）：不只管 /tj /js，任意模块的候选只要上屏文本是多行，都会收尾。
local function hook_expand(env)
    local ctx = env and env.engine and env.engine.context
    if not ctx then return end
    if ctx:get_property("stat_expand_hooked") == "1" then return end
    ctx:set_property("stat_expand_hooked", "1")
    local function expand(c)
        pcall(function()
            -- ① 短标题 → 还原完整内容（/tj /js 报告 + 多行命令的首行标题）
            --    ★ 优先用选中候选自身的 text 查表：get_commit_text() 在多段拼接时
            --      未必等于标题；cand.text 才是精确的候选栏文本。
            --    ★ core.expand_short_full 是「精确匹配」的通用表，覆盖 schedule.lua
            --      的 /jt /jq /gz /nl、super_sequence.lua 的 /txtj 等所有多行命令；
            --      与 stat_expand_lookup（前缀匹配）互不冲突，天然幂等
            --      （展开后 text 已是全文，末尾补上 \n 后精确/前缀都不会再命中）。
            local cand0 = c:get_selected_candidate()
            local t = (cand0 and cand0.text) or c:get_commit_text()
            local full = stat_expand_lookup(t) or core.expand_short_full(t)
            if full and full ~= t and cand0 then cand0.text = full end
            -- ② 通用收尾（2026-11-06 用户规则）：任意候选的上屏文本，
            --    **多行且末尾没有 \n** → 补 1 个 \n（光标落到内容后的空行，
            --    避免接着打字粘在上屏内容尾部）；**单行一律不动**（时间/日期/
            --    提示/符号要能直接接着打字）。
            --    覆盖 schedule.lua 的 /jq /gz /nl /jt 多行信息、
            --    super_sequence.lua 的 /txtj 调序统计等所有命令候选。
            --    ★ 幂等：已有 \n 原样；与 help_cmd 的 group=-1 回调互不干扰
            --      （短标题、/h 分组行是单行，本回调不会改它们，
            --       help_cmd 展开后的 OVERVIEW / line..\n 末尾已有 \n 也不再补）。
            --    ★ 候选栏 text 从未被塞入尾部 \n，前端不会渲染空白。
            local cand = c:get_selected_candidate()
            if cand and cand.text and cand.text ~= "" then
                local fixed = core.finalize_commit_text(cand.text)
                if fixed ~= cand.text then cand.text = fixed end
            end
        end)
    end
    pcall(function()
        ctx.select_notifier:connect(expand, -1)
        ctx.commit_notifier:connect(expand, -1)
    end)
end

-- 转换器函数：处理统计命令
local function translator(input, seg, env)
    local schema_name = get_schema_display_name(env)

    -- 按键时检测连续输入段是否超时
    local timeNow = os.time()
    if timeNow - avgSpdInfo.clickTime > avgSpdInfo.gapThd then
        if avgSpdInfo.clickTime - avgSpdInfo.startTime >= 1 and avgSpdInfo.count > 0 then
            update_stats(0, 1, env)
        end
        avgSpdInfo.logSts = 0
    end
    if avgSpdInfo.logSts == 0 then
        avgSpdInfo.logSts = 1
        avgSpdInfo.startTime = timeNow
        avgSpdInfo.commitTime = timeNow
        avgSpdInfo.count = 0
    end
    avgSpdInfo.clickTime = timeNow
    
    -- 【查看统计时强制结算当前段】确保实时显示速度，不会因为段未结束而显示0
    local function flush_current_segment()
        if avgSpdInfo.logSts == 1 and avgSpdInfo.count > 0 then
            local delt = avgSpdInfo.clickTime - avgSpdInfo.startTime
            if delt >= 1 then
                update_stats(0, 1, env)
            end
        end
    end
    
    -- 命令处理
    if input == "/tj" then
        flush_current_segment()
        local daily = format_daily_summary(schema_name)
        local weekly = format_weekly_summary(schema_name)
        local monthly = format_monthly_summary(schema_name)
        local yearly = format_yearly_summary(schema_name)
        -- ★ 候选栏只有 4 条短标题（可带字数摘要）；点选 / 空格上屏的仍是
        --   上面四份完整报告。顺序保持「今日 / 本周 / 本月 / 本年」不变。
        yield_report(seg, "◉ 今日统计", brief_for(input_stats.daily), daily)
        yield_report(seg, "◉ 本周统计", brief_for(input_stats.weekly), weekly)
        yield_report(seg, "◉ 本月统计", brief_for(input_stats.monthly), monthly)
        yield_report(seg, "◉ 本年统计", brief_for(input_stats.yearly), yearly)
    elseif input == "/qk" then
        local yesterday_data = input_stats.yesterday or {count = 0, length = 0, fastest = 0, ts = 0}
        input_stats = {
            daily = {count = 0, length = 0, fastest = 0, ts = 0, avgGaps = {}, avgCnts = {}},
            weekly = {count = 0, length = 0, fastest = 0, ts = 0, avgGaps = {}, avgCnts = {}},
            monthly = {count = 0, length = 0, fastest = 0, ts = 0, avgGaps = {}, avgCnts = {}},
            yearly = {count = 0, length = 0, fastest = 0, ts = 0, avgGaps = {}, avgCnts = {}},
            lengths = {},
            daily_max = 0,
            weekly_max = 0,
            recent = {},
            yesterday = yesterday_data
        }
        save_stats(env.engine.schema.schema_id)
        yield(create_message_candidate(seg, "※ 所有统计数据已清空（昨日数据保留）。"))
    elseif input == "/ks" then
        env.temp_stats = {
            count = 0,
            length = 0,
            fastest = 0,
            recent = {},
            start_time = os.time(),
            is_collecting = true
        }
        yield(create_message_candidate(seg, "📝 临时统计已开始"))
    elseif input == "/js" then
        if env.temp_stats and env.temp_stats.is_collecting then
            flush_current_segment()
            env.temp_stats.is_collecting = false
            env.temp_stats.last_slash_time = os.time()
            local report = format_custom_summary(env.temp_stats, schema_name)
            -- /js 的报告同样是多行带分隔线，一并走短标题（否则候选栏仍是横线）
            yield_report(seg, "◉ 临时统计报告",
                         string.format(" · %d字", env.temp_stats.length or 0), report)
        else
            yield(Candidate("stat", seg.start, seg._end, "※ 当前没有进行中的临时统计", ""))
        end
    elseif input == "/tc" then
        -- 先确保 env.temp_stats 是有效状态
        if type(env.temp_stats) ~= "table" then
            env.temp_stats = nil
        end
        local is_collecting = env.temp_stats and env.temp_stats.is_collecting
        if is_collecting then
            env.temp_stats.is_collecting = false
            env.temp_stats = nil
        end
        local msg = is_collecting and "※ 临时统计已退出，数据已清空" or "※ 当前没有进行中的临时统计"
        yield(create_message_candidate(seg, msg))
    end
end

-- 初始化
local function init(env)
    if not env or not env.engine then
        return
    end

    local ctx = env.engine.context
    local schema_id = env.engine.schema.schema_id

    -- 保存模块级环境，供 report_commit_text 与 Submit_text 桥接使用
    STATS_ENV = env
    STATS_SCHEMA_ID = schema_id

    -- 加载统计数据（按方案）
    load_stats_from_lua_file(schema_id)

    -- 初始化临时统计状态
    env.temp_stats = env.temp_stats or {
        is_collecting = false,
        count = 0,
        length = 0,
        fastest = 0,
        recent = {}
    }

    -- ★ /tj /js 短标题 → 完整报告：挂 group = -1 的前置回调（早于下面的
    --   统计回调与 C++ OnCommit）。该函数带 context 级闩锁，切方案不会重复连。
    hook_expand(env)

    -- 注册提交通知回调
    if ctx and ctx.commit_notifier then
        ctx.commit_notifier:connect(function(ctx)
            if not ctx then return end

            -- ★ 编码非空判据：只统计「按编码打字上屏」。
            --   Commit() 先触发本回调再清空编码，故此刻 ctx.input 即上屏前的编码串。
            --   点联想词（predictor 空段）/ 复制粘贴 / 语音转文字：编码为空 → 排除。
            local input_at_commit = nil
            pcall(function() input_at_commit = ctx.input end)
            if not input_at_commit or input_at_commit == "" then return end

            local commit_text = ctx:get_commit_text()
            report_commit_text(commit_text)
        end)

    end
end

return { init = init, func = translator }