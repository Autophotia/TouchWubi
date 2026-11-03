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
    1. 手动造词（徐码式逐字/词组累积）：长按 Z（反引号）逐段输编码、翻页选字上屏，全部选定后长按 Z 再按空格，整词写入 C++ UserDb（lua/user_coined）
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
    1. 手动造词：长按 Z（反引号）输该字/词组编码（可只输前几码）→ 翻页选字上屏（自动累积）→ 重复至全部选定 → 长按 Z 再按空格保存整词
    2. 智能编码：无论输入模糊编码还是精确编码，保存时自动从字典查询生成标准五笔编码
    3. 快捷上屏：分号键上屏第二候选，单引号键上屏第三候选（反查/表格模式）
    4. 用户词库：C++ UserDb（lua/user_coined），即时生效无需重部署
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
local char_dict_cache   = nil   -- 全量字典哈希表：{ 单字 -> code }（懒加载，扁平化省 table 对象）
local char_dict_phrases = nil   -- 已废弃：2026-11-01 起不再构建（改布隆过滤器，见下）
local char_dict_done    = false -- 是否已成功加载过全量字典（失败保持 false，下次重试）

-- =================================================================
-- == 主词典多字词去重：布隆过滤器（替代 11.8 万条哈希集合，省 ~10MB 常驻）==
-- =================================================================
-- 2026-11-01：原 char_dict_phrases 精确集合占 ~10MB（16MB 里的大头），是自动造词过程
--   GC 卡顿主因。改用布隆过滤器：1.2M bits（~37500 个 number 块）≈ ~0.6MB，误判率 ~2%。
--   误判方向是「把不在主词典的新词误判为已在」⇒ 该新词本次不造成临时词（宁漏造，
--   不重复造主词典词——与 v2.2 修复 A 语义一致，仅 ~2% 新词被漏造）。
local BLOOM_BITS = 1200000   -- 位数组长度（11.8 万词 @ 误判率 ~2%）
local BLOOM_K    = 7         -- 哈希函数个数
local bloom_blocks = nil     -- { [block_idx] = 32 位整数 }，懒构建，release_dict 释放

local function hash_djb2(s)
    local h = 5381
    for i = 1, #s do
        h = (h * 33 + s:byte(i)) % 4294967296
    end
    return h
end

local function hash_sdbm(s)
    local h = 0
    for i = 1, #s do
        h = (s:byte(i) + h * 64 + h * 65536 - h) % 4294967296
    end
    return h
end

local function bloom_set(s)
    local h1 = hash_djb2(s)
    local h2 = hash_sdbm(s)
    if h2 == 0 then h2 = 1 end
    for i = 0, BLOOM_K - 1 do
        local bit_pos = (h1 + i * h2) % BLOOM_BITS
        local block_idx = math.floor(bit_pos / 32) + 1
        local off = bit_pos % 32
        local mask = 2 ^ off
        local block = bloom_blocks[block_idx] or 0
        if block % (mask * 2) < mask then
            bloom_blocks[block_idx] = block + mask
        end
    end
end

local function bloom_check(s)
    if not bloom_blocks then return false end
    local h1 = hash_djb2(s)
    local h2 = hash_sdbm(s)
    if h2 == 0 then h2 = 1 end
    for i = 0, BLOOM_K - 1 do
        local bit_pos = (h1 + i * h2) % BLOOM_BITS
        local block_idx = math.floor(bit_pos / 32) + 1
        local off = bit_pos % 32
        local mask = 2 ^ off
        local block = bloom_blocks[block_idx]
        if not block or block % (mask * 2) < mask then
            return false
        end
    end
    return true
end

-- ★ 2026-10-25 造词专用日志（独立的低音量开关）。
--   与上面的 klog 不同：klog 每按一个键打 1~3 条（2702 键 7567 条）必须常关；
--   本开关只在「手动造词」这条窄路径上记录（input 含反引号 / 空格落词条 / 真正落盘），
--   正常打字一行不打 ⇒ 可以默认开着用来抓 bug，排完再关。
--   ⚠ 真机 log.info 只输出第一个参数，所以信息必须全部拼进第一个参数里。
--   ⚠ 2026-11-01 性能修复：真机 log.info 是「同步写日志文件」，手动造词每上屏一字、
--   每次保存都打 kcoin ⇒ 同步 IO 累积成「手动造词卡顿」（自动造词 auto_coined.lua 的
--   DEBUG_LOG 早已 false，所以自动不卡手动卡）。造词功能已闭环，改为 false。
local DEBUG_COIN_LOG = false
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

-- 安全取字符串字形数（非法 UTF-8 返回 0）
local function u8len(s)
    local ok, n = pcall(utf8.len, s)
    return (ok and type(n) == "number" and n) or 0
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
-- ★ 2026-11-01 性能重构：① 单字表扁平化（{字→code} 直接存字符串，省 2.4 万 table）；
--   ② 撤销 10-30 的「多字词去重索引」（11.8 万条短语集合，实测占 ~13MB 常驻，
--   GC 停顿 17ms/次，是自动造词过程卡顿大头）。去重价值有限（冗余临时词只在整码
--   精确匹配浮现 + 撞码被主词典覆盖 + 过期淘汰），性能优先砍掉，main_dict_has_phrase 恒 false。
--   build_dicts 现只构建单字表，首次加载从 ~470ms 降到 ~150ms、常驻 16MB 降到 ~3MB。
local function build_dicts()
    local dict = {}      -- 单字：字 -> code（取最高权重编码；扁平化省 table 对象）
    local wdict = {}     -- 临时：字 -> w（构建期比较权重用，函数返回即释放）
    bloom_blocks = {}    -- 布隆过滤器位块（多字词去重，省 ~10MB）
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
                    if text and code then
                        local n = utf8.len(text)
                        if n == 1 then
                            local curw = wdict[text]
                            if not curw or w > curw then
                                wdict[text] = w
                                dict[text] = code
                            end
                        elseif n >= 2 then
                            bloom_set(text)   -- 多字词进布隆过滤器（去重用）
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
    char_dict_cache = dict
    char_dict_phrases = nil
end

-- 确保全量字典已加载（懒加载入口，失败不固化，下次重试）
local function ensure_dict_loaded()
    if not char_dict_done then
        build_dicts()
    end
end

-- 从字典文件中查询单个汉字的标准五笔编码
local function get_char_wubi_code(char)
    -- ① 逐字缓存（2000 条上限，命中即返回，含空结果）
    if char_code_cache[char] then
        return char_code_cache[char]
    end

    -- ② 全量字典懒加载（首次调用一次性读盘，之后 O(1) 查表）
    ensure_dict_loaded()
    if char_dict_cache then
        local c = char_dict_cache[char]
        if c and c ~= "" then
            return code_cache_put(char, c)
        end
    end

    -- ③ 全量字典加载失败 / 查不到 ⇒ 返回空（让上层走 splitinput 降级）
    return code_cache_put(char, "")
end

-- ★ 2026-10-30：暴露给自动造词（auto_coined.lua）做「主词典已有词不重复造」。
--   返回 true = 该词条已是主词典多字词（ly_wubi.dict.yaml 收录），自动造词应跳过。
--   字典加载失败时返回 false（宁可造重，也不漏造），行为退化为修复前。
local function main_dict_has_phrase(text)
    if type(text) ~= "string" or text == "" then return false end
    ensure_dict_loaded()
    -- 布隆过滤器：~2% 误判（新词被误判为已在主词典 → 本次不漏造成临时词，可接受）
    return bloom_check(text)
end
rawset(_G, "auto_coined_in_main_dict", main_dict_has_phrase)

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

-- ★ 2026-11-01 移除 ensure_userphrase_file：方案 B 后自造词主库迁 C++ UserDb，
--   user_coined_ext.txt 不再被写入，只剩「历史迁移源」一个用途（uc_migrate_once 只读）。
--   原函数会 io.open(...,"w") 自动创建 3 行注释头的 txt —— 多余且误导，已删除，
--   禁止再生成该文件。

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

-- =================================================================
-- == 方案 B：自造词存储迁 C++ UserDb（对标魔然，消除热路径 Lua 文件 IO）==
-- =================================================================
-- 卡顿根因（真机日志量化确认）：translator 每键 io.open 读 txt、手动造词上屏
--   append txt、自动造词每上屏整文件重写 txt —— 全是热路径 Lua 文件 IO。
--   现迁到 librime C++ UserDb（LevelDb）：内存哈希 + 前缀查询 + 异步落盘，
--   彻底消除热路径 IO（同 smart_assoc.lua 的 assoc_*.userdb、魔然 moran_pin 的
--   pin_db 用法）。key/value 设计：
--     永久词: "e\t<code>\t<text>"  value = "<seq>"    seq 单调递增，用于倒序列表/撤销最近
--     临时词: "a\t<code>\t<text>"  value = "<tick>"   tick 提交计数，用于淘汰
--     meta:   "\0seq"              value = 下一个 seq 号
--   迁移（db 首次打开且无写入痕迹时，按优先级）：
--     ① 旧根目录 user_coined 库（方案 B 初版位置）→ 整体复制到 lua/user_coined；
--     ② 旧库为空 → 从历史 txt（user_coined_ext.txt / auto.txt）一次性导入；
--     迁移后不再读写 txt / 旧库（保留作历史备份，代码不再引用）。
local uc_db = nil
local uc_migrated = false

local function uc_open()
    if uc_db and uc_db:loaded() then return uc_db end
    -- ★ 2026-11-01 与联想/调序/tips 统一：userdb 放到 lua/ 下（lua/user_coined），
    --   不再落在用户目录根目录。旧根目录 user_coined 库由 uc_migrate_once 迁移。
    local db = LevelDb("lua/user_coined")
    if not db then return nil end
    local ok = pcall(function() db:open() end)
    if not ok or not db:loaded() then return nil end
    uc_db = db
    return uc_db
end

local function uc_manual_key(code, text) return "e\t" .. code .. "\t" .. text end
local function uc_temp_key(code, text)  return "a\t" .. code .. "\t" .. text end

-- 从 key 还原 text, code, is_temp；非词 key（如 meta）返回 nil
local function uc_parse_key(k)
    local kind, rest = k:match("^([ea])\t(.*)$")
    if not rest then return nil end
    local code, text = rest:match("^([^\t]+)\t(.+)$")
    if not code or not text then return nil end
    return text, code, (kind == "a")
end

-- 单调递增 seq（存 meta key "\0seq"，用于倒序列表 / 撤销最近造的词）
local function uc_next_seq()
    local db = uc_open()
    if not db then return 0 end
    local v = db:fetch("\0seq")
    local n = tonumber(v) or 0
    n = n + 1
    db:update("\0seq", tostring(n))
    return n
end

local function uc_put_manual(text, code)
    local db = uc_open()
    if not db then return false end
    local k = uc_manual_key(code, text)
    if db:fetch(k) ~= nil then return false end   -- 已存在，不重复写
    db:update(k, tostring(uc_next_seq()))
    return true
end

local function uc_put_temp(text, code, tick)
    local db = uc_open()
    if not db then return false end
    db:update(uc_temp_key(code, text), tostring(tick or 0))
    return true
end

local function uc_erase_manual(text, code)
    local db = uc_open()
    if not db then return false end
    return db:erase(uc_manual_key(code, text))
end

local function uc_erase_temp(text, code)
    local db = uc_open()
    if not db then return false end
    return db:erase(uc_temp_key(code, text))
end

local function uc_has_manual(text, code)
    local db = uc_open()
    if not db then return false end
    return db:fetch(uc_manual_key(code, text)) ~= nil
end

-- 倒序永久词 list（seq 降序 = 最近造的在最前）
local function uc_list_manual()
    local db = uc_open()
    local out = {}
    if not db then return out end
    local acc = db:query("e\t")
    if acc then
        for k, v in acc:iter() do
            local text, code = uc_parse_key(k)
            if text then out[#out + 1] = { text = text, code = code, seq = tonumber(v) or 0 } end
        end
    end
    table.sort(out, function(a, b) return a.seq > b.seq end)
    return out
end

-- 临时词 list（含 tick）
local function uc_list_temp()
    local db = uc_open()
    local out = {}
    if not db then return out end
    local acc = db:query("a\t")
    if acc then
        for k, v in acc:iter() do
            local text, code = uc_parse_key(k)
            if text then out[#out + 1] = { text = text, code = code, tick = tonumber(v) or 0 } end
        end
    end
    return out
end

local function uc_clear_manual()
    local db = uc_open()
    if not db then return false end
    local acc, keys = db:query("e\t"), {}
    if acc then for k in acc:iter() do keys[#keys + 1] = k end end
    for _, k in ipairs(keys) do db:erase(k) end
    return true
end

local function uc_clear_temp()
    local db = uc_open()
    if not db then return false end
    local acc, keys = db:query("a\t"), {}
    if acc then for k in acc:iter() do keys[#keys + 1] = k end end
    for _, k in ipairs(keys) do db:erase(k) end
    return true
end

-- 旧根目录 user_coined 库是否真实存在于磁盘（有 CURRENT 文件）。
--   ★ 不能直接 LevelDb("user_coined")+open 去探测——open 会在根目录凭空创建一个
--     空 user_coined.userdb 目录（残留垃圾）。必须先做文件系统存在性检查。
local function uc_old_db_exists()
    local dir = get_rime_user_dir()
    if dir == "" then return false end
    dir = dir:gsub("\\", "/")
    if dir:sub(-1) ~= "/" then dir = dir .. "/" end
    local f = io.open(dir .. "user_coined.userdb/CURRENT", "r")
    if f then f:close() return true end
    return false
end

-- 首次打开且 db 无写入痕迹（无 seq meta）时，迁移旧数据：旧 userdb 优先，其次历史 txt。
local function uc_migrate_once()
    if uc_migrated then return end
    uc_migrated = true
    local db = uc_open()
    if not db then return end
    if db:fetch("\0seq") ~= nil then return end   -- 已写过（迁移或新词），跳过

    -- ① 旧根目录 user_coined 库 → 新 lua/user_coined 库整体迁移（方案 B 初版把 userdb
    --   建在根目录，现迁到 lua/ 下）。整库复制（含 e/a/seq meta），旧库无数据则回退 txt。
    if uc_old_db_exists() then
        local old = LevelDb("user_coined")
        if old then
            local ok = pcall(function() old:open() end)
            if ok and old:loaded() then
                local acc = old:query("")
                if acc then
                    local has_any = false
                    for k, v in acc:iter() do
                        has_any = true
                        db:update(k, v)
                    end
                    if has_any then
                        return   -- 已从旧库迁移（含 seq meta），跳过 txt 迁移
                    end
                end
            end
        end
    end

    -- ② 历史 txt 迁移（早期版本种子数据，只读，不写回）
    -- 永久词（txt 末行 = 最新 ⇒ 按行序 seq 递增，导入后倒序正确）
    local ep = userphrasepath or ""
    if ep ~= "" then
        local f = io.open(ep, "r")
        if f then
            for raw in f:lines() do
                local line = raw:gsub("\r$", "")
                if not line:match("^#") then
                    local text, code = line:match("^([^\t]+)\t([a-z]+)")
                    if text and code then db:update(uc_manual_key(code, text), tostring(uc_next_seq())) end
                end
            end
            f:close()
        end
    end
    -- 临时词（tick 是 session 相对值，跨 session 无意义 ⇒ 归一化为 0）
    local ap = get_autophrase_path() or ""
    if ap ~= "" then
        local f = io.open(ap, "r")
        if f then
            for raw in f:lines() do
                local line = raw:gsub("\r$", "")
                if not line:match("^#") then
                    local text, code = line:match("^([^\t]+)\t([a-z]+)")
                    if text and code then db:update(uc_temp_key(code, text), "0") end
                end
            end
            f:close()
        end
    end
end

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

    -- ★ 2026-11-01 性能优化：手动造词保存仍查字典生成标准五笔码（保留「拼音筛字反查」，
    --   input 可能是拼音也可能是五笔码，不能简单 splitinput）。查完立即释放字典，
    --   消除「结束后持续卡顿」（字典不再常驻 Lua 堆）。字典现只加载单字表（2.4 万，
    --   已砍掉 11.8 万词去重集合），常驻从 ~16MB 降到 ~5.9MB、GC 从 17ms 降到 2ms。
    clean_input = generate_standard_code(context)
    if not clean_input or clean_input == "" then
        -- 字典查不到（生僻字）降级用用户输入编码（14键 normalize 到标准左字母码）
        clean_input = normalize_14key(splitinput(input, len) or "")
        if clean_input ~= "" then
            kcoin("code", "DEGRADED: 字典查不到 [" .. context .. "]，改用输入码 -> " .. clean_input)
        end
    else
        kcoin("code", "standard [" .. context .. "] -> " .. clean_input)
    end

    if not clean_input or clean_input == "" then
        kcoin("write", "ABORT: 编码为空 context=[" .. context .. "]")
        return
    end

    -- 写 UserDb
    uc_migrate_once()
    if uc_put_manual(context, clean_input) then
        kcoin("write", "OK [" .. context .. "] code=" .. clean_input .. " -> userdb")
    else
        kcoin("write", "SKIP: 已存在相同条目 " .. context .. "\t" .. clean_input)
    end
end

-- （方案 B：自造词列表缓存与首字母桶索引已由 C++ UserDb 内存哈希 + 前缀查询替代，
--   translator 直接 query(db, 首字母前缀)，无需 Lua 侧 list 缓存。）

-- ★ 2026-10-28：把一条自动临时词「转正」为永久词（方案 B 后写入 C++ UserDb）。
--   转正后它与手动造词完全同构（同样受 /zctj /zccx /zcdr 等命令管理）。
--   语义：已存在则视为「已转正」返回 true（调用方据此删除临时词）；否则写入返回 true。
function UserCoined_AppendManual(text, code)
    if not text or text == "" or not code or code == "" then return false end
    uc_migrate_once()
    local db = uc_open()
    if not db then return false end
    local k = uc_manual_key(code, text)
    if db:fetch(k) ~= nil then return true end   -- 已在手动库 = 视为已转正
    db:update(k, tostring(uc_next_seq()))
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

-- ★ 2026-10-31：手动造词「点击候选栏 / 空格上屏」统一转正保存。
--   点候选栏 = 前端 Context::Select，不产生按键事件 ⇒ commit_text_processor 收不到。
--   保存靠 update_notifier 在提交后结算，判定「是否有新上屏」复用 auto_coined.lua
--   的 detect_and_settle 双判据（size 变 / back 文本变）。
--   ★ v2.11 废弃 super_sequence 的「输入码变空」判据③：它在 bimkit 点选上屏时会在
--   「清空 composition 但尚未 commit」那一拍误触发，此刻 back() 还是旧文本，既误结算
--   又提前消费 _coin_pending_input，导致真正上屏的单字永远进不了缓冲（真机单字无法造词）。
--   ★ v2.12 notifier 统一「单字/词组一律累积」：删掉 v2.11 的 n>1「整词直接保存」分支，
--   它会在保存词组时清空 _coin_buf，把已累积的单字误 wipe（真机 之/田/回到家/吃饱 实测）。
--   notifier 回调拿不到 env 表，所以「是否在手动造词」用模块级 upvalue 预登记。
local _coin_pending_input = nil   -- 非 nil = 手动造词进行中（含反引号的原始 input）
local _coin_buf = {}              -- 逐字造词缓冲：累积已上屏的单字/词组（长按Z再按空格结束一次性保存）
local _coin_code_buf = {}         -- 逐字造词编码缓冲：累积每个单字对应的反引号编码段（作降级编码）
local _coin_last_size     = nil   -- 上次观察到的 commit_history.size（双判据①）
local _coin_last_text     = nil   -- 上次观察到的 back().text（双判据②）
local _coin_hooked        = false -- update_notifier 是否已连接
local _coin_hooked_schema = nil   -- 连接时对应的 schema_id（切方案时重连）

local function coin_hook_notifier(env)
    local ctx = env and env.engine and env.engine.context
    if not ctx then return end
    local sid = env.engine and env.engine.schema and env.engine.schema.schema_id
    if _coin_hooked and sid == _coin_hooked_schema then return end
    _coin_hooked_schema = sid
    _coin_hooked = true
    pcall(function()
        if ctx.update_notifier then
            ctx.update_notifier:connect(function(c)
                local size, bt = nil, nil
                pcall(function() size = c.commit_history.size end)
                pcall(function()
                    local b = c.commit_history and c.commit_history:back()
                    if b then bt = b.text end
                end)

                -- 首次只记基线（不把历史提交当新提交）
                if _coin_last_size == nil then
                    _coin_last_size = size
                    _coin_last_text = bt
                    return
                end

                -- ★ v2.11 双判据（同 auto_coined.lua detect_and_settle）：size 变 或 back 文本变 = 有新上屏。
                --   废弃旧「输入码非空变空」判据③——它在 bimkit 点选上屏时，会在「清空 composition
                --   但尚未 commit」那一拍就误触发：此刻 back() 还是上一条旧文本，既误结算，
                --   又提前消费 _coin_pending_input，等真正 commit 单字时 pending 已 nil，
                --   单字永远进不了缓冲（真机「单字无法进入造词」根因）。
                local has_new = (size ~= _coin_last_size) or (bt ~= nil and bt ~= _coin_last_text)
                _coin_last_text = (bt ~= nil) and bt or _coin_last_text
                _coin_last_size = size

                if not has_new then return end
                -- 非手动造词状态 ⇒ 忽略
                if _coin_pending_input == nil then return end
                -- bt 尚未就绪（清空 composition 那一拍，back 滞后）⇒ 不消费 pending，等下一拍
                if bt == nil or bt == "" then return end

                local pending_input = _coin_pending_input
                _coin_pending_input = nil
                local n = u8len(bt)
                if n >= 1 and not bt:find("%a") then
                    -- ★ v2.12 逐字造词：单字（n==1）或多字词组（n>1）都累积进缓冲，
                    --   统一由「长按Z再按空格」结束一次性保存。不再把 n>1 当「整词」直接保存——
                    --   v2.11 那样会把已累积的单字缓冲误清空（真机 之/田/回到家/吃饱 实测：
                    --   「之田」进缓冲后被「回到家」的整词保存 wipe 掉，词组独立成词、无法组合）。
                    _coin_buf[#_coin_buf + 1] = bt
                    _coin_code_buf[#_coin_code_buf + 1] = pending_input or ""
                    kcoin("ntf", "buf+1 [" .. bt .. "] => [" .. table.concat(_coin_buf) .. "]")
                else
                    kcoin("ntf", "skip 非合规 [" .. tostring(bt) .. "]")
                end
            end)
        end
    end)
end

local function commit_text_processor(key, env)
    local engine = env.engine
    local context = engine.context
    local composition = context.composition
    local segment = composition:back()
    local input_text = context.input
    local candidate_count = 0

    -- ★ 2026-11-03 修复：PC 端关闭官方 predictor（prediction「总联想」开关）。
    --   predictor 上屏后会在 composition 里建「空段」吐预测候选（「我/第/然/微信号」等），
    --   空段让 composition 非空 ⇒ is_composing()/has_menu() 恒 true，标点键被误判乱出字。
    --   PC 端智能联想本就被 smart_assoc 关掉（is_mobile 门控），官方 predictor 是唯一漏网者。
    --   只在 PC（not is_mobile）关；移动端不动（移动端联想候选正是挂在 predictor 空段上）。
    --   ⚠ 只在当前为 true 时才 set（get_option 为 true → 设 false），避免每次按键反复触发
    --   option_update_notifier 引发 RefreshNonConfirmedComposition 的副作用。
    if not is_mobile() and context:get_option("prediction") then
        context:set_option("prediction", false)
    end

    -- ★ 惰性连接 update_notifier（首次连接后 no-op），让「点候选栏上屏」也能触发手动造词
    coin_hook_notifier(env)

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
        else
            -- ★ 2026-11-03 修复：不在「正在打码字母」状态（空状态/标点/其它）时立即清空
            --   二三候选缓存。原实现只在打码时刷新缓存、上屏后 input 为空不再走刷新分支，
            --   导致「打『测试』上屏后按分号/引号把残留的『测度/小幅度』顶上来」。
            env.last_2th_text = {text="", type=""}
            env.last_3th_text = {text="", type=""}
        end
    end

    local key_code_num = tonumber(key.keycode) or key.keycode
    local is_space_key = (key_code_num == 0x20) or (key_code_num == 32)

    -- ★ 2026-10-31 v2.12 徐码式手动造词（逐字/词组上屏 + 累积保存）：
    --   这里「预登记」正在造词（input 含反引号），让 table_translator@mkst 吐出的
    --   sentence 候选（词组）或单字重码（逐字）在空格/点选上屏后，由
    --   coin_hook_notifier 的 update_notifier 统一结算。单字与词组一律累积进缓冲，
    --   最后按「长按Z（`）再按空格」一次性保存。
    local function update_manual_userphrase()
        if input_text and input_text:find("`", 1, true) then
            _coin_pending_input = input_text
            -- ★ 2026-11-01 性能修复：造词开始（长按Z 出现反引号）就预加载全量字典。
            --   原实现要到「长按Z+空格保存」时才在 generate_standard_code 里首次触发
            --   build_dicts（读 14.8 万行 + 布隆构建 ≈ 672ms，真机更慢）⇒ 保存那一拍卡顿。
            --   提前到这里（用户正按着 Z、尚未开始逐字）预加载，保存时查码 O(字数)。
            --   char_dict_done 常驻，已加载则本调用 O(1) 零开销。
            ensure_dict_loaded()
        else
            _coin_pending_input = nil
            -- ★ 用户开始输入非反引号内容（非空）⇒ 放弃未结束的逐字缓冲
            if input_text and input_text ~= "" and #_coin_buf > 0 then
                kcoin("buf", "abandon [" .. table.concat(_coin_buf) .. "]")
                _coin_buf = {}
                _coin_code_buf = {}
            end
        end
    end

    update_manual_userphrase()

    -- ★ v2.12 逐字造词结束键 = 长按Z（`）再按空格（放在 has_menu 之前，优先判定）：
    --   逐字选完所有字/词组后，长按一次 Z（输入区出现纯反引号 `），再按空格 = 保存整词。
    --   此信号与「空格上屏联想候选」不冲突：联想时 input 为空，而这里要求 input 为纯反引号；
    --   与「空格上屏编码候选」也不冲突：编码时 input 含字母（如 `rt），不匹配 ^`+$。
    if is_space_key and #_coin_buf > 0 and input_text and input_text:match("^`+$") then
        local word = table.concat(_coin_buf)
        local code_input = table.concat(_coin_code_buf)
        _coin_buf = {}
        _coin_code_buf = {}
        _coin_pending_input = nil
        if valid_word(word) then
            fileappendtext(userphrasepath, word, code_input, nil)
            kcoin("end", "OK [" .. word .. "]")
        else
            kcoin("end", "discard [" .. word .. "]")
        end
        context:clear()  -- 清掉输入区残留的反引号，吞掉本次空格（不插入空白）
        return 1
    end

    -- ★ S88：原先这里有一段S87 诊断探针 + 「智能联想段豁免空格return 2」，
    --   已整体删除。理由见文件头 S88 撤销记录（长按语音是 App 内置手势，Lua 别碰空格）。
    --   空格语义：有菜单就上屏选中（首）候选——造词合成候选也是普通候选，走同一路径。
    if is_space_key and context:has_menu() then
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

    -- ★ 诊断：缓冲非空但本次空格未触发结束 ⇒ 打印 input 以便定位结束键时序
    if is_space_key and #_coin_buf > 0 then
        kcoin("end", "space buf=" .. #_coin_buf .. " input=[" .. tostring(input_text) .. "] 未匹配^`+$")
    end

    -- 单引号键上屏第三候选（有候选菜单时）
    -- ★ 手机上禁用。26 键布局「L 上滑 = '」本来是要打引号的，
    --   在这里被截胡 ⇒ 打码出候选时上滑 L 会莫名其妙上屏第 3 候选。
    --   手机上直接点候选栏更顺手，这个快捷键只留给 PC。
    -- ★ 2026-11-02 二次修复：原 `has_menu` / `is_composing` 判据都靠不住——
    --   predictor 在上屏后会建「空段」吐预测候选（「我/第/的/论」等），空段让
    --   composition 非空 ⇒ is_composing() 恒为 true，于是上屏后按 `'` 会把
    --   **上一次打码缓存的第 3 候选**（如 imya 的「小幅度」）顶上来（真机乱出字根因）。
    --   改用 `context.input ~= ""`（真正的「正在打码」判据，predictor 空段不消耗 input），
    --   +「确有第 3 候选才 return 1」，否则放行给 pair_punct 打单引号。
    if key.keycode == 0x27 and not is_mobile() then
        klog("Submit_text", "apostrophe key pressed, input=[" .. tostring(context.input) .. "] input_len=" .. tostring(#(context.input or "")) .. " has_menu=" .. tostring(context:has_menu()) .. " is_composing=" .. tostring(context:is_composing()) .. " comp_empty=" .. tostring(composition:empty()) .. " prediction=" .. tostring(context:get_option("prediction")) .. " last_3th_text=" .. (env.last_3th_text and env.last_3th_text.text or "nil"))
        if context.input and context.input ~= "" and env.last_3th_text and env.last_3th_text.text ~= "" then
            klog("Submit_text", "committing 3rd candidate: " .. env.last_3th_text.text)
            context:clear()
            engine:commit_text(env.last_3th_text.text)
            if _G.InputStats_Report then _G.InputStats_Report(env.last_3th_text.text) end
            return 1
        end
    end

    -- 分号上屏第二候选（同上：手机上禁用，理由一样；判据同为 `input ~= ""`）
    if key.keycode == 0x3B and not is_mobile() then
        klog("Submit_text", "semicolon key pressed, input=[" .. tostring(context.input) .. "] input_len=" .. tostring(#(context.input or "")) .. " has_menu=" .. tostring(context:has_menu()) .. " is_composing=" .. tostring(context:is_composing()) .. " comp_empty=" .. tostring(composition:empty()) .. " prediction=" .. tostring(context:get_option("prediction")) .. " last_2th_text=" .. (env.last_2th_text and env.last_2th_text.text or "nil"))
        if context.input and context.input ~= "" and env.last_2th_text and env.last_2th_text.text ~= "" then
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
    -- 获取原始输入（不受 abbrev 规则影响），用于混输方案
    local raw_input = ""
    if env and env.engine and env.engine.context then
        raw_input = env.engine.context.input or ""
    end
    if raw_input == "" and seg then
        raw_input = seg.input or ""
    end
    if raw_input == "" then
        local ctx = seg and seg._context
        if ctx and ctx.input then
            raw_input = ctx.input or ""
        end
    end

    -- 优先使用原始输入，避免 abbrev 规则导致的编码截断
    local query_input = raw_input:match("^[a-z]+$") or input
    if not query_input or not query_input:match("^[a-z]+$") then
        return
    end
    -- 限制：输入少于2个字母时不显示自造词，优先一级简码
    if #query_input < 2 then
        return
    end

    -- 方案 B：从 C++ UserDb 前缀查询（内存哈希，无磁盘 IO），替代 io.open 读 txt
    uc_migrate_once()
    local db = uc_open()
    if not db then return end

    local use_dual_key = is_14key_layout(env)
    local norm_input = use_dual_key and normalize_14key(query_input) or query_input

    local seen = {}
    local function yield_user_coined(text, code, quality, is_temp)
        if seen[text] then
            return
        end
        seen[text] = true
        -- 自动临时词在候选码后加 ☯（与手动造词视觉标记一致的图标）
        local disp = is_temp and (code .. "☯") or code
        local cand = Candidate("user_coined", seg.start, seg._end, text, disp)
        cand.quality = quality
        yield(cand)
    end

    local code_prefix
    -- ★ 方案 B：匹配逻辑不变，只是候选来源从「缓存 list」改为「UserDb query 结果」。
    local function try_match(text, code, is_temp)
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
            -- ★ 2026-10-28 修复：自动临时词【只在整码精确匹配时浮现】（防候选污染），
            --   v2.19 补 14 键模糊整码匹配。quality 950 确保撞码时 ☯ 候选排前排可点选转正。
            if exact_match then
                yield_user_coined(text, code, 950, true)
                kcoin("recall", "临时词命中 [" .. text .. "]=" .. code .. " input=" .. query_input)
            elseif dual_exact_match then
                yield_user_coined(text, code, 900, true)
                kcoin("recall", "临时词模糊命中 [" .. text .. "]=" .. code .. " input=" .. query_input)
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

    -- 前缀查询：只查与 query_input 首字母同键的 code 前缀（26键1前缀 / 14键2前缀）
    local first = query_input:sub(1, 1)
    local prefixes = { first }
    if use_dual_key then
        local l, r = get_key_pair(first)
        prefixes = { l }
        if r then prefixes[#prefixes + 1] = r end
    end

    local function query_prefix(pfx)
        local acc = db:query("e\t" .. pfx)
        if acc then
            for k in acc:iter() do
                local text, code = uc_parse_key(k)
                if text then try_match(text, code, false) end
            end
        end
        acc = db:query("a\t" .. pfx)
        if acc then
            for k in acc:iter() do
                local text, code = uc_parse_key(k)
                if text then try_match(text, code, true) end
            end
        end
    end

    for _, p in ipairs(prefixes) do
        query_prefix(p)
    end
end

-- =================================================================
-- == 模块导出 ==
-- =================================================================

rawset(_G, "user_coined_translator", user_coined_translator)

-- ★ 方案 B：给 auto_coined.lua / user_coined_cmd.lua 的 UserDb 存储钩子。
--   替代旧的 UserCoined_InvalidateCache（删词失效缓存）与 UserCoined_SetTempEntries
--   （整批替换临时词缓存）—— 方案 B 下数据源是 C++ UserDb，写后天然即时可见，无需缓存失效。
rawset(_G, "UserCoined_DB_PutTemp", uc_put_temp)
rawset(_G, "UserCoined_DB_EraseTemp", uc_erase_temp)
rawset(_G, "UserCoined_DB_PutManual", uc_put_manual)
rawset(_G, "UserCoined_DB_EraseManual", uc_erase_manual)
rawset(_G, "UserCoined_DB_HasManual", uc_has_manual)
rawset(_G, "UserCoined_DB_ListManual", uc_list_manual)
rawset(_G, "UserCoined_DB_ListTemp", uc_list_temp)
rawset(_G, "UserCoined_DB_ClearManual", uc_clear_manual)
rawset(_G, "UserCoined_DB_ClearTemp", uc_clear_temp)
rawset(_G, "UserCoined_DB_Migrate", uc_migrate_once)

-- ★ 2026-11-01 性能优化 A4：释放大字典，消除「关闭造词后卡顿延续、切方案才恢复」。
--   根因：char_dict_cache（2.4 万单字）懒加载后常驻内存，LuaJIT 每次 GC 标记都要扫
--   这几万条 ⇒ GC 停顿明显。关闭 auto_coined 开关只是不再查码/造词，但大字典已常驻，
--   GC 压力仍在 ⇒ 打字仍卡。切方案会重建 Lua 状态机、清空 local 缓存 ⇒ 恢复流畅。
--   这里暴露 release 钩子：auto_coined 检测到「开关开→关」边沿时调用，主动释放大字典，
--   下次需要查码时再懒加载（首次重载那一下有开销，但换来关闭后彻底不卡）。
--   （2026-11-01 后 phrases 已废弃，char_dict_phrases 恒 nil，保留置 nil 仅为防呆。）
local function release_dict()
    char_dict_cache   = nil
    char_dict_phrases = nil
    char_dict_done    = false
    char_code_cache   = {}
    char_code_cache_n = 0
    bloom_blocks      = nil
end
rawset(_G, "UserCoined_ReleaseDict", release_dict)

return commit_text_processor