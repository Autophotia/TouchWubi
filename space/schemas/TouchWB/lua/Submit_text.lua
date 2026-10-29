--[[
    Submit_text.lua - 自造词管理与辅助输入处理器
    功能：自造词、手动造词、反查、标点快捷输入
    作者: 空山明月、shawx、Autophotia
    主页: https://github.com/Autophotia/TouchWubi
    日期: 2026-06-06
    优化: 统一26键和14键的造词编码生成逻辑，优先从字典查询标准五笔编码
    优化: 修复翻译器场景下 is_14key_layout 函数调用问题
    优化: 14键造词时支持模糊输入，保存时自动生成标准五笔编码
    优化: 清理冗余代码，统一文件路径，移除移动设备检测
    修复: 添加反向前缀匹配（输入编码以存储编码开头），解决5码输入无法匹配自造词问题

    【主要功能】
    1. 自造词手动模式：输入"词条`编码"后按空格键，自动追加到 user_coined_ext.txt
    2. 自造词即时查询：实时读取用户词库，高优先级显示用户自定义词条
    3. 反查功能：按单引号键快速上屏第三候选项（table/reverse_lookup类型）
    4. 快捷上屏：分号键上屏第二候选，单引号键上屏第三候选
    5. 智能编码生成：无论26键还是14键，保存时自动查询标准五笔编码

    【编码规则】
    - 2字词：每字取前2位
    - 3字词：第1字1位，第2字1位，第3字2位
    - 4字及以上：前3字各1位，最后1字1位
    - 单字：取前4位

    【14键双键布局支持】
    按键映射关系（右边字母 → 左边字母）：
    - W → Q, R → E, Y → T, I → U, P → O
    - S → A, F → D, H → G, K → J
    - C → X, B → V, M → N

    自造词支持16种组合：左左左左、左左左右、左左右左、左左右右、
                         左右左左、左右左右、左右右左、左右右右、
                         右左左左、右左左右、右左右左、右左右右、
                         右右左左、右右左右、右右右左、右右右右

    【使用说明】
    1. 手动造词：输入编码（可模糊）+ 反引号 + 编码（可模糊）... → 选择候选词后按空格键确认
    2. 智能编码：无论输入模糊编码还是精确编码，保存时自动从字典查询生成标准五笔编码
    3. 快捷上屏：分号键上屏第二候选，单引号键上屏第三候选（反查/表格模式）
    4. 用户词库路径：{user_data_dir}/user_coined_ext.txt，即时生效无需重部署
    5. 格式：词条<Tab>编码
    6. 支持跨平台：Windows/macOS/Linux/Android(HarmonyOS)，实现跨平台自造词共享
]]

local basic = require('lib/basic')
local utf8chars = basic.utf8chars

-- =================================================================
-- == S88 撤销记录：S87 的空格豁免已删除（有害无益）==
-- =================================================================
-- 【用户 2026-10-04 的决定性澄清】
--   「长按空格唤醒语音功能一直好用，从没失效过，每次都是长按唤醒语音，
--     然后人说话输入法收音，松手后停止收音并转换成文字上屏。」
--   ⇒ 长按语音**从来没坏过**。S79~S87 八轮修的是一个不存在的问题。
--
-- 【S88 实测：长按时空格根本不会派发到引擎】
--   19:41:10 有一次长按成功（TouchWB 方案下），App 侧链条：
--     [STTBannerContainerController] didAppear
--       -> startRecording source=didAppear#3
--         -> [SpeechFSM] Starting -> Listening on ConnectSucceeded
--   同一时刻 `assoc_probe.log` 里 19:41:09~19:41:12 **一行都没有**。
--   ⇒ App 在手指还按着时就判定为长按并消费掉这次交互，
--     **空格按键从未送到 Rime**，Lua 侧连一个事件都没收到。
--
-- 【因此 S87 这段豁免是有害的，理由具体】
--   它的判据是「输入区为空 + 联想标志为真」，意图是「把空格留给长按」。
--   但长按**不需要空格**，所以：
--     ① 真实长按路径上永远走不到这段代码（长按时事件根本没进来）
--     ② 短按路径上反而会被它误伤 —— 当输入区为空且处于联想态时，
--        用户按空格想打一个空格，这段代码 `return 2` 把它扣住不上屏
--        ⇒ 表现为「空格偶尔失灵」，是纯粹的用户可感知损害。
--   `longpress.log` 里那 10 条记录也印证了这点：输入区全是 `unta`/`una`/`untg`
--   （打码中），唯一一条「输入区=空」走了豁免，而那次并没有对应的长按成功。
--
-- 【结论】
--   长按语音是 App 内置手势，**不需要 Lua 配合**。
--   Lua 侧唯一该做的，就是别碰空格。原先「扣住空格给长按」的思路本身就是错的。

-- =================================================================
-- == 14键双键布局映射模块 ==
-- =================================================================

local key_mapping = {
    w = 'q', r = 'e', y = 't', i = 'u', p = 'o',
    s = 'a', f = 'd', h = 'g', k = 'j',
    c = 'x', b = 'v', m = 'n'
}

local function get_key_pair(c)
    local left = key_mapping[c]
    if left then
        return left, c
    end
    for right, left_char in pairs(key_mapping) do
        if left_char == c then
            return c, right
        end
    end
    return c, nil
end

-- 将任意14键编码标准化为"左字母形式"（例如 ws → qa）
-- 使用 table.concat 提高字符串拼接效率
local function normalize_14key(code)
    if not code or code == "" then
        return code
    end
    local norm = {}
    for i = 1, #code do
        local c = code:sub(i, i)
        local left = key_mapping[c] or c
        table.insert(norm, left)
    end
    return table.concat(norm)
end

local function match_encoding(input_code, stored_code)
    if input_code == stored_code then
        return true
    end
    
    local normalized_input = normalize_14key(input_code)
    local normalized_stored = normalize_14key(stored_code)
    
    return normalized_input == normalized_stored
end

-- 判断当前是否为14键布局
local function is_14key_layout(env)
    local engine = env and env.engine
    if not engine then
        -- 尝试从上下文获取（翻译器场景）
        local ctx = env and env._context
        if ctx and ctx.engine then
            engine = ctx.engine
        end
    end
    if not engine or not engine.schema then
        return false
    end
    local schema_id = engine.schema.schema_id
    return schema_id and (schema_id == "ly_wubi_14" or schema_id == "ly_wubi_pinyin_14")
end

-- =================================================================
-- == 标准五笔编码查询模块 ==
-- =================================================================

-- 单字编码缓存，避免重复读取字典
--
-- ★ 2026-09-29 S14 卡顿修复：
--   原来是 __mode="v" **弱值表** —— 缓存的 value 只被这张表引用，
--   Lua 每次 GC 都会把整层缓存清掉 ⇒ 缓存形同虚设，每次都真读字典文件。
--   会话越久 ⇒ 堆里垃圾越多 ⇒ GC 越频繁 ⇒ 命中率越低 ⇒ 越慢（真机实测延迟
--   随使用时长单调上升、reload 后回落，正是这个正反馈）。
--   改成**强引用**；容量计数改成 O(1)（老写法每次写缓存要 pairs 全表遍历 2000 项）。
local char_code_cache = {}
local char_code_cache_n = 0

-- ★ 2026-10-29 自动造词卡顿修复：
--   上面的 char_code_cache 是「按需单字缓存」，首次遇到某个字仍要 io.open 打开
--   ly_wubi.dict.yaml 逐行扫 **14.8 万行**（真机日志实证：auto_coined*P 在有提交的
--   那一键 cost 飙到 1182µs，无提交时仅 5~10µs）。自动造词为每个相邻窗口词的每个字
--   都查编码，生僻字/新字持续触发全量扫描 ⇒ 每次上屏瞬间卡顿。
--   改成「懒加载全量字典」：首次查码时**一次性**把整本字典读进内存哈希表
--   { 字 → 最高权重编码 }，之后 O(1) 查表，永不再碰磁盘。14.8 万行只读一次，
--   内存占用约 2~3MB（可接受），换来彻底消除每键同步扫盘。
--   加载失败（字典路径尚未就绪等）时不固化空字典，下次调用会重试；查不到字就返回空码，
--   上层（generate_standard_code）拿不到完整码时仍会走 splitinput 降级，行为与修复前一致。
local char_dict_cache = nil     -- 全量字典哈希表（懒加载）
local char_dict_done  = false   -- 是否已成功加载过全量字典（失败保持 false，下次重试）

-- ★ 2026-10-25 造词专用日志（独立的低音量开关）。
--   与上面的 klog 不同：klog 每按一个键打 1~3 条（2702 键 7567 条）必须常关；
--   本开关只在「手动造词」这条窄路径上记录（input 含反引号 / 空格落词条 / 真正落盘），
--   正常打字一行不打 ⇒ 可以默认开着用来抓 bug，排完再关。
--   ⚠ 真机 log.info 只输出第一个参数，所以信息必须全部拼进第一个参数里。
local DEBUG_COIN_LOG = true
local function kcoin(tag, msg)
    if not DEBUG_COIN_LOG then return end
    pcall(function() if log and log.info then log.info("[COIN:" .. (tag or "?") .. "] " .. (msg or "")) end end)
end

-- 造词词条合法性：非空、不含字母、不少于 2 个字形
-- （utf8.len 遇到非法序列返回 nil + 位置，直接比较会报 "attempt to compare nil"，
--   所以整段 pcall 包住，非法输入一律判为不合格）
local function valid_word(s)
    if type(s) ~= "string" or s == "" then return false end
    if s:find("%a") then return false end
    local ok, n = pcall(utf8.len, s)
    return ok and type(n) == "number" and n > 1
end

-- 缓存大小限制（防止无限增长）
local MAX_CACHE_SIZE = 2000

-- 存值：满了就整层丢弃（一次性摊销，不再 pairs 遍历）
local function code_cache_put(k, v)
    if k == nil or k == '' then return v end
    if char_code_cache_n >= MAX_CACHE_SIZE then
        char_code_cache, char_code_cache_n = {}, 0
    end
    if char_code_cache[k] == nil then
        char_code_cache_n = char_code_cache_n + 1
    end
    char_code_cache[k] = v
    return v
end

-- 收集所有可能的字典文件路径（ly_wubi 新名优先，wubi / wubi.extended 旧名兜底）
local function collect_dict_paths()
    local dict_paths = {}
    local function add_dir(dir)
        if not dir or dir == "" then return end
        dir = dir:gsub("\\", "/")
        if dir:sub(-1) ~= "/" then dir = dir .. "/" end
        -- ★ 2026-10-25 修复：主词库已由 wubi.dict.yaml 改名为 ly_wubi.dict.yaml，
        --   旧名找不到 ⇒ 标准编码查询失败 ⇒ 造词只能降级用用户输入的编码。
        --   两个名字都留着（新名优先，旧名兜底），兼容任何一台还没同步字典的设备。
        table.insert(dict_paths, dir .. "ly_wubi.dict.yaml")
        table.insert(dict_paths, dir .. "wubi.dict.yaml")
        table.insert(dict_paths, dir .. "wubi.extended.dict.yaml")
    end
    add_dir(rime_api and rime_api.get_user_data_dir and rime_api.get_user_data_dir())
    add_dir(rime_api and rime_api.get_schema_data_dir and rime_api.get_schema_data_dir())
    add_dir(rime_api and rime_api.get_shared_data_dir and rime_api.get_shared_data_dir())
    return dict_paths
end

-- 单行解析：返回 text, code, weight（缺权重返回 0；非数据行返回 nil）
local function parse_dict_line(trimmed)
    local text, code, weight = trimmed:match("^([^\t%s]+)[\t%s]+([a-z]+)[\t%s]+(%d+)$")
    if text and code then
        return text, code, tonumber(weight) or 0
    end
    -- 更宽松匹配（无权重列）
    local text2, code2 = trimmed:match("^([^\t%s]+)[\t%s]+([a-z]+)$")
    if text2 and code2 then
        return text2, code2, 0
    end
    return nil
end

-- ★ 2026-10-29 懒加载全量字典：一次性把整本 ly_wubi.dict.yaml 读进内存哈希表
--   { 字 → 最高权重编码 }。之后 O(1) 查表，永不再逐字扫 14.8 万行。
local function build_char_dict()
    local dict = {}
    for _, dict_path in ipairs(collect_dict_paths()) do
        local f = io.open(dict_path, "rb")
        if f then
            local in_data = false
            for raw in f:lines() do
                local line = raw:gsub("\r$", ""):gsub("%s+$", "")
                if line == "..." then
                    in_data = true
                elseif line == "---" then
                    in_data = false
                elseif in_data and not line:match("^#") then
                    local text, code, w = parse_dict_line(line)
                    -- ★ 只保留单字：get_char_wubi_code 只查单字编码，多字词行占
                    --   14.8 万行的大头，无需入表，内存从 ~3MB 降到 ~0.5MB。
                    if text and utf8.len(text) == 1 then
                        local cur = dict[text]
                        if not cur then
                            dict[text] = { code = code, w = w }
                        elseif w > cur.w then
                            cur.code, cur.w = code, w
                        end
                    end
                end
            end
            f:close()
            -- 找到第一个可用的字典文件就停（ly_wubi 优先级最高，已含全部单字）
            if next(dict) then
                break
            end
        end
    end
    -- ★ 只有真正读到了字典数据才算「已加载」；失败（路径尚未就绪等）则下次调用再重试，
    --   避免把「空字典」永久固化、导致整个 session 都查不到码。
    if next(dict) then
        char_dict_done = true
    end
    return dict
end

-- 从字典文件中查询单个汉字的标准五笔编码
local function get_char_wubi_code(char)
    -- ① 逐字缓存（2000 条上限，命中即返回，含空结果）
    if char_code_cache[char] then
        return char_code_cache[char]
    end

    -- ② 全量字典懒加载（首次调用一次性读盘，之后 O(1) 查表）
    if not char_dict_done then
        char_dict_cache = build_char_dict()
    end
    if char_dict_cache then
        local e = char_dict_cache[char]
        if e then
            return code_cache_put(char, e.code)
        end
    end

    -- ③ 全量字典加载失败 / 查不到 ⇒ 返回空（让上层走 splitinput 降级）
    return code_cache_put(char, "")
end

-- 根据词条内容生成标准五笔词组编码
local function generate_standard_code(text)
    if not text or text == "" then
        return ""
    end
    
    local len = utf8.len(text)
    if len == 0 then
        return ""
    end
    
    -- 获取每个字的标准编码
    local char_codes = {}
    for i, char in ipairs(utf8chars(text)) do
        local code = get_char_wubi_code(char)
        table.insert(char_codes, code)
    end
    
    -- 按五笔规则生成词组编码
    local result = ""
    
    if len == 1 then
        -- 单字：取前4位
        result = (char_codes[1] or ""):sub(1, 4)
    elseif len == 2 then
        -- 2字词：每字取前2位
        result = (char_codes[1] or ""):sub(1, 2) .. (char_codes[2] or ""):sub(1, 2)
    elseif len == 3 then
        -- 3字词：第1字1位，第2字1位，第3字2位
        result = (char_codes[1] or ""):sub(1, 1) ..
                 (char_codes[2] or ""):sub(1, 1) ..
                 (char_codes[3] or ""):sub(1, 2)
    elseif len >= 4 then
        -- 4字及以上：前3字各1位，最后1字1位
        result = (char_codes[1] or ""):sub(1, 1) ..
                 (char_codes[2] or ""):sub(1, 1) ..
                 (char_codes[3] or ""):sub(1, 1) ..
                 (char_codes[len] or ""):sub(1, 1)
    end
    
    return result
end

-- ★ 2026-10-28：暴露给自动造词模块（auto_coined.lua）复用，
--   保证「自动连词造词」与「手动 ` 造词」走同一套词组码生成逻辑，
--   同一词条两者码逐字节一致，召回零冲突。
rawset(_G, "auto_coined_stdcode", generate_standard_code)

-- =================================================================
-- == 自造词路径管理模块 ==
-- =================================================================

local function get_rime_user_dir()
    if rime_api and rime_api.get_user_data_dir then
        return rime_api.get_user_data_dir() or ""
    end
    return ""
end

local function init_userphrase_path()
    local rime_dir = get_rime_user_dir()
    if rime_dir == "" then
        return ""
    end
    
    -- 统一使用正斜杠，跨平台兼容（Windows/macOS/Linux/Android）
    rime_dir = rime_dir:gsub("\\", "/")
    if rime_dir:sub(-1) ~= "/" then
        rime_dir = rime_dir .. "/"
    end
    
    return rime_dir .. "user_coined_ext.txt"
end

local userphrasepath = init_userphrase_path()

function get_userphrase_path()
    return userphrasepath
end

-- ★ 2026-10-28 修复：自动连词造词的「临时词」改存**独立文件** user_coined_auto.txt。
--   原实现把临时词写进手动词库 user_coined_ext.txt 的第三列，并用整文件重写的方式落盘，
--   与手动造词的 append 写入产生竞态 ⇒ 手动词被覆盖丢失。物理隔离后此问题从根上消除。
local function init_autophrase_path()
    local rime_dir = get_rime_user_dir()
    if rime_dir == "" then
        return ""
    end
    rime_dir = rime_dir:gsub("\\", "/")
    if rime_dir:sub(-1) ~= "/" then
        rime_dir = rime_dir .. "/"
    end
    return rime_dir .. "user_coined_auto.txt"
end

local autophrasepath = init_autophrase_path()

function get_autophrase_path()
    if not autophrasepath or autophrasepath == "" then
        autophrasepath = init_autophrase_path()
    end
    return autophrasepath
end
rawset(_G, "get_autophrase_path", get_autophrase_path)

local function ensure_userphrase_file()
    -- ★ 2026-10-25：module 加载时 userphrasepath 只在 dofile 的那一刻求值一次；
    --   若那时机(path 尚未就绪)取到空，旧代码直接 return ⇒ 整个 session 都造不了词，
    --   而读取方 user_coined_translator 有同样问题的自愈逻辑（见文末），两边的容错不对称。
    --   这里补上与读取侧一致的「用到时再试一次」。
    if not userphrasepath or userphrasepath == "" then
        userphrasepath = init_userphrase_path()
        kcoin("ensure", "re-init path -> [" .. tostring(userphrasepath) .. "]")
        if not userphrasepath or userphrasepath == "" then
            kcoin("ensure", "FAIL: user_data_dir 仍为空，本轮无法造词")
            return
        end
    end

    local f = io.open(userphrasepath, "r")
    if not f then
        f = io.open(userphrasepath, "w")
        if f then
            -- 注意：保持原来的 3 行注释头，不额外写入换行的初始内容，
            -- 这样 fileappendtext 追加时不会出现多余空行。
            f:write("# 自造词文件\n")
            f:write("# 格式：词条<Tab>编码\n")
            f:write("# 即时生效，无需重新部署\n")
            f:close()
        end
    else
        f:close()
    end
end

-- =================================================================
-- == 辅助函数 ==
-- =================================================================

function splitinput(input, len)
    if not input or input == "" then
        return ""
    end
    
    -- 按反引号分割编码
    local codes = {}
    for code in input:gmatch("([^`]+)") do
        table.insert(codes, code)
    end

    local result = ""

    if len == 2 then
        -- 2字词：每字取前2位
        if #codes >= 2 then
            result = (codes[1] or ""):sub(1, 2) .. (codes[2] or ""):sub(1, 2)
        else
            result = input:sub(1, 4)
        end
    elseif len == 3 then
        -- 3字词：第1字1位，第2字1位，第3字2位
        if #codes >= 3 then
            result = (codes[1] or ""):sub(1, 1) ..
                     (codes[2] or ""):sub(1, 1) ..
                     (codes[3] or ""):sub(1, 2)
        else
            result = input:sub(1, 4)
        end
    elseif len >= 4 then
        -- 4字及以上：前3字各1位，最后1字1位
        if #codes >= len then
            result = (codes[1] or ""):sub(1, 1) ..
                     (codes[2] or ""):sub(1, 1) ..
                     (codes[3] or ""):sub(1, 1) ..
                     (codes[len] or ""):sub(1, 1)
        else
            result = input:sub(1, 4)
        end
    else
        -- 单字：直接返回原编码
        result = input:sub(1, 4)
    end

    return result
end

-- ★ 自造词文件缓存（2026-09-29 S14）：声明必须在 fileappendtext 之前，
--   否则下面那句 `_uc_cache = nil` 会写进**全局**，与这里的 local 不是同一个变量。
local _uc_cache = nil
local UC_TTL = 60

function fileappendtext(filepath, context, input, env)
    if not context or context == "" or context:find("%a") then
        return
    end
    
    local len = utf8.len(context)
    local clean_input = ""

    if not filepath or filepath == "" then
        kcoin("write", "ABORT: filepath 为空，写不进去 context=[" .. context .. "]")
        return
    end

    -- 统一使用 generate_standard_code 从字典查询标准五笔编码
    -- 这种方式无论26键还是14键都更加可靠，不依赖用户输入的编码
    clean_input = generate_standard_code(context)

    -- 如果字典查询失败（可能是生僻字），降级使用用户输入的编码
    if not clean_input or clean_input == "" then
        clean_input = splitinput(input, len)
        if clean_input and clean_input ~= "" then
            kcoin("code", "DEGRADED: 字典查不到 [" .. context .. "]，改用用户输入 input=[" ..
                  tostring(input) .. "] -> " .. clean_input)
        end
    else
        kcoin("code", "standard [" .. context .. "] -> " .. clean_input .. " (len=" .. #clean_input .. ")")
    end

    if not clean_input or clean_input == "" then
        kcoin("write", "ABORT: 编码为空 context=[" .. context .. "]")
        return
    end

    -- ★ 兜底：#clean_input 不足 4 位（多数词 usr:#=4）通常意味着字典里
    --   某个字压根查不到编码 ⇒ 这种词存进去也打不出来。此时优先退回用户输入的全串试试。
    if #clean_input < 4 then
        local alt = splitinput(input, len)
        if alt and alt ~= "" and #alt > #clean_input then
            kcoin("code", "SHORT " .. #clean_input .. " 位，改用 " .. #alt .. " 位输入码 " .. alt)
            clean_input = alt
        else
            kcoin("code", "SHORT " .. #clean_input .. " 位且无更好输入码，仍写入：" .. clean_input)
        end
    end
    
    -- 检查是否已存在，避免重复写入相同词条和编码
    local normalized = context .. "\t" .. clean_input
    local f = io.open(filepath, "r")
    local exists = false
    if f then
        for line in f:lines() do
            if line == normalized then
                exists = true
                break
            end
        end
        f:close()
    end
    
    if not exists then
        f = io.open(filepath, "a")
        if f then
            f:write("\n" .. normalized)
            f:close()
            -- ★ 文件被我们改写了 ⇒ 自造词缓存立即失效（见 user_coined_translator）
            _uc_cache = nil
            kcoin("write", "OK [" .. context .. "] code=" .. clean_input .. " -> " .. tostring(filepath))
        else
            -- 旧代码这里静默失败：写不进去完全没有任何痕迹，看起来就是「造不了词」
            kcoin("write", "FAIL: io.open(filepath,'a') 返回 nil，path=" .. tostring(filepath))
        end
    else
        kcoin("write", "SKIP: 已存在完全相同条目 " .. normalized)
    end
end

-- =================================================================
-- == 自造词文件缓存（2026-09-29 S14）==
--   user_coined_translator 原本**每按一个键**（输入 ≥2 个字母）就
--   io.open + 逐行读一遍整个自造词文件。改成内存缓存：
--     · 文件唯一的写入者就是上面的 fileappendtext ⇒ 写完立即置空缓存；
--     · 再加 60 秒兜底刷新，防止用户在别处（同步 / 手动导入）改了文件。
-- =================================================================
-- 解析一行：返回 text, code, flag（flag 空串 = 无第三列）
local function parse_uc_line(line)
    if not line or line == "" or line:match("^#") then return nil end
    local text, code, flag = line:match("^([^\t]+)\t([a-z]+)\t?(.*)$")
    if not text or not code then return nil end
    return text, code, flag or ""
end

local function load_userphrase_list()
    if not userphrasepath or userphrasepath == "" then return nil end
    local list = {}

    -- 读一个词库文件；is_temp=true 表示该文件里的词条是「自动临时词」
    local function read_file(path, is_temp_file)
        if not path or path == "" then return end
        local f = io.open(path, "r")
        if not f then return end
        for line in f:lines() do
            line = line:gsub("\r$", "")
            local text, code, flag = parse_uc_line(line)
            if text and code then
                -- ★ 自愈：早期（错误）实现曾把临时词写进手动词库并留下 temp:N 的行，
                --   这里直接跳过，使这些历史垃圾词彻底失效，不再污染候选。
                -- ★ 2026-10-29 修复：自动临时词库（is_temp_file=true）里 temp:N 是
                --   正常格式，绝不能跳 —— 之前这里无条件跳过，导致所有自动临时词
                --   （灾加/灾加岂/加岂…）都进不了候选、永远显示不出来。
                --   只有读「手动/永久词库」（is_temp_file=false）时才跳过 temp:N 垃圾行。
                if is_temp_file or not flag:match("^temp:") then
                    list[#list + 1] = { text = text, code = code, flag = flag, temp = is_temp_file }
                end
            end
        end
        f:close()
    end

    read_file(userphrasepath, false)         -- 手动/永久词库
    read_file(get_autophrase_path(), true)   -- 自动临时词库（独立文件）
    return list
end

local function get_userphrase_list()
    local now = os.time()
    if _uc_cache and (now - _uc_cache.ts) < UC_TTL then return _uc_cache.list end
    _uc_cache = { list = load_userphrase_list() or {}, ts = now }
    return _uc_cache.list
end

-- ★ 2026-10-28：把一条自动临时词「转正」为永久词 —— 追加进手动词库 user_coined_ext.txt。
--   转正后它与手动造词完全同构（同样受 /zctj /zccx /zcdr 等命令管理），
--   因此 ——> 自动造词与手动造词最终汇入同一个词库，但生产路径互不干扰。
function UserCoined_AppendManual(text, code)
    if not text or text == "" or not code or code == "" then return false end
    ensure_userphrase_file()
    local p = get_userphrase_path()
    if not p or p == "" then return false end
    -- 已存在则不重复追加（去重）
    -- ★ 2026-10-29 修复：转正去重只能查「手动/永久词库」，绝不能把临时词库也算进去。
    --   load_userphrase_list 同时含手动词(temp=false)与自动临时词(temp=true)；
    --   若不排除临时词，召回某临时词转正时，去重循环会在临时库里命中同一条目、
    --   误判「已存在」直接 return true —— 结果既不追加进手动库、又被 auto_coined
    --   当作已转正从临时库里删掉 ⇒ 词条凭空消失、永远转不了正。
    for _, e in ipairs(load_userphrase_list() or {}) do
        if not e.temp and e.text == text and e.code == code then return true end
    end
    local f = io.open(p, "ab")
    if not f then return false end
    f:write(text .. "\t" .. code .. "\n")
    f:close()
    _uc_cache = nil
    return true
end
rawset(_G, "UserCoined_AppendManual", UserCoined_AppendManual)

-- =================================================================
-- == 处理器：自造词记录 ==
-- =================================================================

-- == 移动端判定（加回） ==
-- 用途：把「分号上屏第二候选 / 单引号上屏第三候选」这两个 PC 习惯快捷键
--   在手机上关掉。手机上点候选栏更快，而这两个键在 26 键布局里分别是
--   **L 键上滑（`'`）** 和常用符号 → 会被截胡成「上屏第 3 候选」，纯添乱。
-- 判据与 smart_assoc.lua / super_sequence.lua 保持一致。
local _mobile = nil
local function is_mobile()
    if _mobile ~= nil then return _mobile end
    _mobile = false
    if jit and jit.os then
        local o = (jit.os or ""):lower()
        if o:find("android") or o:find("harmony") then _mobile = true; return _mobile end
    end
    pcall(function()
        local d = ((rime_api and rime_api.get_user_data_dir and rime_api.get_user_data_dir() or "") .. " " ..
                   (rime_api and rime_api.get_shared_data_dir and rime_api.get_shared_data_dir() or "")):lower()
        if d:find("/data/storage/el%d") or d:find("/android/") or d:find("/storage/emulated/")
            or d:find("/sdcard/") or d:find("/harmony") or d:find("/hap/")
            or d:find("/space/") or d:find("/storage/users/") then
            _mobile = true
        end
    end)
    return _mobile
end

-- ★ 2026-09-29 S14：逐键调试日志开关。
--   真机（鸿蒙）上 log.info 是**同步写日志文件**，而下面这段每按一个键就要打 1~3 条
--   （实测 2702 次按键打了 7567 条）。排查问题时把它改回 true 即可，默认关。
--   ⚠ 真机 log.info 只输出第一个参数，改回来时记得把信息拼进第一个参数里。
local DEBUG_KEY_LOG = false
local function klog(tag, msg)
    if not DEBUG_KEY_LOG then return end
    pcall(function() if log and log.info then log.info(tag .. " " .. msg) end end)
end

local function commit_text_processor(key, env)
    local engine = env.engine
    local context = engine.context
    local composition = context.composition
    local segment = composition:back()
    local input_text = context.input
    local candidate_count = 0

    -- 记录候选词（用于反查等功能）
    if input_text then
        klog("Submit_text", "input_text=" .. input_text .. " matches_pattern=" .. tostring(input_text:find("^%p*(%a+%d*)$")) .. " has_menu=" .. tostring(context:has_menu()))
        if input_text:find("^%p*(%a+%d*)$") then
            if context:has_menu() then
                candidate_count = segment.menu:candidate_count()
            end
            env.last_1th_text = context:get_commit_text() or ""
            env.last_2th_text = {text="", type=""}
            env.last_3th_text = {text="", type=""}
            if candidate_count > 1 then
                local cand2 = segment:get_candidate_at(1)
                env.last_2th_text = cand2 and {text=cand2.text or "", type=cand2.type or ""} or {text="", type=""}
                klog("Submit_text", "candidate_count=" .. candidate_count .. " 2nd_candidate=" .. (env.last_2th_text.text or "nil"))
                if candidate_count > 2 then
                    local cand3 = segment:get_candidate_at(2)
                    env.last_3th_text = cand3 and {text=cand3.text or "", type=cand3.type or ""} or {text="", type=""}
                    klog("Submit_text", "3rd_candidate=" .. (env.last_3th_text.text or "nil") .. " type=" .. (env.last_3th_text.type or "nil"))
                end
            end
        end
    end

    local key_code_num = tonumber(key.keycode) or key.keycode
    local is_space_key = (key_code_num == 0x20) or (key_code_num == 32)
    
    -- 手动造词：直接使用原始输入字符串（保留反引号）
    local function update_manual_userphrase()
        if input_text and input_text:find("`") then
            local commit_text = context:get_commit_text() or ""
            kcoin("probe", "step=commit_text input=[" .. input_text .. "] has_menu=" ..
                  tostring(context:has_menu()) .. " commit_text=[" .. commit_text .. "]")

            if not valid_word(commit_text) then
                -- ★ 2026-10-25 兜底：commit_text 拿不到合规词条时，
                --   改从「当前菜单选中的候选」取值（拿不到选中项就退回首候选）。
                --   只在原本会判失败的情况下才生效，已成功的路径完全不变。
                local fb, why = nil, ""
                pcall(function()
                    if not context:has_menu() then why = "no_menu"; return end
                    local n = 0
                    if segment then
                        n = segment.menu:candidate_count()
                        fb = segment:get_selected_candidate()
                    end
                    if not fb then fb = context:get_selected_candidate() end
                    if not fb and n > 0 and segment then fb = segment:get_candidate_at(0) end
                    if not fb then why = why .. " no_candidate(n=" .. n .. ")" end
                end)
                if fb and fb.text and valid_word(fb.text) then
                    commit_text = fb.text
                    kcoin("probe", "step=fallback_candidate -> [" .. commit_text .. "]")
                else
                    kcoin("probe", "step=fallback_failed " .. why)
                end
            end

            if valid_word(commit_text) then
                env.userphrase = commit_text
                env.inputtext = input_text   -- 使用原始输入，保留反引号
                return
            end
            kcoin("probe", "step=REJECT: 无合规词条 input=[" .. input_text .. "]")
        end
        env.userphrase = ""
        env.inputtext = ""
    end

    -- 处理手动造词：保存并上屏
    local function handle_manual_coin()
        if env.userphrase and env.userphrase ~= "" then
            ensure_userphrase_file()
            fileappendtext(userphrasepath, env.userphrase, env.inputtext, env)
            engine:commit_text(env.userphrase)  -- 上屏
            context:clear()                     -- 清空输入状态
            env.userphrase = ""
            env.inputtext = ""
            return true
        end
        return false
    end

    update_manual_userphrase()

    -- ★ S88：原先这里有一段S87 诊断探针 + 「智能联想段豁免空格return 2」，
    --   已整体删除。理由见文件头 S88 撤销记录：
    --     ① 长按成功时空格按键根本不会派发到引擎（19:41:10 实测，Lua 侧零事件），
    --        所以那段豁免在真实长按路径上永远执行不到；
    --     ② 它只在短按时生效，判据「输入区为空 + 联想标志为真」一旦命中，
    --        就把用户想打的空格扣住不上屏 ⇒ 空格偶尔失灵，是纯粹的损害。
    --   现在空格语义回到最朴素的形式：有菜单上屏首候选，否则打空格。
    if is_space_key and context:has_menu() and not (input_text and input_text:find("`")) then
        local sel = nil
        if segment then sel = segment:get_selected_candidate() end
        if not sel then
            sel = context:get_selected_candidate()
        end
        if sel and sel.text and sel.text ~= "" then
            context:clear()
            engine:commit_text(sel.text)
            if _G.InputStats_Report then _G.InputStats_Report(sel.text) end
            return 1
        end
    end

    -- 空格键触发手动造词保存
    if is_space_key then
        -- ★ 诊断：空格有没有真走到这一步？（前面的 processor 可能已把它吞掉）
        kcoin("space", "到达 Submit_text input=[" .. tostring(input_text) ..
              "] has_backtick=" .. tostring(input_text and input_text:find("`") ~= nil) ..
              "] has_menu=" .. tostring(context:has_menu()) ..
              " userphrase=[" .. tostring(env.userphrase) .. "]")
    end
    if is_space_key and handle_manual_coin() then
        return 1
    end

    -- 单引号键上屏第三候选（有候选菜单时）
    -- ★ 手机上禁用。26 键布局「L 上滑 = '」本来是要打引号的，
    --   在这里被截胡 ⇒ 打码出候选时上滑 L 会莫名其妙上屏第 3 候选。
    --   手机上直接点候选栏更顺手，这个快捷键只留给 PC。
    if key.keycode == 0x27 and not is_mobile() then
        klog("Submit_text", "apostrophe key pressed, has_menu=" .. tostring(context:has_menu()) .. " is_composing=" .. tostring(context:is_composing()) .. " last_3th_text=" .. (env.last_3th_text and env.last_3th_text.text or "nil"))
        if context:has_menu() then
            if env.last_3th_text and env.last_3th_text.text ~= "" then
                klog("Submit_text", "committing 3rd candidate: " .. env.last_3th_text.text)
                context:clear()
                engine:commit_text(env.last_3th_text.text)
                if _G.InputStats_Report then _G.InputStats_Report(env.last_3th_text.text) end
            end
            return 1
        end
    end

    -- 分号上屏第二候选（同上：手机上禁用，理由一样）
    if key.keycode == 0x3B and not is_mobile() then
        klog("Submit_text", "semicolon key pressed, has_menu=" .. tostring(context:has_menu()) .. " is_composing=" .. tostring(context:is_composing()) .. " last_2th_text=" .. (env.last_2th_text and env.last_2th_text.text or "nil"))
        if context:is_composing() and env.last_2th_text and env.last_2th_text.text ~= "" then
            klog("Submit_text", "committing 2nd candidate: " .. env.last_2th_text.text)
            context:clear()
            engine:commit_text(env.last_2th_text.text)
            if _G.InputStats_Report then _G.InputStats_Report(env.last_2th_text.text) end
            return 1
        end
    end
    
    return 2
end

-- =================================================================
-- == 翻译器：自造词即时查询 ==
-- =================================================================

local function user_coined_translator(input, seg, env)
    -- 检查文件路径
    if not userphrasepath or userphrasepath == "" then
        userphrasepath = init_userphrase_path()
        if userphrasepath == "" then
            return
        end
    end
    
    -- 获取原始输入（不受 abbrev 规则影响），用于混输方案
    local raw_input = ""
    
    -- 方式1：从 env.engine.context 获取（最可靠，Rime Lua API 标准方式）
    -- env.engine.context.input 是用户原始输入，不受 algebra/abbrev 规则影响
    if env and env.engine and env.engine.context then
        raw_input = env.engine.context.input or ""
    end
    
    -- 方式2：从 seg 获取
    if raw_input == "" and seg then
        raw_input = seg.input or ""
    end
    
    -- 方式3：从 seg._context 获取
    if raw_input == "" then
        local ctx = seg and seg._context
        if ctx and ctx.input then
            raw_input = ctx.input or ""
        end
    end
    
    -- 优先使用原始输入，避免 abbrev 规则导致的编码截断
    -- 如果 raw_input 不为空且是纯字母，则使用它
    local query_input = raw_input:match("^[a-z]+$") or input
    
    -- 如果 query_input 为空或不是纯字母，直接返回
    if not query_input or not query_input:match("^[a-z]+$") then
        return
    end
    
    -- 限制：输入少于2个字母时不显示自造词，优先一级简码
    if #query_input < 2 then
        return
    end
    
    -- ★ 读内存缓存，不再每键开一次文件（详见 get_userphrase_list 注释）
    local entries = get_userphrase_list()
    if #entries == 0 then return end

    -- 判断是否为14键布局
    local use_dual_key = is_14key_layout(env)
    
    -- 在循环外先标准化输入编码，避免重复计算
    local norm_input = use_dual_key and normalize_14key(query_input) or query_input
    
    local seen = {}
    local function yield_user_coined(text, code, quality, is_temp)
        if seen[text] then
            return
        end
        seen[text] = true
        -- 自动临时词在候选码后加 ☯（与手动造词视觉标记一致的图标）；
        -- 转正后迁入手动词库 user_coined_ext.txt，不再带 temp 标记 ⇒ 图标自动消失。
        local disp = is_temp and (code .. "☯") or code
        local cand = Candidate("user_coined", seg.start, seg._end, text, disp)
        cand.quality = quality
        yield(cand)
    end

    local code_prefix
    for _, e in ipairs(entries) do
        local text, code = e.text, e.code
        local is_temp = (e.temp == true)
        code_prefix = code:sub(1, #query_input)
        local exact_match = (code == query_input)
        local prefix_match = (#query_input >= 2 and code:find("^" .. query_input) == 1)
        -- 反向前缀匹配：输入编码以存储编码开头（如输入 kqwys 匹配存储 kqwy）
        -- 用于处理5码输入时匹配4码存储的自造词
        local reverse_prefix_match = (#query_input > #code and query_input:find("^" .. code) == 1)

        -- 仅在14键布局时启用双键模糊匹配
        local dual_exact_match = false
        local dual_prefix_match = false
        local dual_reverse_prefix_match = false
        if use_dual_key then
            local norm_stored = normalize_14key(code)
            local norm_stored_prefix = normalize_14key(code_prefix)

            dual_exact_match = (not exact_match and #query_input == #code and norm_input == norm_stored)
            dual_prefix_match = (not exact_match and not prefix_match and #query_input >= 2 and #code >= #query_input and norm_input == norm_stored_prefix)
            -- 14键反向前缀模糊匹配
            dual_reverse_prefix_match = (not exact_match and not prefix_match and not reverse_prefix_match and #query_input > #code and norm_input:find("^" .. norm_stored) == 1)
        end

        if is_temp then
            -- ★ 2026-10-28 修复：自动临时词【只在整码精确匹配时浮现】。
            --   原实现让临时词参与前缀/反向/14键模糊匹配，且 quality 高达 850~950，
            --   于是每输入两三个字母就冒出一堆自动垃圾词抢占前排候选：
            --     · 正常词被顶到后几页（要翻候选栏）
            --     · 手动造词要求目标字在第一候选 ⇒ 被临时词挤掉而造不了词
            --   现在临时词仅当你「故意打出它的完整词组码」时才出现（用于召回转正），
            --   平时零污染；且 quality 800 低于手动词的 950，不会压住已确认的手动词。
            if exact_match then
                yield_user_coined(text, code, 800, true)
            end
        elseif exact_match then
            yield_user_coined(text, code, 950)   -- 精确匹配：高于所有候选（拼音候选最高约800）
        elseif dual_exact_match then
            yield_user_coined(text, code, 900)   -- 14键模糊精确匹配：低于精确匹配
        elseif reverse_prefix_match then
            yield_user_coined(text, code, 850)   -- 反向前缀匹配：用于5码输入匹配4码存储的自造词
        elseif dual_reverse_prefix_match then
            yield_user_coined(text, code, 800)   -- 14键反向前缀模糊匹配
        elseif prefix_match then
            yield_user_coined(text, code, 850)   -- 前缀匹配：低于精确匹配
        elseif dual_prefix_match then
            yield_user_coined(text, code, 750)   -- 14键模糊前缀匹配：最低优先级
        end
    end
end

-- =================================================================
-- == 模块导出 ==
-- =================================================================

rawset(_G, "user_coined_translator", user_coined_translator)

-- ★ 2026-10-27：给外部模块用的缓存失效钩子（供 lua/user_coined_cmd.lua 的
--   删词命令调用）。_uc_cache 是本文件的 upvalue，外部模块够不着；删完词若是
--   清不掉它，user_coined_translator 还会把已删除的词吐出来，最多滞后一个 TTL（60 秒）。
rawset(_G, "UserCoined_InvalidateCache", function() _uc_cache = nil end)

return commit_text_processor