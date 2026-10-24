--[[
    wubi_pinyin_filter.lua - 五笔候选筛选过滤器（支持点击模糊/右滑精确）
    作者: Autophotia
    主页: https://github.com/Autophotia/TouchWubi
    日期: 2026-06-30（修订）

    【功能概述】
    1. 第五码拼音首字母筛选（可配置首字/末字）
    2. 错误编码过滤
    3. z键拼音反查放行
    4. 逐位区分「左字母（点击/左滑）」与「右字母（右滑）」：
       - 左字母：双键模糊匹配（如 as 键的 a，该位可命中 a 或 s）
       - 右字母：只精确匹配该字母本身（如 as 键的 s，该位只命中 s）
       键对关系由 speller/algebra 的 derive/右/左/ 规则自动解析得出，无需外部依赖。
       注：主题层 click 与 swipe_left 发送同一字符，故「左滑」与「点击」同为模糊；
           「左滑精确」在既定主题下无法实现（详见排查报告）。

    【配置选项】（均为可选）
    wubi_pinyin_filter:
      use_key_pairs: true      # 是否启用双键模糊匹配（默认自动检测，有 derive 规则则启用）
      use_last_char: false     # true=末字拼音首字母, false=首字（默认false）
]]

local basic = require('lib/basic')
local utf8chars = basic.utf8chars

-- ===================================================================
-- 动态构建键对映射（从 derive 规则解析）
-- ===================================================================

local function build_key_mapping(config)
    local left_to_right = {}
    
    local algebra = config:get_list('speller/algebra')
    if not algebra then return left_to_right end
    for i = 0, algebra.size - 1 do
        local item = algebra:get_value_at(i)
        if item and item.value then
            local from, to = item.value:match("^derive/([a-z])/([a-z])/$")
            -- derive/右/左/ ⇒ left_to_right[左] = 右，其键恰好是左字母表
            if from and to and from ~= to then
                left_to_right[to] = from
            end
        end
    end
    return left_to_right
end

-- ===================================================================
-- 检测是否为双键布局（用于自动启用 use_key_pairs）
-- ===================================================================
local function has_derive_rules(config)
    local algebra = config:get_list('speller/algebra')
    if not algebra then return false end
    for i = 0, algebra.size - 1 do
        local item = algebra:get_value_at(i)
        if item and item.value then
            local from, to = item.value:match("^derive/([a-z])/([a-z])/$")
            if from and to and from ~= to then return true end
        end
    end
    return false
end

-- ===================================================================
-- 初始化
-- ===================================================================

-- 读取「前缀预测」限量配置；未配置或负数 ⇒ 用默认值（见 init 里三行调用）
local function read_cap(config, path, default)
    local v = config:get_int(path)
    if v == nil or v < 0 then return default end
    return v
end

-- ⚠ 前向声明：真正的实现在下方「拼音缓存」区（它要用到那两张表）。
--   这里必须先声明成 local，否则 init 里的 reset_pinyin_caches() 会去调**全局**
--   同名变量（= nil）⇒ init 直接抛错中断 ⇒ env.spll_rvdb / predict_cap 全都设不上
--   （表现：候选不限量地爆出来、第 5 码筛选整体失效）。
local reset_pinyin_caches

local function init(env)
    local config = env.engine.schema.config

    -- ★ S15：新 env = 新的反查库实例 ⇒ 旧缓存一律作废（详见 reset_pinyin_caches）
    reset_pinyin_caches()

    -- 读取拼音反向数据库
    local spll_rvdb_name = config:get_string('lua_reverse_db/spelling')
    if spll_rvdb_name then
        env.spll_rvdb = ReverseDb('build/' .. spll_rvdb_name .. '.reverse.bin')
    end

    -- 构建键对映射（每个方案独立，避免方案切换时映射混乱）
    env.left_to_right = build_key_mapping(config)

    -- 是否混输方案（engine/mixed_input）。第十八轮新增：5 码的「整串是完整拼音拼写 ⇒
    -- 拼音优先」只在混输方案生效 —— 纯五笔方案（ly_wubi / ly_wubi_14）的反查只服务
    -- z 键，其 5 码行为不该被顺带改掉。
    env.is_mixed = config:get_bool('engine/mixed_input') or false

    -- 判断是否启用双键匹配（显式配置优先）
    local use_pairs = config:get_bool('wubi_pinyin_filter/use_key_pairs')
    if use_pairs == nil then
        use_pairs = has_derive_rules(config)
    end
    env.use_key_pairs = use_pairs

    -- 读取末字/首字配置
    local use_last = config:get_bool('wubi_pinyin_filter/use_last_char')
    env.use_last_char = use_last ~= nil and use_last or false

    -- 【码长分层】1~3 码各允许带几条「前缀预测」候选（type=completion）。
    -- 0 = 该码长完全不预测（只出精确命中）；缺省/负数 = 用下面的默认值。
    env.predict_cap = {
        [1] = read_cap(config, 'wubi_pinyin_filter/predict_cap_1', 3),
        [2] = read_cap(config, 'wubi_pinyin_filter/predict_cap_2', 6),
        [3] = read_cap(config, 'wubi_pinyin_filter/predict_cap_3', 5),
    }
end

-- ===================================================================
-- 工具函数
-- ===================================================================
local function get_candidate_wubi_code(cand)
    local comment = cand.comment or ""
    local preedit = cand.preedit or ""

    -- 优先从 comment 中提取编码（new_spelling 会修改 comment 格式）
    -- 策略1：提取最后一个 〈...〉 中的纯字母内容（通常是编码）
    if comment ~= "" then
        local extracted = comment:match("〈([^〉]+)〉$")
        if extracted then
            extracted = extracted:gsub("[%s%p]", ""):lower()
            if extracted ~= "" and extracted:match("^[a-z]+$") and #extracted >= 2 then
                return extracted
            end
        end
        -- 策略2：尝试提取所有括号中的纯字母
        for code in comment:gmatch("〈([^〉]+)〉") do
            local clean_code = code:gsub("[%s%p]", ""):lower()
            if clean_code ~= "" and clean_code:match("^[a-z]+$") and #clean_code >= 2 then
                return clean_code
            end
        end
        -- 策略3：从整个 comment 中提取最长的连续纯字母序列
        local longest_code = ""
        for code in comment:gmatch("[a-z]+") do
            if #code > #longest_code and #code >= 2 then
                longest_code = code
            end
        end
        if longest_code ~= "" then
            return longest_code
        end
    end

    -- 回退到 preedit
    preedit = preedit:gsub("[%s%p]", ""):lower()
    if preedit ~= "" then return preedit end

    -- 最后尝试从 comment 中提取（去掉标点后）
    if comment ~= "" then
        local extracted = comment:match("〈([^〉]+)〉")
        if extracted then return extracted:lower() end
        comment = comment:gsub("[%s%p]", ""):lower()
        if comment ~= "" then return comment end
    end
    return ""
end

-- 构建输入串每一位允许的字母集合（逐位判定）
--   左字母（点击/左滑）→ { 左字母, 与之配对的右字母 }  = 模糊
--   右字母（右滑）或其它字符 → { 该字符 }              = 精确
-- left_to_right 由 speller/algebra 的 derive/右/左/ 解析而来，其键恰好是左字母表。
local function build_letter_sets(input_str, max_len, use_pairs, left_to_right)
    max_len = max_len or #input_str
    local sets = {}
    for i = 1, max_len do
        local ch = input_str:sub(i, i)
        if use_pairs and left_to_right[ch] then
            sets[i] = {ch, left_to_right[ch]}
        else
            sets[i] = {ch}
        end
    end
    return sets
end

local function matches_letter_sets(candidate_code, letter_sets)
    if not candidate_code or candidate_code == "" then return false end
    local need = #letter_sets
    if #candidate_code < need then return false end
    for i = 1, need do
        local char = candidate_code:sub(i, i)
        local set = letter_sets[i]
        local found = false
        for _, letter in ipairs(set) do
            if char == letter then
                found = true
                break
            end
        end
        if not found then return false end
    end
    return true
end

-- ===================================================================
-- 拼音读音提取（供 reverse_lookup 候选做「点击模糊 / 右滑精确」筛选）
-- 数据源：lua_reverse_db/spelling（wb_spelling）
--         格式 [字根, 五笔码, 拼音, 字符集]，拼音段形如 sī_sāi、nǚ_rǔ、lüè
-- ===================================================================
local TONE_MAP = {
    ["ā"] = "a", ["á"] = "a", ["ǎ"] = "a", ["à"] = "a",
    ["ē"] = "e", ["é"] = "e", ["ě"] = "e", ["è"] = "e",
    ["ī"] = "i", ["í"] = "i", ["ǐ"] = "i", ["ì"] = "i",
    ["ō"] = "o", ["ó"] = "o", ["ǒ"] = "o", ["ò"] = "o",
    ["ū"] = "u", ["ú"] = "u", ["ǔ"] = "u", ["ù"] = "u",
}
local U_UMLAUT = { ["ü"] = true, ["ǖ"] = true, ["ǘ"] = true, ["ǚ"] = true, ["ǜ"] = true }
local E_LIKE = { ["e"] = true, ["ē"] = true, ["é"] = true, ["ě"] = true, ["è"] = true }

-- 把「带声调的显示式拼音」转为 librime 的规范拼写：
--   sī → si、nǚ → nv、lǜ → lv、lüè → lue、nüè → nue
local function normalize_pinyin(s)
    if not s or s == "" then return "" end
    local chars = utf8chars(s)
    local out = {}
    for i = 1, #chars do
        local ch = chars[i]
        if U_UMLAUT[ch] then
            -- ü 后接 e（含带声调的 e）写成 ue，否则写成 v
            out[#out + 1] = E_LIKE[chars[i + 1]] and "u" or "v"
        else
            out[#out + 1] = TONE_MAP[ch] or ch
        end
    end
    return table.concat(out)
end

-- jqxy 后的 u 在 Rime 规范拼写里写作 v（对标 speller/algebra 的
-- derive/^([jqxy])u/$1v/）。显示式拼音 yu/jue 等必须同时给出 yv/jve，
-- 否则 14 键下用右滑输入的 yv（雨）永远匹配不上读音 yu。
local JQXY = { j = true, q = true, x = true, y = true }
-- n/l 后的 üe 在同一套代数里写作 ve（derive/^([nl])ue$/$1ve/）。
-- 显示式 lüè/nüè 归一化后得到 "lue"/"nue"，必须同时给出 "lve"/"nve"，
-- 否则「点 L + 点 V + 点 E」输入 lve 时「略」会被判为不匹配而误杀。
local NL = { n = true, l = true }

-- 汉字 → 全部规范拼音读音（多音字拆开），带缓存
-- ★ 2026-09-29 S14：强引用 + O(1) 计数（原来是 __mode="v" 弱值表，GC 一跑就整层失效）
local pinyin_readings_cache = {}
local pinyin_readings_cache_n = 0
local MAX_READINGS_CACHE_SIZE = 3000
local function readings_cache_put(k, v)
    if k == nil or k == '' then return v end
    if pinyin_readings_cache_n >= MAX_READINGS_CACHE_SIZE then
        pinyin_readings_cache, pinyin_readings_cache_n = {}, 0
    end
    if pinyin_readings_cache[k] == nil then
        pinyin_readings_cache_n = pinyin_readings_cache_n + 1
    end
    pinyin_readings_cache[k] = v
    return v
end

local function get_char_pinyin_readings(char, spll_rvdb)
    if not char or char == "" or not spll_rvdb then return nil end
    local cached = pinyin_readings_cache[char]
    if cached then return cached end

    local ok, raw = pcall(function() return spll_rvdb:lookup(char) end)
    if not ok or not raw or raw == "" then return nil end
    local clean = raw:gsub("※", "")
    -- 反查库里的值是 `[字根,五笔编码,拼音,GB2312]`，拼音在第 3 段。
    local py = clean:gsub('%[(.-),(.-),(.-),(.-)%]', '%3')
    if py == "" or py == clean then
        -- ★ S15 兜底：老 build 可能是 3 段（没有 GB2312 那一列）。
        --   少了这一段，上面 4 段匹配不上 ⇒ 会掉到「取第一个逗号前的串」= 字根，
        --   于是每个字的「读音」都变成字根 ⇒ 第 5 码拼音筛选整片失效。
        py = clean:gsub('%[(.-),(.-),(.-)%]', '%3')
    end
    if py == "" or py == clean then
        py = clean:match("^([^,]+)")
    end
    if not py or py == "" then return nil end

    local readings = {}
    for one in py:gmatch("[^_]+") do
        local norm = normalize_pinyin(one)
        if norm ~= "" then
            readings[#readings + 1] = norm
            local head, second = norm:sub(1, 1), norm:sub(2, 2)
            -- 追加 jqxy 变体：yu→yv、jue→jve、juan→jvan、jun→jvn …
            if JQXY[head] and second == "u" then
                readings[#readings + 1] = head .. "v" .. norm:sub(3)
            end
            -- 追加 n/l 的 üe 变体：lue→lve、nue→nve
            if NL[head] and norm:sub(2) == "ue" then
                readings[#readings + 1] = head .. "ve"
            end
        end
    end
    if #readings == 0 then return nil end
    readings_cache_put(char, readings)
    return readings
end

-- 只有这些类型的候选才把 comment/preedit 中的字母当作「五笔编码」参与按键筛选；
-- 其余类型一律放行，避免把非编码字段当判据而误杀（如候选被重建后 preedit 丢失）。
-- reverse_lookup（拼音反查）不走这里，已在上方按「候选自身读音」单独处理。
local WUBI_CODE_TYPES = {
    table = true,        -- 码表
    user_table = true,   -- 用户词
    completion = true,   -- 前缀补全
    table_phrase = true, -- 码表词组
    user_coined = true,  -- Submit_text.lua 的自造词（comment 即五笔编码）
}

-- 拼音直查翻译器（table_translator@pinyin_direct）产出的候选，quality 恒 ≥ 1000。
--   ★ 与 ly_wubi_pinyin_14.schema.yaml 的 pinyin_direct/initial_quality 绑定，
--     改那边必须同步改这里（super_sequence.lua 的 PINYIN_DIRECT_MIN_QUALITY 同理）。
--   用途：在「第 5 码」分支里判断「输入串本身就是一个吃满全串的合法拼音码」，
--         见下方 pure_code_len == 5 分支对 pinyin_cover 的说明。
local PINYIN_DIRECT_MIN_QUALITY = 1000

local function matches_prefix(cand, input_str, n, use_pairs, left_to_right, spll_rvdb, use_last_char)
    if n == 0 then return true end

    -- 拼音反查候选（reverse_lookup）必须用「候选自身的拼音读音」做判据。
    -- 否则 get_candidate_wubi_code 会取到五笔码（如「爱」epdc），或回落到 preedit
    -- （反查候选的 preedit 恒等于输入串，比对必然为真）——两种情况都会让
    -- 「点击模糊 / 右滑精确」失效，把同一按键的所有读音一律放行。
    if cand.type == "reverse_lookup" and spll_rvdb then
        local chars = utf8chars(cand.text or "")
        -- ★ 多字候选（拼音词组）整类放行。
        --   原因：get_char_pinyin_readings 只能取到「单字」读音，而这里拿去比对的是整串输入。
        --   词组只取末字的一个音节（3~4 位），却要匹配 5~8 位的输入串，
        --   matches_letter_sets 开头的 `#candidate_code < need` 会直接判 false
        --   ⇒ 所有拼音词组 100% 被误杀（xvyao→需要、xihuan→喜欢、jvyvan→剧院 …）。
        --   词组重码率极低，「点击模糊 / 右滑精确」本来就是为单字重码设计的筛子，
        --   对词组不做按键筛选。
        --   （z 键反查在 filter 开头因 ^z 整段放行，一直是正常的，故该缺陷只在混输模式暴露。）
        if #chars > 1 then return true end
        local target = nil
        if #chars > 0 then
            target = use_last_char and chars[#chars] or chars[1]
        end
        if target then
            local readings = get_char_pinyin_readings(target, spll_rvdb)
            if readings then
                local letter_sets = build_letter_sets(input_str, n, use_pairs, left_to_right)
                for _, py in ipairs(readings) do
                    if matches_letter_sets(py, letter_sets) then
                        return true
                    end
                end
                return false
            end
        end
    end

    -- 类型白名单：非码表类候选的 comment/preedit 不代表编码，直接放行
    if not WUBI_CODE_TYPES[cand.type] then return true end

    local wubi_code = get_candidate_wubi_code(cand)
    if wubi_code == "" then return true end

    local letter_sets = build_letter_sets(input_str, n, use_pairs, left_to_right)
    
    if matches_letter_sets(wubi_code, letter_sets) then
        return true
    end
    
    local preedit = cand.preedit or ""
    preedit = preedit:gsub("[%s%p]", ""):lower()
    if preedit ~= "" then
        return matches_letter_sets(preedit, letter_sets)
    end
    
    return false
end

-- ===================================================================
-- 【第十八轮补2】「整串就是一个完整拼音拼写」的别名感知判据
--
-- 它和 matches_prefix 的区别只有一个字：把 n 取成**整串长度**，而不是前 4 位。
-- 同一套「逐位字母集合」比较，换个长度就是另一层语义：
--     matches_prefix(上, "agang", 4) → true   「吃掉前 4 位」= 4 码前缀语义
--     matches_prefix(上, "agang", 5) → true   「吃掉整串」    = 整串是一条完整拼音
-- 也就是：单字反查候选的**整个读音**能被输入串逐位（含点击别名）对上。
--
-- 为什么必须补这条：第 5 码分支原有的 is_exact_pinyin_input 做的是
--   「输入串 == 候选逐字读音」的**字面**比较，而 14 键「点击=模糊」敲出来的是
--      shang → agang（点在 s 键上发出左字母 a、点在 h 键上发出 g）
--      cheng → xgeng（c→x、h→g）
--   别名串 ≠ 读音字面量（agang ≠ shang），字面判据一律判 false ⇒ 漏判。
--   另一条判据 pinyin_cover 依赖 pinyin_direct 翻译器的 quality ≥ 1000 候选，
--   而 super_sequence 的 sorter 在输入长度 ≥ 5 时会把这批候选整片丢弃
--   （它只在 PINYIN_HOIST_MIN_LEN..MAX_LEN 即 2~4 码才纳入），所以那条也拿不到数据。
--   本判据只依赖 reverse_lookup 候选 —— 它在 5 码下正常存在（实测 agang 有 44 条），
--   因此是唯一在 5 码可用的判据，且不需要改进任何其它文件。
--
-- ★ 只认「单字」候选：matches_prefix 对多字（词组）候选一律直接 return true
--   （见它 `#chars > 1` 分支的说明）。若照搬，taned → 坦然地 这类拼音词组会让
--   判据恒真 ⇒ K 组「4 码五笔命中优先」（物极必反）被误杀。单字才有「整个读音」
--   这个概念可比。
-- ★ 只认「读音长度 == 整串长度」：否则 6 字母读音（如 chuang、zhuang）会被拿去
--   和 5 位输入逐位比较，多出来的尾音节被静默忽略，产生假阳性。
-- ===================================================================
-- full_letter_sets 由调用方用 build_letter_sets(input, #input, ...) 预算一次后传入：
-- 5 码下一批会有几十~上百条反查候选，逐条重建这张表纯属浪费（每条 5 次 table 分配）。
local function is_full_spell_cand(cand, full_letter_sets, n, spll_rvdb)
    if cand.type ~= "reverse_lookup" or not spll_rvdb then return false end
    local text = cand.text or ""
    -- 先用字节长度粗筛「单字」：一个 UTF-8 汉字 3 字节（扩展区 4 字节），
    -- 多字候选必定 > 4 字节 ⇒ 提前返回，省掉 utf8chars 的展开开销。
    if #text > 4 then return false end
    local chars = utf8chars(text)
    if #chars ~= 1 then return false end
    local readings = get_char_pinyin_readings(chars[1], spll_rvdb)
    if not readings then return false end
    for _, py in ipairs(readings) do
        if #py == n and matches_letter_sets(py, full_letter_sets) then
            return true
        end
    end
    return false
end

-- 拼音首字母缓存，避免重复查询反向数据库
-- ★ 2026-09-29 S14：改用**强引用 + O(1) 计数**。
--   原来是 __mode="v" 弱值表 ⇒ Lua 每次 GC 整层失效，会话越久 GC 越频繁、命中率越低；
--   老清理函数还要 pairs 全表遍历计数（3000 项 = 每次写缓存 3000 次迭代）。
local MAX_PINYIN_CACHE_SIZE = 3000
local pinyin_initial_cache = {}
local pinyin_initial_cache_n = 0

-- 存值：满了整层丢弃（一次性摊销，不再 pairs 遍历）
local function pinyin_cache_put(k, v)
    if k == nil or k == '' then return v end
    if pinyin_initial_cache_n >= MAX_PINYIN_CACHE_SIZE then
        pinyin_initial_cache, pinyin_initial_cache_n = {}, 0
    end
    if pinyin_initial_cache[k] == nil then
        pinyin_initial_cache_n = pinyin_initial_cache_n + 1
    end
    pinyin_initial_cache[k] = v
    return v
end

-- ★ 2026-09-29 S15：两张拼音缓存的显式重建入口。
--   强引用缓存换来性能，代价是「第一次算出来的值会被一直用下去」。万一那一刻
--   反查库还没就绪（真机部署/切方案/多进程抢 LevelDB 锁时都发生过），坏值就会被
--   永久记住。这里在 init（= 每次部署 / 切方案 / 重建引擎）时整层丢弃，
--   让缓存既能扛 GC，又不会把坏值带过整个会话。
reset_pinyin_caches = function()
    pinyin_readings_cache, pinyin_readings_cache_n = {}, 0
    pinyin_initial_cache, pinyin_initial_cache_n = {}, 0
end

-- ===================================================================
-- 汉字 → 拼音首字母集合
--
-- 【2026-09-28 修：零声母字（a / o / e 开头）第 5 码筛选不出来】
--   老实现有两处硬伤，叠加起来让「爱 / 安 / 欧 / 傲 / 鹅」这类字永远筛不中：
--   ① 直接对反查库的原始串取 sub(1,1)。反查库存的是**带声调的显示式拼音**
--      （爱=ài、欧=ōu、鹅=é），零声母的首字符是 à / ō / é 这类多字节字符，
--      而声母字（怕=pà、的=de）首字符恰好是 ASCII 字母 ⇒ 只有零声母会踩到。
--   ② 下面的 valid_initials 白名单里没有 a / o / e ⇒ 就算拿到了 'a' 也会被判非法。
--   修法：读音先过 normalize_pinyin（去声调、ü→v/u），再取首字母。
--
-- 【多音字】返回「所有读音的首字母」而不是只取第一个读音（长=cháng/zhǎng 两个都算），
--   与「拼音首字母筛选」的语义一致：这个字只要**有**这个读法就该留下。
-- ===================================================================
local function get_pinyin_initials(char, spll_rvdb)
    if not char or char == '' or not spll_rvdb then return nil end

    -- 优先从缓存中获取
    if pinyin_initial_cache[char] then
        return pinyin_initial_cache[char]
    end

    -- get_char_pinyin_readings 已做 normalize_pinyin（去声调）与多音字拆分
    local readings = get_char_pinyin_readings(char, spll_rvdb)
    if not readings then return nil end

    local set = {}
    for i = 1, #readings do
        local pinyin = readings[i]
        local initial = pinyin:sub(1, 1):lower()
        if pinyin:sub(1, 2) == 'zh' then initial = 'z'
        elseif pinyin:sub(1, 2) == 'ch' then initial = 'c'
        elseif pinyin:sub(1, 2) == 'sh' then initial = 's'
        end
        set[initial] = true
    end
    if next(set) == nil then return nil end

    -- 缓存结果（强引用 + O(1) 计数）
    pinyin_cache_put(char, set)

    return set
end

-- 首字母集合与筛选集合是否有交集（多音字任一读音命中即可）
local function initials_hit(initials, filter_set)
    if not initials or not filter_set then return false end
    for ch in pairs(initials) do
        if filter_set[ch] then return true end
    end
    return false
end

-- 第五码的首字母筛选集合：左字母（点击/左滑）模糊，右字母（右滑）精确
local function build_pinyin_filter_set(letter, left_to_right, use_pairs)
    local set = {}
    -- ★ 必须含 a / o / e：零声母字（爱 ài、安 ān、欧 ōu、傲 ào、鹅 é、儿 ér…）
    --   的拼音首字母就是 a / o / e，缺了它们第 5 码筛选对这些字完全失效。
    local valid_initials = {
        a=true,b=true,c=true,d=true,e=true,f=true,g=true,h=true,j=true,k=true,
        l=true,m=true,n=true,o=true,p=true,q=true,r=true,s=true,t=true,
        w=true,x=true,y=true,z=true
    }
    local function add_if_valid(ch)
        if valid_initials[ch] then set[ch] = true end
    end

    if use_pairs and left_to_right[letter] then
        add_if_valid(letter)
        add_if_valid(left_to_right[letter])
    else
        add_if_valid(letter)
    end
    return set
end

local function make_candidate_key(cand) return tostring(cand.text) end

local function clone_candidate(cand, new_start, new_end, new_preedit)
    local comment = tostring(cand.comment or "")
    local text = tostring(cand.text or "")
    local preedit = new_preedit or tostring(cand.preedit or "")
    local new_cand = Candidate(cand.type, new_start, new_end, text, comment, preedit)
    if cand.quality then new_cand.quality = cand.quality end
    if cand.label then new_cand.label = cand.label end
    return new_cand
end

local function get_target_char(cand, use_last_char)
    local text = cand.text
    if not text or text == '' then return nil end
    local chars = utf8chars(text)
    if #chars == 0 then return nil end
    if use_last_char then
        return chars[#chars]
    else
        return chars[1]
    end
end

local function is_z_pinyin_input(input_str)
    return input_str:match("^z[a-z]+$") ~= nil
end

-- ===================================================================
-- 整串是否是一个「完整的拼音拼写」（第十八轮）
-- ===================================================================
-- 目的：5 码输入有两种意图 —— ①「4 码五笔 + 第 5 码拼音首字母筛选」（taned→物极必反），
--   ② 一个完整的拼音音节（shang→上、cheng→成）。判据必须能把两者分开。
--
-- 做法：取反查候选的字，用「逐字读音」去拼输入的整串 —— 能一字不差拼满 ⇒ 是完整拼音拼写。
--   · 上 → shang（1 字 1 读音）= 输入 shang ✓
--   · 成 → cheng ✓ ；两 → liang ✓ ；你好 → ni+hao = nihao ✓
--   · 坦然地 → tan+ran+de = tanrande ≠ taned ✗（正确的排除）
--   · 长 → chang/zhang 两个读音都试（多音字）
--   关键性质：**缩写式读音拼不出来**。`taned` 能被反查解析成「坦然地」靠的是音节缩写
--   （tan + e(an) + d(i)），而它的字号读音拼出来是 tanrande ≠ taned —— 这正是我们要的区分，
--   K 组（4 码命中优先）因此完全不受影响。
--
-- 成本：≤4 字、每字 ≤4 个读音，且带「前缀不匹配就剪枝」，实测可忽略（毫秒级以下）。
local MAX_SPELL_CHARS = 4

local function spellable_by(text, input, spll_rvdb)
    local chars = utf8chars(text or "")
    local m = #chars
    if m == 0 or m > MAX_SPELL_CHARS then return false end

    -- 逐字读音集合（get_char_pinyin_readings 自带缓存）
    local sets = {}
    for i = 1, m do
        local readings = get_char_pinyin_readings(chars[i], spll_rvdb)
        if not readings then return false end
        sets[i] = readings
    end

    local n = #input
    local function dfs(i, pos)
        if i > m then return pos == n + 1 end
        local list = sets[i]
        for k = 1, #list do
            local s = list[k]
            local e = pos + #s - 1
            -- 前缀剪枝：越界或与输入对不上就整枝砍掉
            if e <= n and input:sub(pos, e) == s then
                if dfs(i + 1, e + 1) then return true end
            end
        end
        return false
    end
    return dfs(1, 1)
end

-- 反查候选里只要有一个能被整串完整拼出 ⇒ 用户就是在打拼音
local MAX_SPELL_SCAN = 40     -- 最多检查多少条反查候选（5 码候选总量本就很小，留足余量）

local function is_exact_pinyin_input(input, reverse_cands, spll_rvdb, is_mixed)
    if not is_mixed or not spll_rvdb or not input or input == "" then return false end
    local n = #reverse_cands
    if n > MAX_SPELL_SCAN then n = MAX_SPELL_SCAN end
    for i = 1, n do
        if spellable_by(reverse_cands[i].text, input, spll_rvdb) then return true end
    end
    return false
end

-- ===================================================================
-- 主过滤器
-- ===================================================================
local function filter(input, env)
    local context = env.engine.context
    local input_str = context.input or ""

    -- ============================================================
    -- 【S15 诊断】/py<汉字>：把「零声母（韵母直拼）筛选」的中间量回显到候选栏。
    --
    -- 为什么要有这条：真机日志不落这些中间量（真机 log.info 还是同步写文件、
    -- 且只输出第一个参数），沙箱与真机各自的 build 又是独立部署出来的，
    -- 所以「韵母筛选在真机上到底卡在哪一步」只能现场回显。
    --
    -- 用法：输入 `/py`（后面带什么都行）
    --   输出：※ [爱 raw=<反查库原值> 读音=ai 首字母=a a?=Y] [安 …] …
    --     · raw = <nil> / <空>  ⇒ 真机反查库没这个字，或库没编译出来
    --     · 读音 是五笔编码（如 epdc）⇒ 反查库格式与预期不同，解析走错了分支
    --     · 首字母 不含 a / o / e ⇒ 读音没过 normalize_pinyin（声调没去掉）
    --     · a?=N 但首字母有 a ⇒ 筛选集合 build_pinyin_filter_set 没放行零声母
    --   ⚠ 命令必须纯 ASCII：真机 speller 不收汉字，`/py爱` 里的「爱」会被丢掉，
    --     所以字集写死在下面，而不是让用户传参。
    -- ============================================================
    if input_str:find("^/py") then
        -- 零声母（韵母直拼）自检样本 + 两个声母对照字（怕 pà / 的 de）
        local chars = utf8chars('爱安欧傲鹅儿二阿恩怕的')
        local parts = {}
        for i = 1, #chars do
            local ch = chars[i]
            local raw = '<no db>'
            if env.spll_rvdb then
                local ok, r = pcall(function() return env.spll_rvdb:lookup(ch) end)
                raw = (ok and r ~= nil) and tostring(r) or '<nil>'
            end
            local readings = get_char_pinyin_readings(ch, env.spll_rvdb)
            local ini = get_pinyin_initials(ch, env.spll_rvdb)
            local keys = {}
            if ini then for k in pairs(ini) do keys[#keys + 1] = k end end
            table.sort(keys)
            local fs = build_pinyin_filter_set('a', env.left_to_right, env.use_key_pairs)
            parts[#parts + 1] = string.format('[%s raw=%s 读音=%s 首字母=%s a?=%s]',
                ch, raw,
                readings and table.concat(readings, ',') or '<nil>',
                (#keys > 0) and table.concat(keys, ',') or '<nil>',
                initials_hit(ini, fs) and 'Y' or 'N')
        end
        yield(Candidate('pydbg', 0, #input_str,
            '※ ' .. ((#parts > 0) and table.concat(parts, ' ') or '用法：/py爱'),
            ''))
        return
    end

    if input_str:find("^/") or input_str:find("^z") then
        for cand in input:iter() do
            yield(cand)
        end
        return
    end

    local sanitized_input = input_str:gsub("[`' ]", "")
    local input_len = #sanitized_input
    local is_z_pinyin = is_z_pinyin_input(input_str)

    local pure_code = sanitized_input:gsub("[^a-z]", "")
    local pure_code_len = #pure_code

    if input_str:find("[`']") or sanitized_input:find("[^%a]") then
        if pure_code_len == 0 then
            for cand in input:iter() do
                yield(cand)
            end
            return
        end
        for cand in input:iter() do
            if not is_z_pinyin then
                if matches_prefix(cand, pure_code, pure_code_len, env.use_key_pairs, env.left_to_right, env.spll_rvdb, env.use_last_char) then
                    yield(cand)
                end
            else
                yield(cand)
            end
        end
        return
    end

    if is_z_pinyin then
        for cand in input:iter() do
            yield(cand)
        end
        return
    end

    if not env.spll_rvdb then
        for cand in input:iter() do
            if matches_prefix(cand, sanitized_input, input_len, env.use_key_pairs, env.left_to_right, env.spll_rvdb, env.use_last_char) then
                yield(cand)
            end
        end
        return
    end

    -- ============================================================
    -- 【第十四轮】输入长度 > 5：五笔已无码可依 ⇒ 只留拼音候选
    --
    -- 依据：五笔码表实际最长 4 码（ly_wubi.dict.yaml 实测码长分布 1:50 /
    -- 2:1108 / 3:5897 / 4:141173，没有任何 5 码条目），第 5 码是「拼音首字母
    -- 筛选」位（见下方 pure_code_len == 5 分支），也就是「4 码五笔 + 1 码拼音
    -- 首字母」= 4+1 码。到第 6 码，五笔不可能再有真正匹配的候选。
    -- 自造词/扩展词同理：Submit_text.generate_standard_code 与 wubi.extended.dict.yaml
    -- 的 encoder 公式（"AaAbBaBb" / "AaBaCaZa"）产出的一律是 4 码。
    --
    -- 实测（本机 librime，探针替换过滤器后取「过滤前」流派）：
    --   xihuan (6)  → reverse_lookup 2 条（喜欢、西幻） + phrase 6 条（以/又/经/纱/弓/糸） + sentence 1 条
    --   jintian(7)  → reverse_lookup 1 条（今天）        + phrase 8 条 + sentence 1 条
    --   gongzuo(7)  → reverse_lookup 1 条（工作）        + phrase 10 条 + sentence 1 条
    --   zhongguo(8) → reverse_lookup 4 条，无其它
    --   qqqqqq (6)  → 无 reverse_lookup，phrase/sentence 共 62 条
    -- 这些 phrase/sentence 全部来自 speller/algebra 的 abbrev 规则
    -- （abbrev/^([a-z]).+$/$1/ 把整串缩成首字母）与前缀补全，与用户敲的拼音串
    -- 无关，却因 quality 较高长期占据列表前排（旧版把它们排在拼音之后，"排后"仍
    -- 属噪声——第 6 码起用户已看不到任何五笔候选，把拼音挤到后排没有任何意义）。
    --
    -- 处理：该长度下只输出 reverse_lookup（拼音反查）候选，其它类型一律丢弃。
    -- 一条拼音都匹配不上时列表即为空——这正是期望行为：编码越长候选越精确，
    -- 全无匹配就不该有任何候选。空列表下引擎仍会处理回车/空格（上屏原始编码）。
    -- 性能：一次流式扫描，不再物化 reverses/others 两个数组；该长度候选总量
    -- 本就很小（4~62 条，远低于 2 键输入的 1002 条）。
    -- ============================================================
    if pure_code_len > 5 then
        for cand in input:iter() do
            if cand.type == "reverse_lookup"
               and matches_prefix(cand, sanitized_input, input_len, env.use_key_pairs, env.left_to_right, env.spll_rvdb, env.use_last_char) then
                yield(cand)
            end
        end
        return
    end

    -- ============================================================
    -- 【第十六轮】第 5 码：先看「有没有吃满前 4 码的真五笔命中」，再谈拼音
    --
    -- 本轮修的是：混输时第 5 码明明能筛出五笔候选，却被拼音反查整个抢走。
    -- 复现（本机 librime 实测）：输入 taned = 4 码 tane + 第 5 码 d
    --   · 前 4 码 tane 命中 彻骨(tame) / 物极必反(tsnr) / 很可怕(tsnr)
    --     —— 14 键下 a≡s、e≡r、n≡m 由 derive 规则等价，故 tane 即 tsnr。
    --   · 第 5 码按「末字拼音首字母」筛，应只剩 物极必反
    --     （反→f ✓；彻骨 骨→g ✗；很可怕 怕→p ✗）。
    --   · 但第十五轮判据是「reverse_cands 非空 ⇒ 只输出拼音」，而反查把 taned
    --     当成合法（缩写）拼音码解出了「坦然地」，于是 物极必反 被整片丢掉。
    -- 为什么反查能解出 taned：拼音方案 ly_pinyin_14 同样继承 14 键 derive 规则
    -- （r→e、m→n、f→d…），叠加 abbrev 音节缩写后
    --   tan + e(an) + d(i)  ⇒  tan ran di（坦然地）
    -- 所以「taned」既是五笔 4+1 码，又是一个合法拼音码。26 键没这问题：26 键第 5
    -- 码是原字母 f，整串 tsnrf 反查无解，只能走五笔筛选。
    --
    -- 硬判据：候选的「匹配段长度」orig_end（它吃掉了输入的前几个字符）
    --   · orig_end == 4 ⇒ 吃满前 4 码，真正的 4 码五笔命中（含 derive 等价）
    --     实测：taned→彻骨/物极必反/很可怕、khlgg→中国/跨国/贵国、
    --           xvyao→预订/预谋、tamen→彻骨(tame)、fffff→土/封堵/…
    --   · orig_end <  4 ⇒ 只吃掉 1~3 码，是简码 / abbrev 前缀命中
    --     实测：khlgz→中(kh)/足(kh)/盅(khl)、fffff→封(fff)、wqvbn→你(wq)；
    --           噪声同理：liang→国(l)、women→侬(wp)、nihao→尿
    --     （derive 规则全是等长替换，abbrev 只会缩短，故 orig_end==4 必定是 4 码全码命中）
    --   · orig_end == 5 ⇒ 吃满整串（反查 / 句子类），只认 reverse_lookup 那一类。
    --
    -- 出口优先级（本轮定案）：
    --   ① full_matched 非空        → 只输出它们
    --      （第 5 码确实筛出了 4 码五笔候选，拼音无权抢——就是用户要的"唯一候选"）
    --   ② 否则 reverse_cands 非空  → 只输出拼音候选
    --      （前 4 码没有真 4 码命中，而整串能当拼音读 ⇒ 是拼音输入：liang→21 条
    --        纯拼音、nihao→你好、xvyao→须要/需要、tamen→它们/衙门/他们/她们）
    --   ③ 否则                     → 输出 short_matched（简码/前缀命中的五笔候选）
    --      （khlgz→中/足/盅、fffff→封、wqvbn→你：这些串反查恒为空，旧行为不得变）
    --   ④ 三者皆空                 → 候选栏为空（合法的"清空"状态）
    -- ②优先于③是刻意的：liang 的 国(orig_end=1)、women 的 侬(=2)、nihao 的 尿(=2)
    -- 都是「简码撞上输入前 1~2 位」的噪声，一旦压过拼音，打拼音就会被无关单字顶掉。
    -- 性能：仍是一次流式扫描 + 两个小数组（5 码候选总量 ≤ 25 条），与第十五轮同量级。
    -- ============================================================
    if pure_code_len == 5 then
        local pinyin_filter = pure_code:sub(5,5):lower()
        local pinyin_filters = build_pinyin_filter_set(pinyin_filter, env.left_to_right, env.use_key_pairs)
        local full_matched = {}
        local full_seen = {}
        local short_matched = {}
        local short_seen = {}
        -- 拼音反查候选单独收集：反查场景下输入串本身就是拼音，「第 5 位」不是首字母筛选位。
        -- 让它们参与这套筛选会被整体丢弃（词组首当其冲），故单独收集、统一输出。
        local reverse_cands = {}
        local reverse_seen = {}

        -- ============================================================
        -- 【第十八轮补】「整串本身就是一个合法拼音码」的判据 pinyin_cover
        --
        -- 由来：14 键布局下「点击=模糊」，点击整串字母敲出的其实是别名串 ——
        --   shang → agang（s 的别名 a、h 的别名 g），cheng → xgeng（c→x、h→g）。
        -- 别名串经 derive 展开可覆盖 4 码五笔词组的编码，于是
        --   西贡(sgam) ⊂ sgamg、绝不后悔(xgrn) ⊂ xgrng
        -- 成为「补全命中」，其 orig_end == 4 ⇒ 旧逻辑走
        --   ① full_matched 非空 ⇒ 只显示它们
        -- 整个候选栏就只剩「西贡」「绝不后悔」，一条拼音候选都不剩
        -- （实测 agang → 西贡、xgeng → 绝不后悔，与用户报的现象逐字一致）。
        -- 而 z 在 14 键里没有别名对象（derive 表里没有 z），别名串仍是 zgang，
        -- 五笔码表没有以 z 开头的码 ⇒ 命中不了 ⇒ 这就是「zh 正常、ch/sh 异常」的原因。
        --
        -- 判据：拼音直查翻译器（pinyin_direct，quality ≥ 1000）存在一条
        --   「匹配段吃满整串」（orig_end == pure_code_len）的候选
        --   ⇒ 这个 5 码串本身就是一条完整拼音，第 5 码不是
        --     「五笔 4 码 + 拼音首字母」的筛选位 ⇒ 拼音应当优先。
        --
        -- ⚠ 重要（第十八轮补2 实测更正）：这条判据在 5 码下**永远拿不到数据**。
        --   super_sequence 的 sorter 只在 2~4 码（PINYIN_HOIST_MIN_LEN..MAX_LEN）
        --   才把 pinyin_direct 候选纳入输出，输入长度 ≥ 5 时它既不 insert 也不
        --   yield —— 整片静默丢弃（见 super_sequence.lua 的
        --   `if hoist_pinyin_group and pinyin_kept < PINYIN_DIRECT_MAX`）。
        --   实测：agang 在「translators 合并后」确有 44 条 q≈1000 的拼音直查候选
        --   （上 商 伤 尚 赏 …，_end=5），但到本过滤器入口时 q≥1000 为 0 条。
        --   所以本判据是**留作兜底**（未来若放开 sorter 的 5 码限制即生效），
        --   5 码真正生效的是下面的 spell_cover。保留它不影响任何行为。
        --
        -- 反例（必须保持原行为，pinyin_direct 一条都不出 ⇒ pinyin_cover 恒 false）：
        --   taned→物极必反、khlgg→中国/跨国/贵国、fffff→封、xvyao→需要/须要、
        --   nihao→你好、jintian→今天、gongzuo→工作、zhongguo→中国（多音节词走反查）。
        -- ============================================================
        local pinyin_cover = false
        local direct_cands = {}
        local direct_seen = {}

        -- 【第十八轮补2】别名感知判据：单字反查候选的整个读音逐位（含点击别名）
        --   对上整串输入 ⇒ 用户就是在打一个完整拼音，第 5 位不是「拼音首字母筛选位」。
        --   实测 agang→上(shang) / sgang→上 / xgeng→成(cheng) / cgeng→成 全部命中；
        --   反例 taned / khlgg / fffff / wqvbh / xvyao 全不命中（详见 is_full_spell_cand）。
        --   只在混输方案生效：纯五笔方案（ly_wubi / ly_wubi_14）的 5 码不该被拼音抢。
        local spell_cover = false
        -- 只在混输方案下才预算这张表（纯五笔方案连建都不建，零开销）
        local full_spell_sets = env.is_mixed
            and build_letter_sets(pure_code, pure_code_len, env.use_key_pairs, env.left_to_right)
            or nil

        for cand in input:iter() do
            local q = cand.quality or 0
            if q >= PINYIN_DIRECT_MIN_QUALITY then
                local e = tonumber(cand._end) or cand._end
                if e == pure_code_len then pinyin_cover = true end
                local key = make_candidate_key(cand)
                if not direct_seen[key] then
                    direct_seen[key] = true
                    table.insert(direct_cands, cand)
                end
                goto continue
            end
            if not matches_prefix(cand, pure_code, 4, env.use_key_pairs, env.left_to_right, env.spll_rvdb, env.use_last_char) then
                goto continue
            end
            if cand.type == "reverse_lookup" then
                if full_spell_sets and not spell_cover
                   and is_full_spell_cand(cand, full_spell_sets, pure_code_len, env.spll_rvdb) then
                    spell_cover = true
                end
                local key = make_candidate_key(cand)
                if not reverse_seen[key] then
                    reverse_seen[key] = true
                    table.insert(reverse_cands, cand)
                end
                goto continue
            end
            local target_char = get_target_char(cand, env.use_last_char)
            if target_char then
                local initials = get_pinyin_initials(target_char, env.spll_rvdb)
                if initials_hit(initials, pinyin_filters) then
                    local orig_start = tonumber(cand.start) or cand.start
                    local orig_end = tonumber(cand._end) or cand._end
                    local is_full = (orig_end == 4)          -- 吃满前 4 码 = 真 4 码命中
                    local seen = is_full and full_seen or short_seen
                    local key = make_candidate_key(cand)
                    if not seen[key] then
                        seen[key] = true
                        local out = cand
                        if orig_start ~= 0 or orig_end ~= pure_code_len then
                            out = clone_candidate(cand, 0, pure_code_len, cand.preedit)
                        end
                        table.insert(is_full and full_matched or short_matched, out)
                    end
                end
            end
            ::continue::
        end

        -- 【第十八轮】新增最高优先：整串是一个完整的拼音拼写 ⇒ 拼音优先，4 码五笔命中让位。
        --
        -- 背景：14 键的模糊等价会把大量无关码表条目「配」到前 4 码上 —— 实测：
        --   shang 的第一 4 码 shan 命中了 椃(sham) / 櫖(shan)，
        --   cheng 的第一 4 码 chen 命中了 绝不后悔(xgrn)，
        --   它们一旦吃满前 4 码、又通过第 5 码首字母筛选，就会整片压掉拼音
        --   （实测 shang 在扩展态只剩 1 条「椃」，常用态则因为 椃 是生僻字被 GB2312
        --    挡掉才侥幸正常 —— 这正是用户报的「shang 不出拼音候选」）。
        -- 判据见 is_exact_pinyin_input：只有「整串能被某个反查候选的逐字读音完整拼出」
        --   才算完整拼音拼写。缩写式读音拼不出来 ⇒ taned（4 码五笔 + 第 5 码筛选）不受影响，
        --   K 组「4 码命中优先」保持不变。
        --
        -- 【第十八轮补】is_exact_pinyin_input 只认「输入串 == 候选逐字读音」，认不出
        --   **别名串**：14 键「点击=模糊」会把 shang 敲成 agang（s 的别名 a、h 的别名 g），
        --   而「上」的读音是 shang ≠ agang ⇒ 判据漏判 ⇒ 西贡/绝不后悔 仍会独占整栏。
        --   原先补的 pinyin_cover（拼音直查精确吃满整串）因 super_sequence 的 sorter
        --   在 ≥5 码时整片丢弃 pinyin_direct 候选而拿不到数据，实际恒为 false（见其注释）。
        --
        -- 【第十八轮补2】真正生效的是 spell_cover：单字反查候选的整个读音能被整串
        --   输入逐位（含点击别名）对上（is_full_spell_cand）。它是「别名感知」的，
        --   正好补上 is_exact_pinyin_input 的字面比较所漏掉的那一类。三条判据任一
        --   成立即视为「用户就是在打拼音」，实测：
        --     agang → spell_cover(T) ⇒ 上 商 伤 尚 赏 …（修掉「只剩西贡」）
        --     xgeng → spell_cover(T) ⇒ 成 称 城 呈 程 …（修掉「只剩绝不后悔」）
        --     taned → 三条全 F      ⇒ 物极必反（K 组「4 码命中优先」保持）
        local prefer_pinyin = spell_cover
            or pinyin_cover
            or ((#reverse_cands > 0)
                and is_exact_pinyin_input(pure_code, reverse_cands, env.spll_rvdb, env.is_mixed))

        if #full_matched > 0 and not prefer_pinyin then
            -- ① 第 5 码筛出了真正的 4 码五笔候选 ⇒ 只显示它们，拼音不参与
            table.sort(full_matched, function(a,b) return (a.quality or 0) > (b.quality or 0) end)
            for _, cand in ipairs(full_matched) do yield(cand) end
        elseif #reverse_cands > 0 then
            -- ② 整串是一个完整的拼音拼写，或前 4 码没有真 4 码命中而整串能当拼音读
            --    ⇒ 只显示拼音候选
            for _, cand in ipairs(reverse_cands) do yield(cand) end
        elseif #direct_cands > 0 then
            -- ②' 整串是合法拼音码（拼音直查精确吃满全串），但拼音反查没捞到候选
            --     ⇒ 直接用拼音直查候选（agang→上/商/伤…、chuai→揣/啜…）
            for _, cand in ipairs(direct_cands) do yield(cand) end
        else
            -- ③ 只剩简码/前缀命中的五笔候选（khlgz→中/足/盅、fffff→封、wqvbn→你）
            table.sort(short_matched, function(a,b) return (a.quality or 0) > (b.quality or 0) end)
            for _, cand in ipairs(short_matched) do yield(cand) end
        end
        -- ④ 三者皆空 ⇒ 候选栏为空：空列表下引擎仍处理回车/空格（express_editor 提交原始编码）
        return
    end

    -- ============================================================
    -- 【码长分层】1~3 码：精确命中照单全收，「前缀预测」限量
    --
    -- 分层依据（五笔的手感来自简码 + 盲打，候选窗不能喧宾夺主）：
    --   1 码 → 一级简码为王，最多带 3 条最高频前缀字（绝不动摇空格首选）
    --   2 码 → 二级简码 + 6 条高频前缀预测（实测 im 3+105、ww 1+107，不控就爆）
    --   3 码 → 三级简码 + 5 条高频前缀预测
    --   4 码 → 只出精确命中（五笔最长就是 4 码，本来就没有前缀预测）
    --
    -- 为什么只限 `type == "completion"` 这一类：
    --   · 精确命中（table / 自造词 / 拼音直查 / 拼音反查）一条都不砍 ⇒ 混输方案
    --     打 2~3 码时拼音同音字、简拼词（你好/中国/这个）全部照旧
    --   · 实测精确组天然排在预测组之前（quality 510 / 850 / 1000 vs 499），
    --     所以这里**不重排**，只在流式扫描里数 completion 的个数 ⇒ 不动 super_sequence
    --     精心排好的顺序（尤其是混输的拼音前置）
    -- ============================================================
    local pred_cap = env.predict_cap[input_len]
    local pred_n = 0

    -- ============================================================
    -- ≤4 码：只保留「吃满整串」的候选，丢弃前缀短命中
    --
    -- 现象（2026-09-28 用户报）：输入 imya（4 码 = 测试/测度/小幅度）时，
    --   候选栏还混着 不(i) / 没(im) / 水(i) / 油(im) / 汕(im) / 浿(imy)。
    --   它们只匹配了输入的前 1~3 位（span 0..1 / 0..2 / 0..3）。
    --   点它们时引擎只消费被吃掉的那几位，剩下的留在编码栏：
    --     imya + 点「没」 → 编码栏变「没ya」；imjh + 点「不」 → 变「不mjh」
    --   混输方案还会把残留字母当拼音首字母再翻一遍（mjh → 卖假货/没结婚），
    --   并伴随约 1 秒卡顿。
    --
    -- 出处：script_translator@wubi_prefix（第五码筛选的支持组件）。它按音节图
    --   把输入切开，天然会产出「只吃掉前 1~4 位」的候选（type=phrase，span 0..N）。
    --   ★ 它在 5 码时是刚需（4 码 + 第 5 码首字母筛选全靠它），不能删；
    --     ≤4 码时 table_translator 已经给出精确命中 + 补全，它只剩噪声。
    --
    -- 判据：候选的匹配段终点 orig_end 必须 == 输入长度 ⇒ 这一条吃满整串。
    --   实测 ≤4 码下 table / completion / sentence / reverse_lookup / 自造词
    --   全是满 span；被丢掉的只会是 script_translator 的前缀短命中。
    --   ★ 不用 type 过滤： candidates 的 _end 是唯一事实来源，type 会因为
    --     super_sequence / new_spelling 的重建而改变。
    -- ============================================================
    for cand in input:iter() do
        if not matches_prefix(cand, sanitized_input, input_len, env.use_key_pairs, env.left_to_right, env.spll_rvdb, env.use_last_char) then
            goto continue
        end
        local orig_start = tonumber(cand.start) or 0
        local orig_end = tonumber(cand._end) or cand._end
        -- 起点不在 0 或没吃满整串 ⇒ 是前缀短命中，丢弃
        if orig_end ~= nil and (orig_start ~= 0 or orig_end ~= input_len) then
            goto continue
        end
        -- 前缀预测（completion）按码长限量
        if pred_cap and cand.type == "completion" then
            pred_n = pred_n + 1
            if pred_n > pred_cap then
                goto continue
            end
        end
        yield(cand)
        ::continue::
    end
end

return { init = init, func = filter }