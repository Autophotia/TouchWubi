-- ============================================================
-- 【来源与署名】★ 2026-09-30 补署
--   创意来源：万象拼音（万象家族 lua）
--     上游：https://github.com/amzxyz/rime_wanxiang
--   修改：Autophotia（超越输入法 · TouchWB 双键五笔方案）
--         https://github.com/Autophotia/TouchWubi
--
--   溯源：万象系成员 —— 手动自由排序 + 自动词频排序。
--         本方案后续迭代较多（移动端数字键、自动调频、/tx* 系列命令等），
--         结构与上游已有差异。
--
--   ★ 创意归万象及上游作者；本方案内的改动由 Autophotia 负责，
--     缺陷请联系修改者，不要反馈给上游项目。
-- ============================================================
-- 万象拼音方案新成员：手动自由排序 + 自动词频排序（支持PC端快捷键 + 移动端数字键）
-- 数据存放于 userdb 中，处于性能考量，此排序仅影响当前输入码
--
-- 【PC端快捷键】
--   Ctrl+J  前移当前高亮候选一位
--   Ctrl+K  后移当前高亮候选一位
--   Ctrl+L  重置当前编码的所有调序记录（恢复默认顺序）
--   Ctrl+P  置顶当前高亮候选
--
-- 【移动端数字键】（Trime / Hamster 等，需启用下滑数字）
--   数字键 2-9  前移对应序号的候选（例如 3 将第3候选前移一位）
--   数字键 0    前移第10候选
--   数字键 1    撤销上次调序操作（仅对当前编码有效）
--
-- 【其他命令】（均仅影响当前方案）
--   /txqk   调序清空（清除所有调序记录，仅清空 userdb，保留备份文件）
--   /txdc   调序导出（导出调序数据至 sequence_<schema_id>.txt，仅当数据库条目数大于备份时允许覆盖）
--   /txdr   调序导入（从 sequence_<schema_id>.txt 恢复调序数据）
--   /txtj   调序统计（查看所有调序记录，按空格上屏）
--
-- 【自动调频】（第二十轮新增，开关 switches/auto_freq，reset: 1 默认开）
--   同一编码下**连续**上屏两次的词自动提前（AUTO_FREQ_MIN=2），提前后一直保持在前面，
--   直到同一个编码下有别的词也「连续两次」上屏，后者排到更前面。
--   ⚠ 第二十二轮修正：早先记的是「累计次数」，于是词一旦参与过调频，之后每上屏一次
--     计数就 +1，排序值反超对手 ⇒ 变成「单次输入也会顶到第一」。现在改为只在
--     **连续两次**时才写库，单次输入完全不动数据（详见 af_record 注释）。
--   ⚠⚠ S93 修正（用户实测报告的「轮流抢第一」）：旧实现在「连续两次」达标后，
--     **每一次继续上屏都会把序号刷新成最大**（db:update(key, "T"..max+1)），
--     而读取侧是按序号降序排 ⇒ 谁最后上屏谁第一，两个词互相顶来顶去。
--     现在改为：**首次达标即定序，之后不动**（af_record 里已存在就直接返回 false）。
--     这才符合上面那句设计意图（「直到**别的**词也连续两次」才换位）。
--   ⚠⚠ S93 同时删掉判据③里 `text = _af_last_text` 的兜底 ——
--     拿「上一次结算的词」冒充「本次上屏的词」，会给没被上屏的词补计数，
--     同样表现为莫名其妙的词轮流抢第一。取不到词就不记（宁可漏记，不可记错）。
--   手动调序（Ctrl+J/K/L/P、移动端数字键）始终优先，不会被它覆盖。
--   /txzq   调序自动清（清空自动调频记录，手动调序保留）
--   /txzj   调序自动检（自动调频自检：开关 / 连续次数 / 本码已调频词）
--
-- 【S93 新增自动调频专项探针】log/af_probe.log
--   只读、不改任何状态。目的是把「点选候选栏 / 空格上屏 / 收起键盘再弹出」
--   三条路径在日志里彻底分开（此前它们落在同一段代码里，只能靠推测）。
--
-- 【方案配置说明】
-- 本脚本包含处理器(P)和过滤器(F、S)，需在 schema.yaml 中添加相应配置：
--
-- engine:
--   processors:
--     - lua_processor@*super_sequence*P       # 处理器：处理 Ctrl+J/K/L/P 及移动端数字键
--   filters:
--     - lua_filter@*super_sequence*F          # 过滤器：应用手动调序记录（调整候选项顺序）
--     - lua_filter@*super_sequence*S          # 过滤器：自动按词频排序（基于 quality 降序，可选）
--
-- key_binder:                                  # 按键绑定配置（可选，仅影响 PC 端 Ctrl 快捷键）
--   sequence:
--     up: "Control+j"                         # 前移
--     down: "Control+k"                       # 后移
--     reset: "Control+l"                      # 重置
--     pin: "Control+p"                        # 置顶
--
-- 无需识别器配置，脚本通过以下方式判断：
--   - 检测 Ctrl 键组合（key_event:ctrl()）
--   - is_function_mode_active() 排除功能模式
--   - 输入 "/txqk" 触发清空数据库
--   - 移动端自动检测并启用数字键调序
--
-- 注意：
--   - S 过滤器（自动词频排序）为可选组件，若不需要可省略。
--   - 若同时使用 F 和 S，建议先执行 S（词频排序），再执行 F（手动调序），
--     以确保手动调序覆盖自动排序结果（顺序由 filters 列表顺序决定）。

-- 内部常量定义（从 wanxiang.lua 提取）
local RIME_PROCESS_RESULTS = {
    kRejected = 0, -- 表示处理器明确拒绝了这个按键，停止处理链但不返回 true
    kAccepted = 1, -- 表示处理器成功处理了这个按键，停止处理链并返回 true
    kNoop = 2,     -- 表示处理器没有处理这个按键，继续传递给下一个处理器
}

---判断是否在命令模式（从 wanxiang.lua 提取）
---@param context Context | nil
---@return boolean
local function is_function_mode_active(context)
    if not context or not context.composition or context.composition:empty() then
        return false
    end

    local seg = context.composition:back()
    if not seg then return false end

    return seg:has_tag("number") or  -- number_translator.lua 数字金额转换 R+数字
        seg:has_tag("unicode") or    -- unicode.lua 输出 Unicode 字符 U+小写字母或数字
        seg:has_tag("calculator") or -- super_calculator.lua V键计算器
        seg:has_tag("shijian") or    -- shijian.lua /rq /sr 等与时间日期相关功能
        seg:has_tag("Ndate")         -- shijian.lua N日期功能
end

-- 更可靠的 iOS 检测
local function is_ios_device()
    return os.getenv("HOME") and os.getenv("HOME"):find("/var/mobile/") ~= nil
end

-- 检测是否为移动端（Trime / Hamster / 超越输入法等）
-- 自动检测是否为移动设备（智能平台检测）
-- 支持的输入法：同文(Trime)、仓(Hamster)、超越输入法(Beyond)、鸿蒙系统等
local function is_mobile_device()
    -- 获取路径（支持 rime_api 和回退到环境变量）
    local user_data_dir = ""
    local shared_data_dir = ""
    local dist = ""
    local dist_name = ""

    if rime_api then
        user_data_dir = rime_api.get_user_data_dir() or ""
        shared_data_dir = rime_api.get_shared_data_dir() or ""
        dist = rime_api.get_distribution_code_name() or ""
        dist_name = rime_api.get_distribution_name() or ""
    end

    local lower_dist = dist:lower()
    local dist_name_lower = dist_name:lower()
    local lower_path = user_data_dir:lower()
    local sys_lower_path = shared_data_dir:lower()
    local home = (os.getenv("HOME") or ""):lower()

    -- 1. 已知移动端输入法（distribution_code_name）
    if lower_dist == "trime" or
        lower_dist == "hamster" or
        lower_dist == "hamster3" then
        return true
    end

    -- 2. 超越输入法检测（RimeAPI + /space/ 路径）
    if dist_name_lower == "rimeapi" and
        (lower_path:find("/space/") or sys_lower_path:find("/space/")) then
        return true
    end

    -- 3. 通用移动路径关键词（Android/iOS/macOS）
    local mobile_keywords = {"/android/", "/mobile/", "/sdcard/", "/storage/emulated/",
                             "applications", "library"}
    for _, kw in ipairs(mobile_keywords) do
        if lower_path:find(kw) or sys_lower_path:find(kw) then
            return true
        end
    end

    -- 4. 鸿蒙系统路径特征（HarmonyOS / HarmonyOS NEXT）
    -- 4.1 传统鸿蒙路径标识
    if lower_path:find("/harmony/") or
        lower_path:find("/hap/") or
        lower_path:find("/harmonyos/") or
        lower_path:find("/openharmony/") or
        sys_lower_path:find("/harmony/") or
        sys_lower_path:find("/hap/") then
        return true
    end

    -- 4.2 鸿蒙沙箱存储路径（el数字 是鸿蒙特有，/data/storage/ 是 Android/鸿蒙共有）
    if lower_path:find("/data/storage/el%d+") or
        sys_lower_path:find("/data/storage/el%d+") then
        return true
    end

    -- 4.3 鸿蒙 bundle 路径（应用资源目录）
    if lower_path:find("/bundle/") or sys_lower_path:find("/bundle/") then
        return true
    end

    -- 4.4 鸿蒙用户目录特征（/storage/Users/）
    if lower_path:find("/storage/users/") or
        sys_lower_path:find("/storage/users/") or
        home:find("/storage/users/") then
        return true
    end

    -- 4.5 超越输入法 + 鸿蒙组合检测
    if dist_name_lower == "rimeapi" and
        (lower_path:find("/data/storage/el%d+") or
         lower_path:find("/space/") or
         home:find("/storage/users/")) then
        return true
    end

    -- 5. JIT 平台检测（Android/HarmonyOS）
    if jit and jit.os then
        local os_name = jit.os:lower()
        if os_name:find("android") or os_name:find("harmony") then
            return true
        end
    end

    -- 6. 环境变量检测
    if os.getenv("HMOS") or os.getenv("HARMONYOS") then
        return true
    end

    -- 7. iOS 路径检测
    if home:find("/var/mobile/") then
        return true
    end

    -- 8. HOME 目录回退检测（Android 兜底）
    if home:find("/storage/emulated/") then return true end
    if home:find("/data/data/") then return true end

    return false
end

local MOBILE_MODE = is_mobile_device()

---@type string | nil 当前选中的键，命令模式为 0 开始的位置索引，正常模式为候选词
local cur_adjustment_phrase = nil

---@type integer | nil 当前高亮索引
local cur_highlight_idx = nil

---- `0`: 无调整，默认值
---- `-1`: 前移一位
---- `1`: 后移一位
---- `nil`: 重置/置顶
---@type -1 | 1 | 0 | nil
local cur_adjust_offset = 0

---@type boolean 是否处于 pin 模式
local in_pin_mode = false

---@type integer | nil 数字键置顶的候选索引（1-indexed），nil 表示无待处理置顶
--- 1 = 撤销，2-9/0 = 前移对应候选
local pin_candidate_index = nil

---@type table | nil 上次调序记录 { code, text, from_position }，用于撤销
local last_adjustment = nil

---@type table<string, table> 移动端会话内候选顺序追踪 { [code] = {text1, text2, ...} }
--- 避免 S 排序覆盖手动调序结果
local mobile_candidate_order = {}

-- 按方案存储的导出标记
local _need_export = {}
-- 当前方案ID（用于 fini 时关闭数据库）
local current_schema_id = nil
-- 按方案存储的清空标记（清空后阻止自动导入）
local _cleared_schemas = {}

-- 按方案存储的数据库连接
local _user_dbs = {}

-- 获取方案特定的数据库文件名
local function get_db_file_name(schema_id)
    local base_name = is_ios_device() and
                      (os.getenv("HOME") .. "/Documents/sequence") or
                      "lua/sequence"
    return base_name .. "_" .. schema_id
end

-- 获取方案特定的导出文件名
local function get_export_file_name(schema_id)
    return (rime_api.get_user_data_dir() and (rime_api.get_user_data_dir() .. "/lua/sequence_" .. schema_id .. ".txt") or "lua/sequence_" .. schema_id .. ".txt")
end

local function get_user_db(schema_id)
    if not schema_id then return nil, function() end end
    
    -- 如果数据库连接已存在且正常，直接返回
    if _user_dbs[schema_id] and _user_dbs[schema_id]:loaded() then
        local function close()
            if _user_dbs[schema_id] and _user_dbs[schema_id]:loaded() then
                collectgarbage()
                _user_dbs[schema_id]:close()
            end
        end
        return _user_dbs[schema_id], close
    end
    
    -- 尝试重新打开或创建数据库（最多重试3次）
    local max_retries = 3
    local db = nil
    
    for i = 1, max_retries do
        -- 如果之前的连接存在但未加载，先关闭
        if _user_dbs[schema_id] then
            pcall(function() _user_dbs[schema_id]:close() end)
            _user_dbs[schema_id] = nil
        end
        
        -- 创建新连接
        db = LevelDb(get_db_file_name(schema_id))
        
        if db then
            -- 尝试打开
            local ok, err = pcall(function() db:open() end)
            if ok and db:loaded() then
                _user_dbs[schema_id] = db
                break
            end
        end
        
        -- 重试前稍作等待
        if i < max_retries then
            collectgarbage()
        end
    end
    
    local function close()
        if _user_dbs[schema_id] and _user_dbs[schema_id]:loaded() then
            collectgarbage()
            _user_dbs[schema_id]:close()
        end
    end

    return db, close
end

---@param value string LevelDB 中序列化的值
---@return { to_position: integer, updated_at: integer }
local function parse_adjustment_value(value)
    local result = {}

    local match = value:gmatch("[-.%d]+")
    result.to_position = tonumber(match());
    result.updated_at = tonumber(match());

    return result
end

---@param code string 当前输入码
---@param schema_id string 方案ID
---@return table<string, { to_position: integer, updated_at: integer, from_position?: integer, candidate?: Candidate}> | nil
local function get_adjustment(code, schema_id)
    if code == "" or code == nil then return nil end

    local db = get_user_db(schema_id)
    if not db then return nil end

    local accessor = db:query(code .. "|")
    if accessor == nil then return nil end

    local table = nil
    for key, value in accessor:iter() do
        -- "\002" 开头是自动调频记录（第二十轮新增），不属于手动调序，必须跳过。
        -- 否则自动调频的次数会被当成「手动把该词挪到第 N 位」，把候选拖回原处。
        if key:sub(1, 1) ~= "\002" then
            if table == nil then table = {} end
            local adjustment_key = string.match(key, "^.*|(%S+)$")
            table[adjustment_key] = parse_adjustment_value(value)
        end
    end

    ---@diagnostic disable-next-line: cast-local-type
    accessor = nil

    return table
end

local last_export_date = nil

local function get_today_date()
    local now = os.date("*t")
    return string.format("%04d%02d%02d", now.year, now.month, now.day)
end

local function should_auto_export(schema_id)
    if not _need_export[schema_id] then return false end
    local today = get_today_date()
    if last_export_date ~= today then
        last_export_date = today
        return true
    end
    return false
end

---@param code string 匹配的输入码
---@param adjust_key string | number 匹配键，为候选索引（命令模式），或候选词（普通模式）
---@param to_position integer | nil 目标位置，`nil` 为从数据库中移除该纪录
---@param timestamp? number 操作时间戳，默认去当前时间戳
---@param schema_id? string 方案ID
local function save_adjustment(code, adjust_key, to_position, timestamp, schema_id)
    if code == "" or code == nil then return end

    local db = get_user_db(schema_id)
    if not db then return end
    
    local key = string.format("%s|%s", code, adjust_key)
    local result = false

    if to_position == nil or to_position <= 0 then
        if type(adjust_key) == "number" then
            local user_adjustment = get_adjustment(code, schema_id)

            if user_adjustment == nil then return false end

            ---@type table{key: string, updated_at: number} | nil
            local erase_item = {}
            for db_key, db_value in pairs(user_adjustment) do
                if adjust_key + 1 == db_value.to_position
                    and (erase_item.updated_at == nil
                        or erase_item.updated_at < db_value.updated_at)
                then
                    erase_item.key = db_key
                    erase_item.updated_at = db_value.updated_at
                end
            end

            if erase_item.key ~= nil then
                _need_export[schema_id] = true
                result = db:erase(string.format("%s|%s", code, erase_item.key))
            end

            return result
        else
            _need_export[schema_id] = true
            result = db:erase(key)
        end
    else
        if not timestamp then
            timestamp = rime_api.get_time_ms
                and os.time() + tonumber(string.format("0.%s", rime_api.get_time_ms()))
                or os.time()
        end
        local value = string.format("%s\t%s", to_position, timestamp)
        _need_export[schema_id] = true
        result = db:update(key, value)
    end

    return result
end

---从 context 中获取当前排序匹配码
---@param context Context
---@return string
local function extract_adjustment_code(context)
    if is_function_mode_active(context) then
        return context:get_property("sequence_adjustment_code") or ""
    end

    return context.input:sub(1, context.caret_pos)
end

local function file_exists(name)
    local f = io.open(name, "r")
    return f ~= nil and io.close(f)
end

--- 统计数据库中有效条目数（排除系统元数据键）
---@param db LevelDB
---@return integer
local function count_db_entries(db)
    if not db or not db:loaded() then return 0 end
    local accessor = db:query("")
    if not accessor then return 0 end
    local count = 0
    for key, _ in accessor:iter() do
        -- "\001" = 内部标记；"\002" = 自动调频记录（第二十轮新增，不参与手动调序的导出/统计）
        if key:sub(1, 1) ~= "\001" and key:sub(1, 1) ~= "\002" then
            count = count + 1
        end
    end
    accessor = nil
    return count
end

--- 统计备份文件中有效条目数（排除注释行和空行，要求包含 tab 分隔符）
---@param schema_id string
---@return integer
local function count_txt_entries(schema_id)
    local filename = get_export_file_name(schema_id)
    if not filename then return 0 end
    local file = io.open(filename, "rb")
    if not file then return 0 end
    local content = file:read("*a")
    file:close()
    if content:sub(1, 3) == "\xef\xbb\xbf" then
        content = content:sub(4)
    end
    local count = 0
    for line in content:gmatch("[^\r\n]+") do
        if line:sub(1, 1) ~= "#" and line:match("\t") then
            count = count + 1
        end
    end
    return count
end

--- 导出调序数据到文件（返回导出条目数，若失败或被保护拒绝则返回 nil）
---@param db LevelDB
---@param schema_id string
---@return integer | nil
local function export_to_file(db, schema_id)
    -- 如果 schema_id 为 nil，则跳过导出
    if not schema_id then return nil end
    
    -- 如果数据库连接失败，跳过导出
    if not db or not db:loaded() then
        return nil
    end
    
    local sync_file_name = get_export_file_name(schema_id)
    if not sync_file_name then return nil end

    -- 【导出保护】统计备份文件条目数
    local txt_entries = count_txt_entries(schema_id)

    -- 【关键修复】只查询一次数据库，同时用于统计和写入，避免两次查询之间数据库状态变化
    local da = db:query("")
    if not da then return nil end

    -- 统计数据库条目数（同时收集数据）
    local db_entries = 0
    local export_data = {}
    for key, value in da:iter() do
        -- 只导出手动调序记录："\001" 是内部标记，"\002" 是自动调频（不进备份文件）
        if key:sub(1, 1) ~= "\001" and key:sub(1, 1) ~= "\002" then
            db_entries = db_entries + 1
            table.insert(export_data, {key = key, value = value})
        end
    end
    da = nil

    -- 【导出保护】如果备份存在且条目数 >= 数据库条目数，则拒绝覆盖
    if txt_entries > 0 and db_entries <= txt_entries then
        return nil
    end

    -- 开始导出，覆盖旧文件，使用二进制模式确保UTF-8 BOM正确写入
    local file = io.open(sync_file_name, "wb")
    if not file then return nil end

    -- 写入 UTF-8 BOM，确保工具能正确识别编码
    file:write("\xef\xbb\xbf")

    -- 获取当前Windows用户名
    local current_username = os.getenv("USERNAME") or "unknown1"

    -- 先写入当前用户ID行（使用 # 作为注释前缀，避免控制字符导致二进制识别）
    file:write(string.format("#/user_id\t%s\n", current_username))

    -- 写入收集的数据
    for _, item in ipairs(export_data) do
        local line = string.format("%s\t%s\n", item.key, item.value)
        file:write(line)
    end

    file:close()
    _need_export[schema_id] = false  -- 重置标记
    return db_entries
end

local function import_from_file(db, schema_id)
    -- 如果 schema_id 为 nil，则跳过导入
    if not schema_id then return false, 0 end
    
    -- 如果数据库连接失败，跳过导入
    if not db or not db:loaded() then
        return false, 0
    end
    
    -- 如果该方案已被清空，跳过自动导入
    if _cleared_schemas[schema_id] then
        return false, 0
    end
    
    local sync_file_name = get_export_file_name(schema_id)
    if not sync_file_name then return false, 0 end

    -- 使用二进制模式读取，处理 UTF-8 BOM
    local file = io.open(sync_file_name, "rb")
    if not file then
        return false, 0
    end

    -- 读取全部内容并处理 BOM
    local content = file:read("*a")
    file:close()
    
    -- 移除 UTF-8 BOM（如果存在）
    if content:sub(1, 3) == "\xef\xbb\xbf" then
        content = content:sub(4)
    end

    local import_count = 0

    -- 按行分割处理
    for line in content:gmatch("[^\r\n]+") do
        if line == "" then goto continue end

        -- 忽略系统元数据行（注释行以 # 开头）
        if line:sub(1, 1) == "#" then goto continue end

        -- 数据处理逻辑（保持不变）
        local key, value = string.match(line, "^(.-)\t(.+)$")
        if key and value then
            local code, phrase = string.match(key, "^(.+)|(.+)$")
            if not code or not phrase then goto continue end

            local info = parse_adjustment_value(value)
            local exist_value = db:fetch(key)
            if exist_value then -- 跳过旧的数据
                local exist_info = parse_adjustment_value(exist_value)
                if info.updated_at <= exist_info.updated_at then
                    goto continue
                end
            end

            import_count = import_count + 1
            save_adjustment(code, phrase, info.to_position, info.updated_at, schema_id)
        end

        ::continue::
    end

    _need_export[schema_id] = true  -- 导入后标记需要导出
    return true, import_count
end

--- 清空数据库
local function clear_database(schema_id)
    local db, close_db = get_user_db(schema_id)
    if not db or not db:loaded() then return end
    
    -- 遍历删除所有键
    local accessor = db:query("")
    if accessor then
        for key, _ in accessor:iter() do
            db:erase(key)
        end
        accessor = nil
    end
    
    close_db()
    
    -- 重新初始化数据库
    _user_dbs[schema_id] = nil
    get_user_db(schema_id)
    
    _need_export[schema_id] = false  -- 清除导出标记，防止退出时导出空数据覆盖备份
    _cleared_schemas[schema_id] = true  -- 设置清空标记，阻止自动导入
end

---执行排序调整
---@param context Context
---@param schema_id string 方案ID
local function process_adjustment(context, schema_id)
    local selected_cand = context:get_selected_candidate()

    if cur_adjust_offset == nil then -- 如果是重置/置顶，直接设置位置
        -- 非索引匹配的情况下，我们可以直接重置，提高效率
        local code = extract_adjustment_code(context)
        local adjustment_key = is_function_mode_active(context)
            and context.composition:back().selected_index
            or selected_cand.text
        save_adjustment(code, adjustment_key, in_pin_mode and 1 or nil, nil, schema_id)
    else -- 否则进入 filter 调整位移
        cur_adjustment_phrase = selected_cand.text
    end

    context:refresh_non_confirmed_composition()

    if context.highlight and cur_highlight_idx and cur_highlight_idx > 0 then
        context:highlight(cur_highlight_idx)
    end
end

-- ============================================================================
-- 【第二十轮 / 第二十一轮】自动调频（auto_freq）
--
-- 需求：手动调频（Ctrl+J/K/L/P、移动端数字键）保留，另加「打过的词自动往前排」。
--
-- 为什么不用 Rime 原生的 enable_user_dict：实测把它改成 true（用配置接口确认运行时
--   读到的确实是 true）后，既不生成 userdb、候选顺序也一字不变；中文路径与 ASCII
--   路径两个沙箱结果一致 ⇒ 这条路在本方案（Lua 过滤器多）走不通，只能自己实现。
--
-- 上屏捕获方式（第二十一轮定稿，实测）：
--   ★ 不要在组件 init() 里连 notifier —— 那时 context 还没就绪，回调一次都不会触发
--     （上一轮据此误判「commit_notifier 不可用」）。改到 P.func 首次运行时连接即可。
--   一次上屏分两步取信息：
--     select_notifier → context.input 还在，取「输入码」（此时 get_selected_candidate() 仍是 nil）
--     commit_notifier → 取「上屏词」（get_commit_text()，兜底 commit_history:back().text）
--     update_notifier → commit 之后必定触发，当场结算（不必等下一次按键）
--   覆盖：空格、数字键、分号/撇号（key_binder send 2/3）、commit_composition、
--         以及移动端点击候选栏（前端调 RimeSelectCandidate → Context::Select，与数字键同路径）。
-- ============================================================================

local AUTO_FREQ_MIN = 2            -- 同一个「编码+词」**连续**上屏几次才提前（2 = 连续两次才置顶）
local AUTO_FREQ_HOIST_MAX = 5      -- 单个编码一次最多提前几个词
local AUTO_FREQ_MAX_PER_CODE = 40  -- 单个编码最多保留多少条记录（防膨胀）
local AF_PREFIX = "\002af|"        -- 记录键前缀（\002 开头 ⇒ 与手动调序互不干扰）

local _af_stat = { calls = 0, commits = 0, writes = 0,
                   last_code = nil, last_word = nil, err = nil }
local _af_hooked = false
local _af_schema_id = nil
local _af_live_code = nil          -- 最新的完整输入码
-- ★★★ S92 重做：上屏检测从「commit_history 整队指纹」换成「本项目已实测的三判据」。
--
-- 【为什么必须换 —— 这才是「连打两次没反应」的真根因】
--   旧实现算指纹靠 `for e in context.commit_history:iter()`，
--   而 smart_assoc.lua 第 637 行早就实测写明：
--     · commit_history:iter() **不可用**（迭代出的是 std::reverse_iterator 结构体）
--     · commit_history.size 是**属性**不是方法
--     · commit_history:back() 可用
--   也就是说旧实现每次都走进 pcall 的退化分支，只剩 back().text 一个判据。
--   而 smart_assoc 同一段注释明确指出单判据的后果：
--     「只比末条文本，**队列满后连打同一个词会漏记**」
--   ——「连续两次上屏同一个词」恰好就是被这个缺陷吃掉的那一种输入，
--   所以用户怎么测都测不出来。（写入侧一直是好的：/txaf 能读到记录，
--   所以现象是「记录偶尔有、但顺序不变」，这也解释了为何难以复现。）
--
-- 【换成什么】
--   直接复用 smart_assoc 已验证的三判据：
--     ① size 变了      —— 常规新增
--     ② back().text 变了 —— 覆盖 size 读不到时的常规情形
--     ③ 输入码从非空变空 —— **关键补充**，覆盖队列满 + 连打同词
--   第 ③ 条正是旧实现唯一缺的那一条，也是本轮修复的核心。
local _af_last_size = nil          -- 上次结算时 commit_history.size
local _af_last_text = nil          -- 上次结算时 commit_history:back().text
local _af_prev_code = nil          -- 上一次 tick 时的输入码（判据 ③ 用）

-- ★ S96：判据③的闩锁「本轮输入码已经空过了」
--   必要原因见 af_tick 里S96 那段注释（一句话版：
--   af_tick 一次上屏会被触发多次，而 _af_prev_code 每次都被重写，
--   于是「非空→空」被反复检出，run 计数虚涨、AUTO_FREQ_MIN=2 形同虚设）。
local _af_empty_latched = false
-- 下面两个是「连续上屏」的记数器：只有连续 AUTO_FREQ_MIN 次上屏同一个「编码+词」才触发调频
local _af_run_key = nil            -- 上一条连续段的 key（code|word）
local _af_run_count = 0            -- 该 key 连续出现了几次
local _af_seq_hint = 0             -- 进程内已发出的最大序号（重启后从库里现取，避免序号回退）
local _af_last_hoist_sig = nil    -- ★ S93：上一次提权结果的签名（探针去重，防刷屏）

--- 取词：纯汉字串（可多字）才算，英文/数字/标点/空格一律不记
--- ⚠ 第二十一轮修掉的真 bug：旧正则 ^(\228[\128-\191][\128-\191]+)$ 只认**单字**
---   （第二个汉字的首字节是 0xE4~0xE9，不在 [\128-\191] 内），导致五笔重码里
---   最常见的词组（whnt 的「修改 / 个性」）全部被丢弃，功能形同不存在。
local function af_pick_word(text)
    if not text or text == "" then return nil end
    if #text > 24 then return nil end
    local rest = text:gsub("[\228-\233][\128-\191][\128-\191]", "")
    if rest ~= "" then return nil end
    return text
end

local function af_key(code, word)
    return AF_PREFIX .. code .. "|" .. word
end

--- 自动调频开关（schema 的 switches 里有 auto_freq，reset: 1 默认开）
local function af_enabled(context)
    local ok, v = pcall(function() return context:get_option("auto_freq") end)
    if not ok then return false end
    return v == true
end

--- 该编码下已发出的最大序号（序号越大 = 触发得越晚 = 排得越靠前）
local function af_max_seq(db, code)
    local mx = 0
    local acc = db:query(AF_PREFIX .. code .. "|")
    if acc then
        for _, v in acc:iter() do
            local s = tonumber(tostring(v):match("^T(%d+)")) or 0
            if s > mx then mx = s end
        end
        acc = nil
    end
    return mx
end

--- 记一次「这个编码下，这个词被**连续**上屏 ⇒ 触发调频」
---
--- 值格式："T<序号>"（序号越大 = 越晚触发 = 排得越靠前）。
---
--- ⚠ 第二十二轮改掉的真 bug：旧实现存的是「累计上屏次数」，而排序看的就是这个数，
---   于是：个性累计 2 次置顶 → 修改累计 2 次置顶（并列，按原序修改在前）→ 再打一次个性，
---   个性变 3 > 修改 2，**单次输入就把个性顶到第一**。用户要的是「必须连续两次才触发」，
---   所以现在改成：只有连续 AUTO_FREQ_MIN 次上屏同一个「编码+词」才写库，
---   单次上屏一个字都不写（数据不变 ⇒ 顺序自然不变）。
local function af_record(code, word, schema_id)
    if not code or code == "" or not word then return false end
    local db = get_user_db(schema_id)
    if not db or not db:loaded() then _af_stat.err = "数据库未加载"; return false end

    local key = af_key(code, word)
    local has = false
    local accessor = db:query(key)
    if accessor then
        for k, _ in accessor:iter() do if k == key then has = true end end
        accessor = nil
    end

    -- ★★★ S93 真根因修复：已存在的词**不再无条件刷新序号**。
    -- 【S93 要治的病 —— 「油箱 / 测试 轮流占据第一」】
    --   旧代码对已存在的词照样 `db:update(key, "T" .. (max+1))`，
    --   而读取侧 `af_apply` 是 `table.sort(picked, a.score > b.score)`（序号大者在前）
    --   ⇒ 合起来 = 「谁最后上屏谁就抢到第一」。
    --
    -- ★★★★★ S96 把这条规则从「一律不刷新」改成「不够高才抬」
    --   （S93 只治好了「轮流抢第一」，却顺手关掉了「重复上屏能往前挤」的能力）
    -- ★★★★★ S96 改写 S93 规则：不是「一律不刷新」，而是「不够高才抬」
    -- -------------------------------------------------------------------
    -- 【为什么 S93 的「已存在一律不刷新」必须改 —— S95 真机铁证】
    --   库内实测（af_probe.log，22:15）：
    --       HOIST code=[unta] 库内=[测试#17 油箱#16]
    --                ⇒ 前排=[测试#17(原第1) 测试#17(原第40) ... 油箱#16]
    --   `油箱` 的序号 **16 比 `测试` 的 17 小** ⇒ 油箱永远排在第二。
    --   而 S93 规则让它**永久冻结在 16** ⇒ 用户「连续上屏油箱多少次」
    --   都追不上 17 ⇒ 用户报告「调频坏了，多次重复上屏也无法调至第一候选」。
    --
    -- 【S93 当初为什么要「不刷新」—— 不能推翻它，只能补上缺口】
    --   S93 要治的是「油箱 / 测试 轮流抢第一」。
    --   成因是：旧代码对已存在的词也 `update(key, "T"..max+1)`，
    --   于是**谁最后上屏谁就抢到第一**。
    --   ⚠ 但 S93 只解决了「A 让位给 B」，
    --     完全没解决「B 想从第三candidate 往前挤却挤不动」。
    --   真正的设计意图（见本文件头部）是：
    --     「提前后一直保持在前面，**直到同一个编码下有别的词**
    --       也连续两次上屏，后者排到更前面」
    --   ⇒ 语义是「**达标就该排到最前**」，不是「达标后就被冻结」。
    --   S93 把「别反复刷序号」实现成了「永远不刷新」，
    --   顺手把「能往前挤」这个能力也一起关掉了 —— 那是实现过头，不是设计意图。
    --
    -- 【S96 的规则：抬到「本编码当前最高序号 + 1」，仅当确实不够高时】
    --   · 已是最高（如油箱=16 而测试=17 时，油箱再上屏 → 抬到 18）⇒ 提权成功
    --   · 已是最高且连续上屏 → 不动（每次都抬会退化成 S93 要治的「轮流抢第一」）
    --   ⇒ 同时满足两个诉求：**不轮流抢第一** + **重复上屏能真正提权**
    if has then
        -- ⚠ 读原值只能用 db:query()（本项目已实测可用的唯一读法）。
        --   不用 db:get() —— 那个 API 在本 librime 上从未被验证过。
        local oldseq = nil
        pcall(function()
            local acc2 = db:query(key)
            if acc2 then
                for k2, v2 in acc2:iter() do
                    if k2 == key then oldseq = tonumber(tostring(v2):match("%d+")) end
                end
                acc2 = nil
            end
        end)
        local cur_max = af_max_seq(db, code)
        if oldseq ~= nil and oldseq >= cur_max then
            -- 已经是本编码最前 ⇒ 不动，避免退化成「谁最后上屏谁抢第一」
            af_probe(string.format("AFREC 已存在·已最前·不刷新 rk=[%s] 原值=%d max=%d",
                                   tostring(key), oldseq, cur_max))
            _af_stat.err = nil
            return false
        end
        -- 不够高 ⇒ 抬到最前
        local ns = cur_max + 1
        if ns <= _af_seq_hint then ns = _af_seq_hint + 1 end
        _af_seq_hint = ns
        local oku = pcall(function() db:update(key, "T" .. ns) end)
        af_probe(string.format("AFREC 已存在·抬到最前 rk=[%s] %s→%d (max=%d) ok=%s",
                               tostring(key), tostring(oldseq), ns, cur_max, tostring(oku)))
        _af_stat.err = nil
        return true
    end

    -- 新词且该编码已达上限 ⇒ 不再扩表
    local n = 0
    local acc = db:query(AF_PREFIX .. code .. "|")
    if acc then
        for _ in acc:iter() do n = n + 1 end
        acc = nil
    end
    if n >= AUTO_FREQ_MAX_PER_CODE then return false end

    local seq = af_max_seq(db, code) + 1
    if seq <= _af_seq_hint then seq = _af_seq_hint + 1 end   -- 防止清库后序号回退
    _af_seq_hint = seq
    db:update(key, "T" .. seq)
    _af_stat.err = nil
    return true
end

---
--- 如何判断「发生了一次新的上屏」（第二十二轮定案）：
---   看 context.commit_history（提交历史队列，**上限 20 条**）的**整队指纹**：
---     指纹 = 条数 + 全部文本拼起来；指纹变了 ⇒ 有新上屏，没变 ⇒ 没有。
---
---   ⚠ 为什么不用「条数 + 末条文本」（第二十一轮的方案，已证伪）：
---     队列满 20 条之后条数不再增长，此时**连续两次上屏同一个词**，
---     条数没变、末条文本也没变 ⇒ 第二次上屏被当成「没有新上屏」吞掉。
---     而这正是自动调频最核心的场景（连打两次同一个词）⇒ 队列一满调频就失效。
---     用整队指纹后，只要不是「20 条文本全都一样」，新上屏都能被检出。
---
---   这套判据的好处是**不需要知道用户是用什么方式上屏的** —— 空格、数字键、
---   分号/撇号（key_binder send 2/3）、commit_composition、移动端点击候选栏，
---   最终都只是往这个队列里 push 一条，于是天然只结算一次，也不会把
---   「Esc 放弃输入」「命令模式清屏」误当成上屏（这两种都不会动队列）。
---
--- ⚠ 为什么不用 select/commit_notifier（实测）：
---   本 librime 版本下这两个 notifier **只对数字键触发**；空格与分号（`send: 2`）
---   提交时**不触发**（/txzj 显示 上屏=[修改] 正确，但「选中 / 上屏」计数不涨）。
---   ⇒ notifier 只留作 /txzj 的诊断计数，真正的记录一律走这里。
-- ★★★ S93 新增：自动调频专项探针。
-- 【为什么必须单独写一个文件，而不是复用 smart_assoc 的 probe】
--   smart_assoc 的 probe 变量是 local，本文件看不见；
--   而本文件（super_sequence）才是「上屏结算 + 写库 + 提权」的唯一所在地，
--   用户反馈的三种现象（点选上屏 / 空格上屏 / 收起键盘）全部在这里分叉。
-- 【探针只读，不改任何状态】—— 绝不能因为「加探针」本身影响被测行为
--   （S92 教训：为了一个不存在的功能加了一整套共享标志）。
-- ★ S100 基线版：关掉（<｜hy_place▁holder▁no▁813｜> smart_assoc.lua 的 PROBE_ON 一起）。
--   排错版本把下一行改回 true 重新打包即可。
local AF_PROBE_ON = false
local _af_probe_path = nil
local _af_probe_tried = false

local function af_probe(msg)
    if not AF_PROBE_ON or not _af_probe_path then return end
    pcall(function()
        local f = io.open(_af_probe_path, "a")
        if f then
            local ts = "?"
            pcall(function() ts = os.date("%H:%M:%S") end)
            f:write("[" .. ts .. "] AFTICK " .. tostring(msg) .. "\n")
            f:close()
        end
    end)
end

--- 在 P.init 里挑一个能写的路径（与 smart_assoc 同一套回退顺序）
local function af_probe_init(env)
    if _af_probe_tried or not AF_PROBE_ON then return end
    _af_probe_tried = true
    local base = ""
    pcall(function()
        if rime_api and rime_api.get_user_data_dir then
            base = rime_api.get_user_data_dir() or ""
        end
    end)
    if base == "" then
        pcall(function()
            local sd = env and env.engine and env.engine.schema
                       and env.engine.schema.schema_dir or ""
            base = sd:match("^(.+[/\\])") or ""
        end)
    end
    if base ~= "" and not base:match("[/\\]$") then base = base .. "/" end
    for _, p in ipairs({ base .. "log/af_probe.log", base .. "af_probe.log",
                         "log/af_probe.log", "af_probe.log" }) do
        local ok, f = pcall(io.open, p, "a")
        if ok and f then
            pcall(function() f:close() end)
            _af_probe_path = p
            break
        end
    end
    af_probe("==== af probe start ==== path=" .. tostring(_af_probe_path))
end

--- 记一次「结算」—— src 说明是谁触发的这次 af_tick
---   key  = P.func 每次按键都会走
--   ntf  = update_notifier（点选候选栏时前端调 Select，走这里）
local function af_tick(context, schema_id, src)
    if not context then return end
    _af_stat.tick = (_af_stat.tick or 0) + 1

    local code = context.input:sub(1, context.caret_pos)

    -- ① 先结算新上屏：此时 _af_live_code 还是「上屏那一刻」的输入码。
    --    顺序不能反 —— 上屏后 composition 已清空，若先把新的输入码写进去，
    --    补记（移动端点击后没有 update 事件，只能在下次按键时结算）就会记错码。
    --
    -- ★★★ S92：换成 smart_assoc.lua 已实测的 size(属性) + back() + 输入码变空 三判据。
    --   旧代码用 commit_history:iter() 算整队指纹，实测该 API 在本 librime 上不可用
    --   （详见 _af_last_size 一组变量的注释），于是每次都退化成单判据，
    --   而那恰好漏掉「连续上屏同一个词」—— 本功能唯一的触发条件。
    local size, text
    pcall(function() size = context.commit_history.size end)
    pcall(function()
        local e = context.commit_history:back()
        text = e and e.text
    end)

    local fresh = false
    local why = ""
    -- 判据 ①：条数变了（常规新增）
    if size ~= nil and _af_last_size ~= nil and size ~= _af_last_size then
        fresh = true
        why = "J1size"
    end
    -- 判据 ②：末条文本变了
    if not fresh and text ~= nil and text ~= _af_last_text then
        fresh = true
        why = "J2text"
    end
    -- 判据 ③（本轮补上的关键一条）：输入码从非空变空 = 刚发生了上屏。
    --   覆盖「队列已满 + 连打同一个词」—— 此时 size 与 back().text 都没变，
    --   旧实现完全看不见这次上屏，所以「连续两次」永远攒不起来。
    --
    -- ★★★★★ S96：这一条必须加闩锁 `_af_empty_latched`
    -- -------------------------------------------------------------------
    -- 【S95 真机日志的病态序列（同一个编码 unta，22:14:32~ 22:14:59）】
    --     run=1/2 → run=3/2 → run=5/2 → run=7/2 → run=9/2
    --   而这段时间用户**只上屏了两次**「测试」，其余全是空更新。
    --   根因：`af_tick` 一次上屏会被触发**多次**
    --   （src=ntf 是 update_notifier、src=key 是 P.func），
    --   而 `_af_prev_code` 在 980 行**每次 af_tick 都被重写**。
    --   ⇒ 「输入码从非空变空」这个状态在同一次上屏内被反复检出
    --   ⇒ `fresh=true` 反复成立 ⇒ `run` 一路虚涨到 9
    --   ⇒ AUTO_FREQ_MIN=2 这道门槛在第一次上屏后就被永久跨过
    --   ⇒ 「连续上屏两次才调频」这个语义彻底失效。
    --   而真正的伤害在下游：`run` 达标后会调`af_record`，
    --   而 S93 规则「已存在则不刷新序号」又让写入变成空操作
    --   ⇒ 用户看到的就是「反复上屏多少次，调频都没反应」。
    --
    -- 【闩锁的解除】输入码一旦**重新变成非空**就解锁
    --   （用户开始打下一个词= 一次新的上屏周期已经开始）。
    if code ~= "" then
        _af_empty_latched = false
    end
    if not fresh and not _af_empty_latched
        and _af_prev_code ~= nil and _af_prev_code ~= ""
        and code == "" then
        fresh = true
        why = "J3empty"
        -- ★ S96：立刻上闩 —— 同一次「变空」只认第一次。
        --   ⚠ 绝不能靠 `code == ""` 本身来防重复：af_tick 每次都重写
        --     _af_prev_code，下一次进来 _af_prev_code 已经是 ""，
        --     判据靠的是「上一轮非空」，所以必须自己记住「已经空过了」。
        _af_empty_latched = true
        -- ★★★ S93：删掉 `text = _af_last_text` 这行兜底。
        -- 【为什么它是错的 —— 它会伪造本次上屏的词】
        --   旧代码：back() 取不到就拿**上一次结算的词**当成本次上屏的词。
        --   但「取不到」有三种完全不同的原因，只有一种能这么补：
        --     · 队列满 + 连续上屏**同一个**词 ⇒ back() 返回的就是那个词
        --       （本来就正确，text == _af_last_text，那次赋值是空操作）
        --     · back() 暂时取不到（时序）⇒ 此刻**根本不知道**上屏了什么
        --     · back() 返回的是**上一条**（本次还没挤进队列）⇒ 拿到的是别人的词
        --   后两种情况下把 _af_last_text 记成「本次上屏的词」，
        --   等于给一个**没被上屏的词**补了一次连续计数
        --   ⇒ 它平白攒够两次而被调频提权 ⇒ 表现为「莫名其妙的词轮流抢第一」。
        --   宁可漏记（用户会再打一次就补上），也不能记错：
        --   记错的代价是把不该置顶的词永久顶到最前，且用户无法预期。
        --
        --   判据③ 本身必须保留 —— 它负责「检出这次上屏发生了」，
        --   而 S92 要解决的「队列满 + 连打同词」在那种情况下 back() 是准的。
    end
    _af_prev_code = code

    if not fresh then
        -- 没有新上屏 ⇒ 只维护输入码
        if code ~= "" then _af_live_code = code end
        return
    end
    _af_last_size = size
    _af_last_text = text
    _af_stat.settle = (_af_stat.settle or 0) + 1
    _af_stat.last_code = _af_live_code
    _af_stat.last_word = text

    -- ② 再维护输入码，供下一次上屏使用
    if code ~= "" then _af_live_code = code end

    -- ★★★ S93 探针：每一次「结算」都打一行。
    --   目的：把用户反馈的三条路径（点选候选栏 / 空格上屏 / 收起键盘再弹出）
    --   在日志里彻底分开 —— 之前只能靠推测，因为三者都落到同一段代码。
    --   注意 text=nil 时**不写库**（见下面的 return），日志里能直接看出来。
    af_probe(string.format(
        "SETTLE src=%s why=%s code=[%s] live=[%s] text=[%s] run=%s/%d prevRun_key=[%s]",
        tostring(src or "?"), why, tostring(code), tostring(_af_live_code),
        tostring(text), tostring(_af_run_count), AUTO_FREQ_MIN,
        tostring(_af_run_key)))

    if not text or text == "" then return end

    local word = af_pick_word(text)
    local c = _af_stat.last_code
    if not word or not c or c == "" then
        -- 非纯汉字（英文/数字/标点/命令回显）或拿不到输入码 ⇒ 打断连续段
        af_probe("  BREAK 非汉字或无码 word=[" .. tostring(text) .. "] code=[" .. tostring(c) .. "]")
        _af_run_key, _af_run_count = nil, 0
        _af_stat.run = 0
        return
    end
    -- 命令模式 / 反查 / 计算器 的上屏不记（它们不是「这个编码的候选」）
    local h = c:sub(1, 1)
    if h == "/" or h == "z" or h == "@" or h == "=" then
        af_probe("  BREAK 命令类编码 code=[" .. tostring(c) .. "]")
        _af_run_key, _af_run_count = nil, 0
        _af_stat.run = 0
        return
    end

    -- 【必须连续两次】同一个「编码+词」连续上屏第 2 次（及以上）才写库；
    -- 中途上屏了别的词 ⇒ 连续段重新从 1 数起；只上屏 1 次 ⇒ 一个字节都不写。
    local rk = c .. "|" .. word
    if rk == _af_run_key then
        _af_run_count = _af_run_count + 1
    else
        _af_run_key, _af_run_count = rk, 1
    end
    _af_stat.run = _af_run_count
    if _af_run_count < AUTO_FREQ_MIN then
        af_probe("  SKIP 未达连续次数 rk=[" .. tostring(rk) .. "] run="
                 .. tostring(_af_run_count) .. "/" .. tostring(AUTO_FREQ_MIN))
        return
    end

    local ok = af_record(c, word, schema_id or _af_schema_id)
    -- ★ 记录「这次到底有没有真的改到库」——
    --   S93 改动后，已存在的词会返回 false（不再刷新序号），
    --   这两种结果在日志里必须能分开，否则又会出现
    --   「代码按预期执行了，但用户的现象另有原因」这种误判。
    af_probe("  RECORD rk=[" .. tostring(rk) .. "] run=" .. tostring(_af_run_count)
             .. " 写库=" .. tostring(ok))
    if ok then
        _af_stat.writes = _af_stat.writes + 1
    end
end

-- 以下两个回调只做诊断计数（/txzj 里看「选中 / 上屏」是否在涨），不负责记录
local function af_on_select(ctx)
    _af_stat.calls = _af_stat.calls + 1
end

local function af_on_commit(ctx)
    _af_stat.commits = _af_stat.commits + 1
end

local function af_on_update(ctx)
    -- ★ S93：src="ntf" —— 移动端**点选候选栏**时前端调 Context::Select，
    --   不经过 P.func 的按键路径，只走 update_notifier。
    --   这正是用户反馈「点候选栏上屏会中断循环」的探针抓手：
    --   日志里 src=ntf 与 src=key 分开，就能看清两条路径的差别。
    local ok, err = pcall(af_tick, ctx, _af_schema_id, "ntf")
    if not ok then _af_stat.err = tostring(err) end
end

--- 在 P.func 首次拿到 context 时连接 notifier（init 阶段 context 未就绪，连了也不触发）
local function af_hook(env)
    local ctx = env and env.engine and env.engine.context
    if not ctx then return end
    local sid = env.engine and env.engine.schema and env.engine.schema.schema_id
    -- 切换方案时（schema_id 变了）要重新连：否则回调仍指向上一个方案的 context
    if _af_hooked and sid == _af_schema_id then return end
    _af_schema_id = sid
    -- 切换方案 ⇒ 「连续上屏」的记数器作废（不同方案的同名词不算连续）
    _af_run_key, _af_run_count = nil, 0
    _af_stat.run = 0

    pcall(function()
        if ctx.select_notifier then
            ctx.select_notifier:connect(function(c) pcall(af_on_select, c) end)
        end
        if ctx.commit_notifier then
            ctx.commit_notifier:connect(function(c) pcall(af_on_commit, c) end)
        end
        if ctx.update_notifier then
            ctx.update_notifier:connect(function(c) pcall(af_on_update, c) end)
        end
    end)
    _af_hooked = true
end

--- 把学过的词提到最前（在 S 过滤器里应用 ⇒ 之后的 F 手动调序永远覆盖它）
local function af_apply(list, code, schema_id)
    local n = #list
    if n <= 1 or not code or code == "" then return end

    local db = get_user_db(schema_id)
    if not db or not db:loaded() then return end

    local scores = {}
    local stale = {}
    _af_stat.last_dump, _af_stat.dump_n = nil, 0
    _af_stat.dump_code = code
    local accessor = db:query(AF_PREFIX .. code .. "|")
    if not accessor then return end
    local pfx = AF_PREFIX .. code .. "|"
    local head = #pfx
    for k, v in accessor:iter() do
        if k:sub(1, head) == pfx then                 -- 防御：确认是「本编码」的记录
            local s = tonumber(tostring(v):match("^T(%d+)"))
            if s then
                scores[k:sub(head + 1)] = s
            else
                -- 旧格式（存的是累计次数）⇒ 本次升级后一律作废，免得残留旧顺序
                stale[#stale + 1] = k
            end
        end
    end
    accessor = nil
    for _, k in ipairs(stale) do db:erase(k) end
    if not next(scores) then return end

    -- 自检用：本编码下已调频的词（按序号从新到旧）
    local dump = {}
    for w, s in pairs(scores) do dump[#dump + 1] = { w = w, s = s } end
    table.sort(dump, function(a, b) return a.s > b.s end)
    local parts = {}
    for i = 1, math.min(6, #dump) do parts[i] = dump[i].w .. "#" .. dump[i].s end
    _af_stat.last_dump = table.concat(parts, " ")
    _af_stat.dump_n = #dump

    local picked = {}
    for i, c in ipairs(list) do
        local s = scores[c.text]
        if s then picked[#picked + 1] = { idx = i, score = s, cand = c } end
    end
    if #picked == 0 then return end

    -- 最近触发的排最前（序号大 = 触发晚）；序号唯一，排序结果稳定
    table.sort(picked, function(a, b) return a.score > b.score end)
    if #picked > AUTO_FREQ_HOIST_MAX then
        local tmp = {}
        for i = 1, AUTO_FREQ_HOIST_MAX do tmp[i] = picked[i] end
        picked = tmp
    end

    local moved = {}
    for _, p in ipairs(picked) do moved[p.cand.text] = true end
    -- ★★★ S93 探针：把「谁被提到第几」写清楚。
    --   用户看到的「油箱和测试轮流在第一位」就是这里的排序结果，
    --   有了这行就能直接判定：是库里的 seq 变了，还是排序逻辑有问题。
    -- ⚠ 必须去重：af_apply 在 S 过滤器里，**每次按键**都会跑一遍，
    --   同一编码连打 5 个键就会重复 5 次同一行 ⇒ 日志瞬间被刷爆、
    --   真正的变化被埋掉。这里只在「前排结果与上次不同」时才记。
    do
        local ord = {}
        for i, p in ipairs(picked) do
            ord[i] = string.format("%s#%d(原第%d)", p.cand.text, p.score, p.idx)
        end
        local sig = tostring(code) .. "|" .. table.concat(ord, " ")
        if sig ~= _af_last_hoist_sig then
            _af_last_hoist_sig = sig
            af_probe(string.format("HOIST code=[%s] 库内=[%s] ⇒ 前排=[%s]",
                                   tostring(code), _af_stat.last_dump,
                                   table.concat(ord, " ")))
        end
    end
    local rest = {}
    for _, c in ipairs(list) do
        if not moved[c.text] then rest[#rest + 1] = c end
    end

    local k = 0
    for _, p in ipairs(picked) do k = k + 1; list[k] = p.cand end
    for _, c in ipairs(rest) do k = k + 1; list[k] = c end
end

--- 只清空自动调频记录（手动调序不受影响）
local function af_clear(schema_id)
    local db = get_user_db(schema_id)
    if not db or not db:loaded() then return 0 end
    local keys = {}
    local accessor = db:query(AF_PREFIX)
    if accessor then
        for k, _ in accessor:iter() do keys[#keys + 1] = k end
        accessor = nil
    end
    for _, k in ipairs(keys) do db:erase(k) end
    _af_stat.writes = 0
    _af_run_key, _af_run_count = nil, 0
    _af_stat.run = 0
    _af_stat.last_dump = nil
    _af_stat.dump_n = 0
    return #keys
end

local P = {}
function P.init(env)
    local schema_id = env and env.engine and env.engine.schema and env.engine.schema.schema_id
    local db = get_user_db(schema_id)
    import_from_file(db, schema_id)
    -- ★ S93：探针初始化（只做一次；纯追加写，不改任何输入行为）
    af_probe_init(env)
end

-- P 阶段按键处理
---@param key_event KeyEvent
---@param env Env
---@return ProcessResult
function P.func(key_event, env)
    local context = env.engine.context

    -- 【自动调频】首次拿到 context 时连接 notifier（init 阶段 context 未就绪）
    af_hook(env)

    if key_event:release() then
        return RIME_PROCESS_RESULTS.kNoop
    end

    -- 【自动调频】状态推进：维护输入码 / 记录上屏（每次按键都走一次）
    --   src="key"：这是按键路径。空格上屏也走这里。
    af_tick(context, env.engine and env.engine.schema and env.engine.schema.schema_id, "key")

    -- 移动端数字键调序（PC端数字正常上屏）
    if MOBILE_MODE and context:has_menu() then
        -- ★★★ S91 更正：判据彻底换掉。
        -- 【为什么不能再用锁存标志】
        --   原判据 `_G.__touchwb_assoc_seg` 由 smart_assoc 在按键开头「现场判定」后写入，
        --   本身是准的。但本函数读它时，**按键已经流过 smart_assoc*P**，
        --   而那里对联想段的数字键做了 commit + `return 1`（吞掉）
        --   ⇒ 本函数**根本收不到联想段的数字键** ⇒ 这里的联想段分支形同虚设。
        --   更危险的是：标志一旦为真而按键没被吞（比如联想段无候选菜单时），
        --   就会把**正常打字**的下滑数字也一起放行 ⇒ 落到 selector ⇒ 顶候选上屏。
        --   —— 这正是用户实测的「无论哪种候选栏，下滑数字都直接上屏候选」。
        --
        -- 【S91 的正确做法：不再问「是不是联想段」，而是问「输入码是不是空的」】
        --   · 输入码非空 ⇒ 用户在打码 ⇒ 下滑数字 = 调序（保留本函数的原逻辑）
        --   · 输入码为空   ⇒ 上屏后的联想段 ⇒ 下滑数字该直接上屏
        --     但这个键已被 smart_assoc*P 吞掉并 commit 过了，本函数走不到这里；
        --     万一走到（时序兜底），也必须放行，绝不能拿去调序。
        local input_text = context.input:sub(1, context.caret_pos)
        if input_text == "" then
            return RIME_PROCESS_RESULTS.kNoop
        end

        -- 计算器模式（=开头）不拦截数字键
        if input_text:find("^=") then
            return RIME_PROCESS_RESULTS.kNoop
        end

        local keycode = key_event.keycode

        -- 数字键 1：撤销上次调序（移动端下滑数字）
        if keycode == 0x31 then
            pin_candidate_index = 1  -- 1 表示撤销
            context:refresh_non_confirmed_composition()
            return RIME_PROCESS_RESULTS.kAccepted
        end

        -- 数字键 2-9：有候选菜单时前移对应候选
        if keycode >= 0x32 and keycode <= 0x39 then
            pin_candidate_index = keycode - 0x30  -- 1-indexed
            context:refresh_non_confirmed_composition()
            return RIME_PROCESS_RESULTS.kAccepted
        end

        -- 数字键 0：前移第10候选
        if keycode == 0x30 then
            pin_candidate_index = 10
            context:refresh_non_confirmed_composition()
            return RIME_PROCESS_RESULTS.kAccepted
        end
    end

    if not context:has_menu() then
        return RIME_PROCESS_RESULTS.kNoop
    end

    local selected_cand = context:get_selected_candidate()
    if selected_cand == nil or selected_cand.text == nil then
        return RIME_PROCESS_RESULTS.kNoop
    end

    -- 桌面端：Ctrl+J/K/L/P（保留原有行为）
    if key_event:ctrl() then
        if is_function_mode_active(context)
            and not context:get_property("sequence_adjustment_code")
        then
            return RIME_PROCESS_RESULTS.kNoop
        end

        local kc = key_event.keycode   -- 修复：在此处定义局部变量，避免与移动端 keycode 作用域混淆
        in_pin_mode = kc == 0x70
        if kc == 0x6A then
            cur_adjust_offset = -1
        elseif kc == 0x6B then
            cur_adjust_offset = 1
        elseif kc == 0x6C then
            cur_adjust_offset = nil
        elseif in_pin_mode then
            cur_adjust_offset = nil
        else
            return RIME_PROCESS_RESULTS.kNoop
        end

        if cur_adjust_offset == 0 then
            return RIME_PROCESS_RESULTS.kNoop
        end

        local schema_id = env.engine and env.engine.schema and env.engine.schema.schema_id
        process_adjustment(context, schema_id)
        return RIME_PROCESS_RESULTS.kAccepted
    end

    return RIME_PROCESS_RESULTS.kNoop
end

local F = {}
function F.init() end

function F.fini()
    local schema_id = current_schema_id
    
    if _need_export[schema_id] then
        local db = get_user_db(schema_id)
        export_to_file(db, schema_id)
    end
    
    local _, close_db = get_user_db(schema_id)
    close_db()
    
    cur_adjustment_phrase = nil
    cur_highlight_idx = nil
    cur_adjust_offset = 0
    in_pin_mode = false
    pin_candidate_index = nil
    last_adjustment = nil
    mobile_candidate_order = {}
    current_schema_id = nil
end

---@param input Translation
---@param env Env
function F.func(input, env)
    local context = env.engine.context
    local schema_id = env.engine and env.engine.schema and env.engine.schema.schema_id
    current_schema_id = schema_id
    
    -- 处理清空数据库指令（生成空候选）
    if env.engine.context.input == "/txqk" then
        clear_database(schema_id)
        yield(Candidate("clear_db", 0, #context.input, "※ 当前方案调序数据库已清空（备份保留）", ""))
        return
    end

    -- 【自动调频】/txzq 调序自动清：只清空自动调频记录（手动调序不受影响）
    if env.engine.context.input == "/txzq" then
        local n = af_clear(schema_id)
        yield(Candidate("clear_af", 0, #context.input,
                        string.format("※ 自动调频记录已清空（%d 条，手动调序保留）", n), ""))
        return
    end

    -- 【自动调频】/txzj 调序自动检：开关 / 连续次数 / 本码已调频词
    if env.engine.context.input == "/txzj" then
        local on = af_enabled(context)
        -- 直接读上屏历史：不管走的是哪条捕获路径，都能看到「刚才到底上屏了什么」
        local chb
        pcall(function()
            local e = context.commit_history:back()
            chb = e and e.text
        end)
        yield(Candidate("af_debug", 0, #context.input,
                        string.format("※ 自动调频%s 连续%d/%d 码[%s]已调频%d词[%s] 末次结算=[%s] 队尾=[%s] 写库%d %s",
                                      on and "开" or "关",
                                      _af_stat.run or 0, AUTO_FREQ_MIN,
                                      tostring(_af_stat.dump_code),
                                      _af_stat.dump_n or 0,
                                      tostring(_af_stat.last_dump),
                                      tostring(_af_stat.last_word),
                                      tostring(chb),
                                      _af_stat.writes,
                                      _af_stat.err and ("异常=" .. tostring(_af_stat.err)) or ""), ""))
        return
    end
    
    -- 处理手动导出指令（导出到文本文件）
    if env.engine.context.input == "/txdc" then
        local db = get_user_db(schema_id)
        if not db or not db:loaded() then
            yield(Candidate("export_db", 0, #context.input, "※ 导出失败：数据库连接失败", ""))
            return
        end
        
        -- 1. 统计数据库有效条目数
        local accessor = db:query("")
        local db_entries = 0
        if accessor then
            for key, _ in accessor:iter() do
                if key:sub(1, 1) ~= "\001" then
                    db_entries = db_entries + 1
                end
            end
            accessor = nil
        end
        
        -- 2. 统计备份文件条目数
        local txt_entries = count_txt_entries(schema_id)
        
        -- 3. 预先判断保护条件，直接提示（避免依赖 export_to_file 返回值）
        if txt_entries > 0 and db_entries <= txt_entries then
            yield(Candidate("export_db", 0, #context.input, "※ 导出失败：已有有效备份，请先执行 /txdr 恢复", ""))
            return
        end
        
        -- 4. 执行实际导出（此时允许覆盖）
        local count = export_to_file(db, schema_id)
        if count == nil then
            yield(Candidate("export_db", 0, #context.input, "※ 导出失败：未知错误", ""))
        elseif count > 0 then
            yield(Candidate("export_db", 0, #context.input, "※ 成功导出 " .. count .. " 条数据", ""))
        else
            yield(Candidate("export_db", 0, #context.input, "※ 导出失败：当前数据库无调序数据", ""))
        end
        return
    end
    
    -- 处理手动导入指令（从文本文件恢复）
    if env.engine.context.input == "/txdr" then
        local db = get_user_db(schema_id)
        -- 手动导入时临时清除清空标记，允许导入
        local was_cleared = _cleared_schemas[schema_id]
        _cleared_schemas[schema_id] = nil
        
        local success, count = import_from_file(db, schema_id)
        if success and count and count > 0 then
            yield(Candidate("import_db", 0, #context.input, "※ 成功导入 " .. count .. " 条数据", ""))
        elseif success and count == 0 then
            yield(Candidate("import_db", 0, #context.input, "※ 导入（无新记录）", ""))
        else
            -- 导入失败，恢复清空标记
            if was_cleared then
                _cleared_schemas[schema_id] = true
            end
            yield(Candidate("import_db", 0, #context.input, "※ 导入失败：备份不存在或无数据", ""))
        end
        return
    end
    
    -- 处理调序统计指令（查看所有调序数据）
    if env.engine.context.input == "/txtj" then
        local db = get_user_db(schema_id)
        if not db or not db:loaded() then
            yield(Candidate("query_db", 0, #context.input, "※ 调序统计：数据库连接失败", ""))
            return
        end
        
        local all_phrases = {}
        local seen = {}
        
        local accessor = db:query("")
        if accessor then
            for key, _ in accessor:iter() do
                -- "\001" 是内部标记，"\002" 是自动调频记录，都不属于手动调序统计
                if key:sub(1, 1) ~= "\001" and key:sub(1, 1) ~= "\002" then
                    local phrase = key:match("^.-|(.+)$")
                    if phrase and not seen[phrase] then
                        seen[phrase] = true
                        table.insert(all_phrases, {phrase = phrase, source = "db"})
                    end
                end
            end
            accessor = nil
        end
        
        local sync_file_name = get_export_file_name(schema_id)
        if sync_file_name then
            local file = io.open(sync_file_name, "rb")
            if file then
                local content = file:read("*a")
                file:close()
                if content:sub(1, 3) == "\xef\xbb\xbf" then
                    content = content:sub(4)
                end
                for line in content:gmatch("[^\r\n]+") do
                    if line:sub(1, 1) ~= "#" then
                        local key = string.match(line, "^(.-)\t")
                        if key then
                            local phrase = key:match("^.-|(.+)$")
                            if phrase and not seen[phrase] then
                                seen[phrase] = true
                                table.insert(all_phrases, {phrase = phrase, source = "file"})
                            end
                        end
                    end
                end
            end
        end
        
        local count = #all_phrases
        if count == 0 then
            yield(Candidate("query_db", 0, #context.input, "※ 调序统计：当前无调序数据", ""))
        else
            local lines = {}
            for i, item in ipairs(all_phrases) do
                local tag = item.source == "file" and "〔备份〕" or ""
                table.insert(lines, string.format("%d. %s %s", i, item.phrase, tag))
            end
            local header = "=== 调序统计 ===\n共 " .. count .. " 条记录（含备份）\n------------------------\n"
            local content = header .. table.concat(lines, "\n")
            yield(Candidate("query_db", 0, #context.input, content, "按空格上屏"))
        end
        return
    end
    
    -- 命令模式（/开头）和 z 键反查模式：直接输出所有候选，跳过排序和去重处理
    local input_text = context.input:sub(1, context.caret_pos)
    if input_text:find("^/") or input_text:find("^z") or input_text:find("^@") then
        for cand in input:iter() do
            yield(cand)
        end
        return
    end

    -- 次日第一次打字自动导出调序数据（受保护）
    if should_auto_export(schema_id) then
        local db = get_user_db(schema_id)
        export_to_file(db, schema_id)
    end

    -- 处理数字键调序操作（移动端下滑数字）
    -- pin_candidate_index = 1: 撤销, 2-10: 前移对应候选
    if pin_candidate_index then
        local pin_idx = pin_candidate_index
        pin_candidate_index = nil

        local code = extract_adjustment_code(context)
        local is_func_mode = is_function_mode_active(context)

        -- 收集候选（去重）
        local candidates = {}
        local phrase_count = {}
        for cand in input:iter() do
            local text = cand.text
            phrase_count[text] = (phrase_count[text] or 0) + 1
            if phrase_count[text] == 1 then
                table.insert(candidates, cand)
            end
        end

        -- 应用数据库中已有的全部调序记录
        -- 关键修复：from_position 应该动态计算当前位置，而不是基于原始顺序
        local user_adjustment = get_adjustment(code, schema_id)
        if user_adjustment then
            -- 为每个记录绑定候选
            for pos, cand in ipairs(candidates) do
                local key = is_func_mode and tostring(pos - 1) or cand.text
                if user_adjustment[key] then
                    user_adjustment[key].candidate = cand
                end
            end
            
            -- 按时间排序，逐个应用
            local list = {}
            for _, info in pairs(user_adjustment) do
                if info.candidate then
                    table.insert(list, info)
                end
            end
            table.sort(list, function(a, b) return a.updated_at < b.updated_at end)
            
            -- 逐个应用调序记录，动态计算 from_position
            for _, record in ipairs(list) do
                if record.to_position and record.to_position > 0 then
                    -- 动态查找当前位置
                    local from = nil
                    for pos, cand in ipairs(candidates) do
                        if cand == record.candidate then
                            from = pos
                            break
                        end
                    end
                    
                    if from and from ~= record.to_position then
                        local to = record.to_position
                        table.remove(candidates, from)
                        table.insert(candidates, to, record.candidate)
                    end
                end
            end
        end

        -- 执行数字键移动
        if pin_idx == 1 then
            -- 撤销：恢复上次调序的候选到原位置
            if last_adjustment and last_adjustment.code == code then
                for i, cand in ipairs(candidates) do
                    if cand.text == last_adjustment.text then
                        local moved = table.remove(candidates, i)
                        local target = math.min(last_adjustment.from_position, #candidates + 1)
                        table.insert(candidates, target, moved)
                        -- 保存新位置（实际上恢复）
                        local key = is_func_mode and tostring(target - 1) or moved.text
                        save_adjustment(code, key, target, nil, schema_id)
                        break
                    end
                end
                last_adjustment = nil
            end
        elseif pin_idx >= 2 and pin_idx <= #candidates then
            -- 前移一位：基于当前列表位置
            local moved = table.remove(candidates, pin_idx)
            local new_pos = pin_idx - 1
            table.insert(candidates, new_pos, moved)
            local key = is_func_mode and tostring(new_pos - 1) or moved.text
            save_adjustment(code, key, new_pos, nil, schema_id)
            last_adjustment = { code = code, text = moved.text, from_position = pin_idx }
        end

        -- 更新会话内顺序缓存（用于快速恢复，但本分支已从数据库读取，缓存仅作辅助）
        local new_order = {}
        for _, cand in ipairs(candidates) do
            table.insert(new_order, cand.text)
        end
        mobile_candidate_order[code] = new_order

        -- 输出结果
        for _, cand in ipairs(candidates) do yield(cand) end
        return
    end

    -- 非调序路径：常规候选输出，需应用数据库记录
    -- 清除移动端会话状态（编码变化或上屏后撤销不应再有效）
    mobile_candidate_order = {}
    last_adjustment = nil

    local adjust_code = extract_adjustment_code(context)
    local user_adjustment = get_adjustment(adjust_code, schema_id)

    local has_unsaved_adjustment = cur_adjustment_phrase ~= nil
        and cur_adjust_offset ~= 0
        and cur_adjust_offset ~= nil
        and adjust_code ~= ""

    -- ============================================================
    -- 【性能】无调序数据、也无待应用调整时：惰性「边取边去重边输出」直通。
    --
    -- 原实现把上游【全部】候选先物化进 candidates 再统一输出，这会强制上游
    -- super_sequence*S 的扫描段必定执行（其惰性设计因此失效）。2 键输入实测
    -- 码表候选约 1002 条，等于每次落键都把整条候选流读完。
    --
    -- 改为惰性后，下游（wubi_pinyin_filter / simplifier / uniquifier）不再索取时
    -- 协程就挂在 yield 上，上游一条都不会多读。去重语义与原实现完全一致
    -- （按 cand.text 首次出现为准）。仅当确实存在调序记录时才走下面的物化路径。
    -- ============================================================
    if user_adjustment == nil and not has_unsaved_adjustment then
        local seen = {}
        for cand in input:iter() do
            local text = cand.text
            if not seen[text] then
                seen[text] = true
                yield(cand)
            end
        end
        return
    end

    -- 收集候选（去重）
    local candidates = {}
    local phrase_count = {}
    local dedupe_position = 1
    local cur_candidate = nil
    local cur_raw_index = nil
    local is_func_mode = is_function_mode_active(context)

    for cand in input:iter() do
        local text = cand.text
        phrase_count[text] = (phrase_count[text] or 0) + 1
        if phrase_count[text] == 1 then
            table.insert(candidates, cand)
            if cur_adjustment_phrase == text then
                cur_candidate = cand
                cur_raw_index = dedupe_position - 1
            end
            local adjust_key = is_func_mode and tostring(dedupe_position - 1) or text
            if user_adjustment and user_adjustment[adjust_key] then
                user_adjustment[adjust_key].candidate = cand
            end
            dedupe_position = dedupe_position + 1
        end
    end

    -- 应用数据库中的调序记录（如果有）
    -- 关键修复：动态查找当前位置，而不是使用绑定的 from_position
    if user_adjustment ~= nil then
        local list = {}
        for _, info in pairs(user_adjustment) do
            if info.candidate then
                table.insert(list, info)
            end
        end
        table.sort(list, function(a, b) return a.updated_at < b.updated_at end)
        for _, record in ipairs(list) do
            if record.to_position and record.to_position > 0 then
                -- 动态查找当前位置
                local from = nil
                for pos, cand in ipairs(candidates) do
                    if cand == record.candidate then
                        from = pos
                        break
                    end
                end
                
                if from and from ~= record.to_position then
                    local to = record.to_position
                    table.remove(candidates, from)
                    table.insert(candidates, to, record.candidate)
                end
            end
        end
    end

    -- 应用当前调整（Ctrl+J/K/L/P 产生的）
    if has_unsaved_adjustment then
        local from_position = nil
        for position, cand in ipairs(candidates) do
            if cand.text == cur_adjustment_phrase then
                from_position = position
                break
            end
        end

        if from_position ~= nil then
            local to_position = from_position + cur_adjust_offset
            if to_position < 1 then
                to_position = 1
            elseif to_position > #candidates then
                to_position = #candidates
            end

            if from_position ~= to_position then
                table.remove(candidates, from_position)
                table.insert(candidates, to_position, cur_candidate)
                local adjust_key = is_func_mode and cur_raw_index or cur_adjustment_phrase
                if adjust_key then
                    save_adjustment(adjust_code, adjust_key, to_position, nil, schema_id)
                    cur_highlight_idx = to_position - 1
                end
            end
        end
    end

    -- 更新会话内顺序缓存（用于移动端数字键分支快速读取，但不再依赖它）
    local new_order = {}
    for _, cand in ipairs(candidates) do
        table.insert(new_order, cand.text)
    end
    mobile_candidate_order[adjust_code] = new_order

    -- 输出最终结果
    for _, cand in ipairs(candidates) do
        yield(cand)
    end

    -- 在filter处理完成后重置临时状态
    if has_unsaved_adjustment then
        cur_adjustment_phrase = nil
        cur_highlight_idx = nil
        cur_adjust_offset = 0
        in_pin_mode = false
    end
end

-- ============================================================
-- 自动词频排序（通用版）
-- 适用于任意键位布局（26键、14键、18键等）
-- ============================================================
local MAX_CANDIDATES = 200            -- 码表类候选数量上限（性能保护，勿轻易放开：2 键输入实测有 1002 条码表候选）
local MAX_REVERSE_CANDIDATES = 30     -- 末尾补挂的拼音反查候选上限（单独计数，不被码表候选挤掉）
local MAX_SCAN = 1500                 -- 补挂阶段的扫描上限（只统计"已超出数量上限之后"的候选；
                                      -- 2 键输入实测 1002 条码表候选，1500 足以扫到流末尾）
local MAX_SCAN_SHORT = 200            -- 1 键输入的补挂扫描上限（1 键候选可达上万条，必须收紧）
-- ⚠️ 不要再用 `table.sort(list, by_quality_desc)`！
-- Lua 的 table.sort 是快排，**不稳定**：比较函数对全部元素恒返回 false 时，
-- 元素顺序会被任意打乱。而 librime 的 reverse_lookup（拼音反查）候选
-- quality **恒为 0.0**（本机实测 liang 的 21 条全是 Q0.0）⇒ 恰好吃满这个陷阱：
--   librime 原本已按字典词频排好「两 量 亮 梁 良 凉 辆 靓 粮 俩 …」，
--   过一遍 table.sort 就变成「莨 椋 粱 谅 魉 墚 … 两(第 15 位)」——
--   常用字被甩到后面、生僻字顶到前面（用户报的"单字区分有问题"）。
local function by_quality_desc(a, b)
    return (a.quality or 0) > (b.quality or 0)
end

-- ============================================================
-- 稳定降序排序（quality 相同时保持原有相对顺序）—— 替代 table.sort + by_quality_desc
--
-- 实现：以下标为 key，质量相等时按原下标升序 ⇒ 稳定；并对"全部相等"短路。
-- 实测（本机 librime，输入 liang）：
--   有 table.sort ：莨 椋 粱 谅 魉 墚 里昂 惊 踉 利昂 俩 亮 梁 量 两 晾 良 辆 凉 粮 靓
--   本函数        ：两 量 亮 梁 良 凉 辆 靓 粮 俩 晾 利昂 里昂 谅 粱 椋 魉 踉 墚 惊 莨
-- 后者与纯拼音方案（ly_pinyin_14，字典直查，无此过滤器）的顺序完全一致。
-- 性能：额外两次 O(n) 遍历 + 一次拷贝；实测 2 键输入（216/228 条候选）与原实现
--       持平（差异在测量噪声内，瓶颈在 C API 翻页）
-- ============================================================
local function sort_candidates_desc(list)
    local n = #list
    if n <= 1 then return end

    local q = {}
    local all_same = true
    q[1] = list[1].quality or 0
    for i = 2, n do
        q[i] = list[i].quality or 0
        if q[i] ~= q[1] then all_same = false end
    end
    -- 全部 quality 相同（拼音反查流的常态）：排序无意义，直接保持原序，
    -- 既省开销，也避免任何可能的打乱。
    if all_same then return end

    local idx = {}
    for i = 1, n do idx[i] = i end
    table.sort(idx, function(a, b)
        if q[a] ~= q[b] then return q[a] > q[b] end
        return a < b                -- 相等时按原序 ⇒ 稳定
    end)
    local out = {}
    for k = 1, n do out[k] = list[idx[k]] end
    for k = 1, n do list[k] = out[k] end
end

-- ===================================================================
-- 【第十八轮】2 码混输的候选重排
-- ===================================================================

-- 是否为混输方案（schema 的 engine/mixed_input: true），按 schema_id 缓存
local _mixed_schema_cache = {}
local function is_mixed_schema(env)
    local schema = env.engine.schema
    local sid = schema.schema_id or ""
    local cached = _mixed_schema_cache[sid]
    if cached == nil then
        cached = schema.config:get_bool('engine/mixed_input') or false
        _mixed_schema_cache[sid] = cached
    end
    return cached
end

-- ===================================================================
-- 【第十八轮】混输方案的拼音候选前置
-- ===================================================================

-- pinyin_direct 翻译器产出的候选，quality 恒 ≥ 1000
-- （initial_quality 设成 1000，词频只体现在小数位 ⇒ 实测 1000.0482…~1000.0）。
-- 这是「这批候选是拼音直查结果」的唯一可靠标记：反查（reverse_lookup）候选的
-- quality 恒为 0、码表候选恒 ≤ 850，都不会撞到这个区间。
local PINYIN_DIRECT_MIN_QUALITY = 1000

-- 前置生效的输入长度区间。
--   · 1 码：候选上限只有 25 条，顺序经多轮调校，不动；
--   · 2~4 码：五笔简码/前缀补全的候选最多、歧义最大，正是「拼音被埋」的重灾区
--            （实测 de 的「的」在 191、ni 的「你」在 139、he 的「和」在 63、
--             shi 的「是」在 47）；
--   · 5~6 码：wubi_pinyin_filter 有专门的「只留拼音反查」逻辑，不能掺入
--            同名的码表候选（见 sorter 收集段对 PINYIN_DIRECT_MAX 的说明）。
local PINYIN_HOIST_MIN_LEN = 2
local PINYIN_HOIST_MAX_LEN = 4

-- 拼音组之前最多保留的几条「非联想补全」候选（第二十三轮前只数单字，见 hoist_pinyin）。
-- 为什么要设上限：2 码的模糊等价会一次命中一串单字，实测 de 有 9 个（原 有 胡 圾 垢
--   郁 碑 硼 髯）、ni 有 9 个（悄 峭 尿 已 山 同 民 恍 屑）。若不设上限，拼音组被推到
--   第 10 位 —— 候选页大小是 9（default.yaml: menu/page_size: 9），拼音刚好掉到第 2 页，
--   等于没修好。取 5 之后：
--     de → 原 有 胡 圾 垢 | 的 得 地 德 | 郁 碑 硼 髯 | 有限 有戏 …
--     ni → 悄 峭 尿 已 山 | 你 泥 呢 拟 | 同 民 恍 屑 | 悄悄 同学们 …
--   前 5 条已覆盖 2 码简码的绝大多数用法；第 6 条起让位给拼音，两边都在首页。
--   这也是「拼音组必然落在首页」的保证：它前面最多只有这 5 条。
-- 想改成「拼音直接置顶」：把这个值设成 0 即可（前 5 条也让位）。
local PINYIN_HOIST_HEAD_CAP = 5

-- 纳入「拼音组」的 pinyin_direct 候选条数上限。
-- 为什么必须有：拼音字典里同一个音节的字数在「扩展」态会暴涨 —— 实测 ni / shi / bu
--   在扩展态各有 200+ 条候选（你 米 迷 拟 尼 呢 密 泥 妳 泥… / 是 时 事 使 市 式 …），
--   会一口气吃满 MAX_CANDIDATES=200 的配额，五笔候选（悄 峭 尿 已 山 / 椒 要 相 木 朴）
--   被整片挤掉、且 singles 为空导致前置失效 ⇒ 五笔用户打 ni 只看得到拼音。
--   截断之后：五笔单字照旧在首位，拼音组紧随其后，超出的生僻拼音字回到它们
--   原来的位置（末尾补挂段），与改造前一致 —— 是「沉底」，不是「消失」。
--
-- 【第二十五轮】30 → 10：26 键混输（ly_wubi_pinyin）也装上了 pinyin_direct，
--   而它的 GB2312 开关默认是「扩展」（14 键默认「常用」），同一套拼音直查在 26 键上
--   会一口气带出 20~30 条：de → 的 得 地 德 锝 底 徳 悳 淂 㝵 㤫 㥀 …（全是生僻字/异体字），
--   把五笔单字和词组整片挤出首页。压到 10 之后首页只剩最常用的 10 个拼音字，
--   五笔单字提前露面（ni：第 6~15 位是拼音，第 16 位就回到 恍 犀 惝 屑）。
--   对 14 键的影响很小：它默认「常用」字符集，de 的拼音块本来就只有 5 条；
--   ni 的常用态拼音有 10 条，恰好用满，前 15 位与改造前完全一致。
-- 注意：调它对「联想词/词组的位次」几乎无效 —— 联想词在 hoist_pinyin 的第 ④ 段，
--   压它的是第 ③ 段（其余五笔单字），不是这里的拼音块。想让联想词进首页该改
--   PINYIN_HOIST_HEAD_CAP 或限制第 ③ 段长度。
local PINYIN_DIRECT_MAX = 10

-- 把已物化的候选原地重排成四段：
--   ① 前 PINYIN_HOIST_HEAD_CAP 条「真实命中」候选（组内保持原序 ⇒ 五笔打 2 码手感不变）
--   ② 拼音直查候选（组内保持原序，它已按拼音字典词频排好：的 得 地 德 底）
--   ③ 其余真实命中候选
--   ④ 联想/补全出来的多字词（type == "completion" 且字数 > 1）
-- 效果（GB2312 = 常用）：
--   de   → 原 有 胡 圾 垢 | 的 得 地 德 | 郁 碑 硼 髯 | 有限 有戏 …
--   ni   → 悄 峭 尿 已 山 | 你 泥 呢 拟 | 同 民 恍 屑 | 悄悄 同学们 …
--   he   → 肯 上 目 | 和 喝 何 合 … | …
--   ougn → 实现 被刺 补眠 这 为 | 平 凭 评 瓶 … | 实 火 料 之 …
--
-- 【第二十三轮】为什么不再按「单字 / 词组」分段：
--   第十八轮的分段是 ①单字 ②拼音 ③其余单字 ④词组 —— **所有多字词一律落到第 ④ 段**，
--   等于「词组永远排在最后」。在 de / ni / he 上这是对的：它们的多字词（有限、有戏、
--   悄悄、同学们…）全是 completion 类型的联想补全，本来就该垫底。
--   但 ougn 不是：这里的「实现 / 被刺 / 补眠」type 是 table / phrase，quality 850 或 500，
--   是**真实的码表命中**而不是联想 —— 纯五笔方案里它们稳居前三。旧规则把真实命中和
--   联想补全一并塞到第 ④ 段，前面挡着 25 个单字（其中 这/为/实/火/料 只吃掉部分编码，
--   平/凭/评… 还是 quality=0 的拼音反查副本），这个词实际上是打不出来的。
--   ⇒ 区分二者的依据是**产出来源（type）**，不是字数：只要不是 completion，词组就和单字
--     一样有资格进第 ① 段竞争前排。竞争规则不变（按 quality 降序），于是 quality 850 的
--     码表命中天然压过 quality 500 的简码单字 —— 与纯五笔的顺序一致。
--   反例保护：de 的「郁 / 碑 / 硼 / 髯」type 同样是 completion，但它们是单字，不进第 ④ 段
--   （第 ④ 段只收多字联想词），因此它们在 de 上的位置与改造前完全相同。
local function hoist_pinyin(list)
    local n = #list
    if n <= 1 then return end

    local mains, pinyins, tails = {}, {}, {}
    local nm, np, nt = 0, 0, 0
    for i = 1, n do
        local cand = list[i]
        if (cand.quality or 0) >= PINYIN_DIRECT_MIN_QUALITY then
            np = np + 1; pinyins[np] = cand
        elseif cand.type == "completion"
               and (utf8.len(tostring(cand.text or "")) or 2) ~= 1 then
            -- 联想补全出来的多字词：始终留在最后一段
            nt = nt + 1; tails[nt] = cand
        else
            nm = nm + 1; mains[nm] = cand
        end
    end

    -- 没有拼音候选，或没有其它候选 ⇒ 重排无意义，保留原序（多数输入走这条短路）。
    if np == 0 or nm == 0 then return end

    local keep = nm
    if keep > PINYIN_HOIST_HEAD_CAP then keep = PINYIN_HOIST_HEAD_CAP end

    local k = 0
    for i = 1, keep do k = k + 1; list[k] = mains[i] end
    for i = 1, np do k = k + 1; list[k] = pinyins[i] end
    for i = keep + 1, nm do k = k + 1; list[k] = mains[i] end
    for i = 1, nt do k = k + 1; list[k] = tails[i] end
end

local function sorter(input, env)
    local input_text = env.engine.context.input:sub(1, env.engine.context.caret_pos)
    -- 命令模式（/开头）和 z 键反查模式：直接输出所有候选，跳过排序和数量限制
    if input_text:find("^/") or input_text:find("^z") or input_text:find("^@") then
        for cand in input:iter() do
            yield(cand)
        end
        return
    end

    local input_len = #(env.engine.context.input or "")
    -- 1码时限制候选数量并排序，让常用字排在前面
    local limit = (input_len <= 1) and 25 or MAX_CANDIDATES
    local scan_budget = (input_len <= 1) and MAX_SCAN_SHORT or MAX_SCAN

    -- 【第十八轮】混输方案的拼音候选前置。
    --
    -- 问题：librime 的合并流把 reverse_lookup（拼音反查）候选排在全部码表候选
    --   之后（ReverseLookupTranslation::Compare 只对 completion / sentence 让位，
    --   其余一律「我在后」），而 2 码恰是码表候选最多的场合。实测（GB2312=常用）：
    --     de  共 195 条，「的」被压在 191；ni 的「你」139；he 的「和」63；
    --     shi 的「是」47；wo 的「我」181。而纯拼音方案里 de 的第 1 位就是「的」
    --     ——用户打拼音得翻二十多页，等于拼音候选不可达。
    --   反查本身捞不回来：de 的反查候选位于原始流的第 866 位（流总长 874），
    --   把收集窗口从 200 一路放大到 900 才够，实测每多读 200 条就多花 ~10 ms
    --   （de 19.6ms → 30.1ms → 41.4ms → 53.0ms），不可接受。
    --
    -- 做法（零额外读取）：在 translators 里加一个 table_translator@pinyin_direct
    --   （dictionary/prism 都指向拼音字典，initial_quality: 1000），它排在
    --   table_translator 之前，产出的拼音候选天然落在候选流的第 1~24 位，
    --   且 quality ≥ 1000 —— 既不占收集代价，又给了我们一个可靠的识别标记。
    --   本过滤器只负责「把这个标记明确的拼音组挪到五笔单字之后」。
    --
    -- 只对「混输方案 + 2~4 码」生效：纯五笔方案（ly_wubi / ly_wubi_14）没有
    --   拼音输入诉求，顺序不该被顺带改掉；1 码走 25 条上限 + 补挂；
    --   5~6 码由 wubi_pinyin_filter 的「只留反查」逻辑接管。
    local mixed = is_mixed_schema(env)
    local hoist_pinyin_group = mixed
        and input_len >= PINYIN_HOIST_MIN_LEN
        and input_len <= PINYIN_HOIST_MAX_LEN

    -- 不前置的长度（1 码、5~6 码）必须把 pinyin_direct 候选整片丢弃，原因有二：
    --   ① 5~6 码下 wubi_pinyin_filter 要求「只输出 reverse_lookup 类型」，
    --      而 pinyin_direct 是 table 类型 —— 留着会被它整片丢掉，看着无害；
    --      但 super_sequence*F 的去重是按 text「首次出现为准」，pinyin_direct
    --      排在反查之前 ⇒ 反查那条同名的会被去掉（liang 的「两」会整个消失）。
    --   ② 丢弃发生在其质量排序之前，既有顺序完全不受影响，等于这个翻译器
    --      对 1 码与 5~6 码不存在。
    -- 前置的长度下，超过 PINYIN_DIRECT_MAX 的尾部也一并丢弃：理由见该常量的说明。

    local candidates = {}
    local emitted = false       -- 前 limit 条是否已排序输出
    local appended = 0          -- 已补挂的拼音反查候选数
    local scanned = 0           -- 补挂阶段已扫描的候选数
    local pinyin_kept = 0       -- 已纳入 candidates 的 pinyin_direct 候选数

    -- 排序 + （2~4 码混输）拼音前置 + 自动调频，然后整段输出
    local af_on = nil          -- 惰性判断一次即可（get_option 每次调用都有开销）
    local function output()
        if #candidates > 1 then
            sort_candidates_desc(candidates)
        end
        if hoist_pinyin_group then hoist_pinyin(candidates) end
        -- 【自动调频】放在 S 过滤器 ⇒ 其后运行的 F 过滤器（手动调序）永远覆盖它
        if af_on == nil then af_on = af_enabled(env.engine.context) end
        if af_on then
            af_apply(candidates, input_text,
                     env.engine and env.engine.schema and env.engine.schema.schema_id)
        end
        for _, c in ipairs(candidates) do yield(c) end
        emitted = true
    end

    -- 分两段处理，第二段（补挂）由客户端索取驱动：
    -- 下面的 yield 是协程挂起点，客户端不再要后续候选时，第二段循环根本不会执行。
    -- 因此普通打字（含 2 键输入）的耗时与改造前完全一致，只有真正翻页到末尾才会付出扫描代价。
    for cand in input:iter() do
        if not emitted then
            if (cand.quality or 0) >= PINYIN_DIRECT_MIN_QUALITY then
                -- pinyin_direct 候选：只有「2~4 码混输 + 未超上限」才纳入，
                -- 其余一律丢弃（既不占 limit 配额，也不参与排序）
                if hoist_pinyin_group and pinyin_kept < PINYIN_DIRECT_MAX then
                    pinyin_kept = pinyin_kept + 1
                    table.insert(candidates, cand)
                    if #candidates >= limit then output() end
                end
            else
                table.insert(candidates, cand)
                if #candidates >= limit then output() end
            end
        else
            scanned = scanned + 1
            if scanned > scan_budget then break end
            -- 补挂阶段：只挑被数量上限挤掉的拼音反查候选，挂在列表末尾。
            -- 背景：reverse_lookup（拼音反查）候选在 librime 的合并流里排在码表候选之后
            -- （ReverseLookupTranslation::Compare 只对 completion / sentence 让位），
            -- 码表候选一旦超过 limit（as+ui=au 实测 1002 条）就会被整片丢弃。
            -- 补挂位置固定在末尾：既有候选的顺序、位置与数字键调序均不受影响。
            if cand.type == "reverse_lookup" then
                yield(cand)
                appended = appended + 1
                if appended >= MAX_REVERSE_CANDIDATES then break end
            end
        end
    end

    if not emitted then output() end
end

local S = { func = sorter }

return { P = P, F = F, S = S }