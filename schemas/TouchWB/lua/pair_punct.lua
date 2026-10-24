--[[
    pair_punct.lua - 配对符号自动补全模块
    作者: kuroame, boomker, shawx
    授权: MIT
    日期: 2026-06
]]

local M = {}
local processor = {}
local segmentor = {}

-- ★ 移动端判定（与 smart_assoc.lua 完全同款实现）
--   用途：26 键 K/L 下滑要走 punctuator 的 pair（左右交替出单个符号），
--         而 PC 端保留「一次出一对」的老行为，互不干扰。
local _mobile = nil
local function is_mobile()
    if _mobile ~= nil then return _mobile end
    _mobile = false
    if jit and jit.os then
        local o = (jit.os or ""):lower()
        if o:find("android") or o:find("harmony") then _mobile = true; return _mobile end
    end
    pcall(function()
        local d = ((rime_api.get_user_data_dir() or "") .. " " ..
                   (rime_api.get_shared_data_dir() or "")):lower()
        if d:find("/data/storage/el%d") or d:find("/android/") or d:find("/storage/emulated/")
            or d:find("/sdcard/") or d:find("/harmony") or d:find("/hap/")
            or d:find("/space/") or d:find("/storage/users/") then
            _mobile = true
        end
    end)
    return _mobile
end

function get_selected_candidate_index(key_value, selected_index, page_size)
	local key_name = key_value
	local selected_cand_idx = -1
	local page_cand_size = page_size or 7
	
	if key_name == "space" then
		key_name = 0
	elseif key_name == "Return" then
		key_name = -1
	elseif key_name == "semicolon" then
		key_name = 1
	elseif key_name == "apostrophe" then
		key_name = 2
	elseif key_name:match("^[1-9]$") then
		key_name = tonumber(key_name) - 1
	elseif key_name == "0" then
		key_name = 9
	else
		return -1
	end

	local page_pos = math.floor(selected_index / page_cand_size) + 1
	local idx = key_name
	selected_cand_idx = ((type(key_name) == "number") and (page_pos > 1))
		and (key_name + (page_pos - 1) * page_cand_size) or idx
	return selected_cand_idx
end

local tag_prefix = "pair_punct_"

local pairTable = {
    ["`"] = { "`" },
    ["```"] = { "```" },
    ["“"] = { "“", "”" },
    ["”"] = { "“", "”" },
    ["‘"] = { "‘", "’" },
    ["’"] = { "‘", "’" },
    ["("] = { "(", ")" },
    ["["] = { "[", "]" },
    ["{"] = { "{", "}" },
    ["<"] = { "<", ">" },
    ["（"] = { "（", "）" },
    ["【"] = { "【", "】" },
    ["〔"] = { "〔", "〕" },
    ["〚"] = { "〚", "〛" },
    ["〘"] = { "〘", "〙" },
    ["「"] = { "「", "」" },
    ["」"] = { "「", "」" },
    ["［"] = { "［", "］" },
    ["｛"] = { "｛", "｝" },
    ["『"] = { "『", "』" },
    ["』"] = { "『", "』" },
    ["〖"] = { "〖", "〗" },
    ["《"] = { "《", "》" },
    ["》"] = { "《", "》" },
    ["〈"] = { "〈", "〉" },
    ["〉"] = { "〈", "〉" },
	["quotedbl"] = { "“", "”" },
    ["apostrophe"] = { "‘", "’" },
}

local symbol_whitelist = {
    "`", "```", "“", "”", "‘", "’", "(", ")", "[", "]", "{", "}", "<", ">",
    "（", "）", "【", "】", "〔", "〕", "〚", "〛", "〘", "〙", "「", "」",
    "［", "］", "｛", "｝", "『", "』", "〖", "〗", "《", "》", "〈", "〉"
}

local direct_punct_map = {
    [","] = "，",
    ["."] = "。",
    ["!"] = "！",
    ["?"] = "？",
    [":"] = "：",
    ['"'] = "”",
    ["("] = "（",
    [")"] = "）",
    ["-"] = "-",
    -- ★ `#` **不能**放进这张表：落进来会被 commit_text 直接上屏并 return 1，
    --   完全绕开 punctuator ⇒ 上滑 `#` 永远只出单个字符、没有候选列表
    --   （`#` 的按键名 numbersign 会先被转成 "#"，所以判定得到的是字符）。
    --   不放进表：空状态由 punctuator 弹列表可选变体；
    --            打码中由 pool_punct_set 分支保持「首候选 + #」（与 `= @ / ~` 同类）。
    ["$"] = "￥",
    ["%"] = "%",
    ["&"] = "&",
    ["*"] = "*",
    ["~"] = "~",
    ["|"] = "·",
    -- ★ `'` **要**放进这张表：否则它会掉到下面
    --   `if base_key_value == "apostrophe" then return 1` 那句被干吞掉（什么都不出）。
    --   进表后与同排 `"` 同等待遇：打码中「首候选 + ’」一起上屏。
    ["'"] = "’",
}

local pool_punct_first_map = {
    ["/"] = "、",
    ["\\"] = "、",
    ["="] = "=",
    ["["] = "「",
    ["]"] = "」",
    ["{"] = "『",
    ["}"] = "』",
    ["<"] = "《",
    [">"] = "》",
    ["*"] = "*",
    ["#"] = "#",
    ["$"] = "￥",
    ["%"] = "%",
    ["&"] = "&",
    ["~"] = "~",
    ["|"] = "·",
    ["!"] = "！",
    ["("] = "（",
    [")"] = "）",
    ["@"] = "@",
    ["^"] = "^",
    ["_"] = "_",
    ["+"] = "+",
    ["-"] = "-",
}

local pool_punct_set = {
    ["/"] = true,
    ["\\"] = true,
    ["="] = true,
    ["["] = true,
    ["]"] = true,
    ["{"] = true,
    ["}"] = true,
    ["<"] = true,
    [">"] = true,
    ["*"] = true,
    ["#"] = true,
    ["$"] = true,
    ["%"] = true,
    ["&"] = true,
    ["~"] = true,
    ["|"] = true,
    ["!"] = true,
    ["("] = true,
    [")"] = true,
    ["@"] = true,
    ["^"] = true,
    ["_"] = true,
    ["+"] = true,
    ["-"] = true,
}

local function is_pure_symbol(txt)
    for _, sym in ipairs(symbol_whitelist) do
        if txt == sym then
            return true
        end
    end
    return false
end

local function get_key_char(segment)
    for tag in pairs(segment.tags) do
        if tag:sub(1, #tag_prefix) == tag_prefix then
            return tag:sub(#tag_prefix + 1)
        end
    end
    return nil
end

local function get_pp_seg(segmentation)
    for i = 0, segmentation.size - 1 do
        local seg = segmentation:get_at(i)
        if seg and get_key_char(seg) then
            return seg
        end
    end
    return nil
end

local function on_update_or_select(env)
    return function(ctx)
        local segmentation = ctx.composition:toSegmentation()
        local pp_seg = get_pp_seg(segmentation)
        if not pp_seg then return end
        
        local selected_cand = ctx.composition:back():get_selected_candidate()
        if not selected_cand or not is_pure_symbol(selected_cand.text) then
            return
        end
        
        local target_txt = selected_cand.text
        local punct_pair = pairTable[target_txt]
        if not punct_pair or (#punct_pair < 1) then return end
        
        ctx.composition:back().prompt = (#punct_pair == 2) and punct_pair[2] or ""
    end
end

function segmentor.init(env)
    env.closing_punct = nil
    local config = env.engine.schema.config
    local schema_id = config:get_string("schema/schema_id")
    local schema = Schema(schema_id)
    env.echo_translator = Component.Translator(env.engine, schema, "", "echo_translator")
    env.update_notifier = env.engine.context.update_notifier:connect(on_update_or_select(env))
    env.select_notifier = env.engine.context.select_notifier:connect(on_update_or_select(env))
end

function processor.init(env)
    env.last_processed_key = nil
    env.last_processed_time = 0
end

local shift_char_map = {
    ["1"] = "!",
    ["2"] = "@",
    ["3"] = "#",
    ["4"] = "$",
    ["5"] = "%",
    ["6"] = "^",
    ["7"] = "&",
    ["8"] = "*",
    ["9"] = "(",
    ["0"] = ")",
    ["-"] = "_",
    ["="] = "+",
    ["["] = "{",
    ["]"] = "}",
    ["\\"] = "|",
    [";"] = ":",
    ["'"] = "\"",
    [","] = "<",
    ["."] = ">",
    ["/"] = "?",
    ["`"] = "~",
}

function processor.func(key, env)
    local context = env.engine.context
    local composition = context.composition
    local current_time = os.clock()
    
    local repr = key:repr()
    local has_shift = repr:match("^Shift%+") ~= nil
    local base_key_value = repr:gsub("^Shift%+", ""):gsub("^Release%+", "")
    
    if key:release() then
        return 2
    end
    
    local input = context.input or ""
    if string.sub(input, 1, 1) == "=" then
        return 2
    end
    
    if (base_key_value == "quotedbl" or base_key_value == "apostrophe") and 
       env.last_processed_key == base_key_value and 
       (current_time - env.last_processed_time < 0.2) then
        return 2
    end

    local is_ascii_mode = context:get_option("ascii_mode")
    local is_ascii_punct = context:get_option("ascii_punct")
    
    local key_char = base_key_value
    if key_char == "comma" then key_char = "," end
    if key_char == "period" then key_char = "." end
    if key_char == "question" then key_char = "?" end
    if key_char == "exclam" then key_char = "!" end
    if key_char == "semicolon" then key_char = ";" end
    if key_char == "colon" then key_char = ":" end
    if key_char == "slash" then key_char = "/" end
    if key_char == "backslash" then key_char = "\\" end
    if key_char == "caret" then key_char = "^" end
    -- ★ 2026-09-29 修复：26 键 A 键上滑 `~` 会把候选顶进编码栏，而不是顶候选上屏。
    --   根因：librime 对 `~` 给的按键名是 **asciitilde**，而这里只映射了 "tilde"
    --   ⇒ key_char 停在 "asciitilde" ⇒ direct_punct_map 查不到 ⇒ is_direct_punct=false
    --   ⇒ 一路 return 2 放行 ⇒ 字符被 speller / punctuator 收走，候选留在编码栏。
    --   实测 28 个标点里 `~` 是唯一中招的（其余都走 direct_punct_map 正常顶上屏）。
    if key_char == "tilde" or key_char == "asciitilde" then key_char = "~" end
    if key_char == "asterisk" then key_char = "*" end
    if key_char == "at" then key_char = "@" end
    if key_char == "numbersign" then key_char = "#" end
    if key_char == "dollar" then key_char = "$" end
    if key_char == "percent" then key_char = "%" end
    if key_char == "ampersand" then key_char = "&" end
    if key_char == "bar" then key_char = "|" end
    if key_char == "grave" then key_char = "`" end
    if key_char == "equal" then key_char = "=" end
    if key_char == "bracketleft" then key_char = "[" end
    if key_char == "bracketright" then key_char = "]" end
    if key_char == "braceleft" then key_char = "{" end
    if key_char == "braceright" then key_char = "}" end
    if key_char == "less" then key_char = "<" end
    if key_char == "greater" then key_char = ">" end
    if key_char == "parenleft" then key_char = "(" end
    if key_char == "parenright" then key_char = ")" end
    if key_char == "quotedbl" then key_char = "\"" end
    if key_char == "apostrophe" then key_char = "'" end
    if key_char == "minus" then key_char = "-" end
    if key_char == "plus" then key_char = "+" end
    if key_char == "underscore" then key_char = "_" end
    if key_char == "asciicircum" then key_char = "^" end
    
    if has_shift and shift_char_map[key_char] then
        key_char = shift_char_map[key_char]
    end
    
    -- ★ 2026-09-29 新增：**移动端**禁用 key_binder 的「`;` 选第 2 候选 / `'` 选第 3 候选」。
    --   那两条绑定写在各 schema 的 key_binder 段：
    --     {accept: semicolon,  send: 2, when: has_menu}
    --     {accept: apostrophe, send: 3, when: has_menu}
    --   是 PC 物理键盘的二选 / 三选快捷键。手机上没有与之对应的实体键位，
    --   26 键 N / L 上滑之类的手势送进来的 `;` `'` 会被它抢走 ⇒
    --   表现为「上滑没出标点，反而莫名选了第 2 / 第 3 个候选」。
    --
    --   ⇒ 移动端在这里**先拦下来**，与其它标点走同一套逻辑：**首候选 + 标点**一起上屏
    --     （`;`→`；`、`'`→`’`），随后清空编码栏。
    --
    -- ⚠ 位置：放在**所有分支之前**（key_char 映射之后、has_menu 判定之前）。
    --   打码时 `context:has_menu()` 实测是 false、`composition:empty()` 实测是 true，
    --   所以下面那两个分支的实际走法反直觉；靠 `context.input ~= ""` 判断「正在打码」
    --   才是最稳的事实来源，别挪进下面任何一个分支里。
    -- ⚠ 必须排在 key_binder 之前才拦得住（processors：pair_punct → punctuator → key_binder），
    --   return 1 即截断链条。
    -- ⚠ PC 端 is_mobile()==false，完全不进这个分支，二选 / 三选快捷键行为不变。
    -- ⚠ 空状态（没在打码）不进这里，`;` `'` 仍走原逻辑（移动端引号还保留 pair 左右交替）。
    if is_mobile() and (key_char == ";" or key_char == "'") and input ~= "" then
        local m_sel = context:get_selected_candidate()
        local m_txt = (m_sel and m_sel.text) or ""
        local m_punct = (key_char == ";") and "；" or "’"
        env.engine:commit_text(m_txt .. m_punct)
        context:clear()
        return 1
    end

    local has_candidate_menu = context:has_menu()
    
    local top_candidate_text = ""
    if has_candidate_menu then
        local selected_cand = context:get_selected_candidate()
        if selected_cand and selected_cand.text then
            top_candidate_text = selected_cand.text
        end
    end
    
    local is_direct_punct = direct_punct_map[key_char] ~= nil
    
    if base_key_value == "BackSpace" then
        local input = context.input or ""
        local is_pair_punct = false
        for _, pair in pairs(pairTable) do
            if #pair == 2 and (input == pair[1] or input == pair[2]) then
                is_pair_punct = true
                break
            end
        end
        if is_pair_punct then
            context:clear()
        end
        return 2
    end

    if not context:get_option("pair_symbol") then
        return 2
    end

    -- ★ 智能联想段不是"打码打出来的候选"，在它上面按标点只是想打标点，
    --   绝不能把联想词一起上屏（真机表现：输入"…测试句子"后按句号 ⇒ 上屏"…测试句子女。"）。
    --   smart_assoc 正常情况下会先清掉联想，这里兜的是"清空因为时序没生效"的情况。
    --
    -- ★★ S90 曾把判据换成 `_G.__touchwb_assoc_seg`（旧的
    --   `__touchwb_assoc_predicting` 自 S88 起已空转：写点随长按语音代码被删、读点还留着）。
    --   S91 进一步收紧 —— 详见下面那段说明。
    --
    -- ★★★ S91 再更正：锁存标志也不能单独当判据。
    --   `_G.__touchwb_assoc_seg` 由 smart_assoc 在**按键开头**现场判定后写入，
    --   但本函数读它时，按键已经流过 smart_assoc*P，而那里对联想段的标点
    --   做了清理并 return 1（吞掉）⇒ 标志**已被清成 false** ⇒ 这里读到 false。
    --   也就是说：靠「读另一个文件在上游写下的状态」来豁免，时序上根本不可靠 ——
    --   上游一清理，读点就失效。S90 的标点修复之所以看起来好了，
    --   实际是**上游已经先清了**这道兜底偶然生效，不是判据本身对。
    --
    -- 【S91 的正确判据：输入码是不是空的 + 联想候选是不是真的在展示】
    --   · 输入码为空（结构事实，predictor 空段路 S60 起不推占位符，永远为空）
    --     且 联想段标志为真（联想候选确实在展示）
    --     ⇒ 用户只想打标点 ⇒ return 2 放行给 punctuator，绝不顶候选
    --   · 输入码非空 ⇒ 正常打字 ⇒ 走下面的原有配对逻辑
    --   ⚠ 为什么不能只看「输入码为空」：刚上屏、predictor 还没建段的空窗期
    --     输入码也是空的，那时若豁免 ⇒ 会把正常打字的配对标点功能也一起关掉。
    --     加上标志条件，把空窗期排除。
    local _live_in = context.input or ""
    if _live_in == "" and _G.__touchwb_assoc_seg then
        -- S90 探针：只累计数，日志由 smart_assoc 的 P.func 统一打印
        _G.__touchwb_punct_exempt = (_G.__touchwb_punct_exempt or 0) + 1
        return 2
    end
    _G.__touchwb_punct_exempt = 0

    -- ★ S118 标点规则（用户 2026-10-12 定）：
    --   · 全角标点：仅打码中「顶当前候选 + 标点」上屏，其它时候清联想只出标点（下方原有逻辑已实现）。
    --   · 半角标点：任何时候「清候选 + 清联想 + 直接上屏半角符号」，绕开 punctuator。
    --   半角/全角由 ascii_punct 开关决定（Rime 既有机制）。
    --
    --   这里补的是「半角分支」：当 ascii_punct 开（要半角）且非 ascii_mode（纯英文模式）
    --   且该键是 direct_punct_map 里的标点键时，直接 commit 半角字符本身 + clear。
    --   key_char 经过 296-338 行的按键名映射 + shift 转换后，已是最终半角 ASCII 字符
    --   （如 `,` `.` `!` `?` `:` `"` `(` `)` `|` `~` 等），正好是半角输出。
    --
    --   ⚠ 为什么放在 has_candidate_menu 判断之前：半角规则「任何时候」都生效，
    --     不区分打码中/空状态/配对段，一个分支统一覆盖三种情形，避免重复。
    --   ⚠ 成对符号（pairTable 里的 `"` `'` `(` `[` `{` `<` 等）在 ascii_punct 开时
    --     也走这里 ⇒ 输出单个半角符号，不再成对（这正是「半角直接上屏」的预期）。
    if is_ascii_punct and not is_ascii_mode and is_direct_punct then
        env.engine:commit_text(key_char)
        context:clear()
        return 1
    end

    if has_candidate_menu then
        if base_key_value == "Left" or base_key_value == "Right" then
            return 2
        end
        
        if input ~= "" and (pool_punct_set[input] or direct_punct_map[input]) then
            return 2
        end
        
        if is_direct_punct and not is_ascii_mode and not is_ascii_punct then
            local punct_symbol = direct_punct_map[key_char] or ""
            env.engine:commit_text(top_candidate_text .. punct_symbol)
            context:clear()
            return 1
        end
        
        if key_char == ";" then
            return 2
        end
        
        -- ★ `'` 不再在这里被吞掉。它现在归 direct_punct_map。
        --
        -- ⚠ 2026-09-29 实测纠正：上面那句注释说的「走到 is_direct_punct ⇒
        --   「首候选 + ’」一起上屏」**并没有发生**。实测打码中按 `'` 上屏的是
        --   **第 3 候选**（key_binder 的 `{accept: apostrophe, send: 3}`，见
        --   get_selected_candidate_index：apostrophe → key_name=2 → 第 3 个）。
        --   原因：key_binder 在 processor 链里排在 pair_punct 之前，先吃掉这个键。
        --   同理 `;` 是选第 2 候选。二者都是有意设计 —— 26 键 L / N 上滑靠它二选三选，
        --   不要为了「首候选 + 标点」去动它。（独立 session 实测，非 0.2s 去重伪影）
        --
        -- if base_key_value == "apostrophe" then
        --     return 1
        -- end
        
        if pool_punct_set[key_char] then
            local punct_symbol = pool_punct_first_map[key_char] or ""
            context:clear()
            env.engine:commit_text(top_candidate_text .. punct_symbol)
            return 1
        end
        
        return 2
    else
        if composition:empty() then
            -- ★ **移动端**把 `"` 和 `'` 放行给 punctuator 的 `pair`
            --   （symbols.yaml: '"' : { pair: [ '“', '”' ] } / ''': { pair: [ '‘', '’' ] }）
            --   ⇒ 第 1 次出开的、第 2 次出闭的，正好是用户要的「一次左、一次右」。
            --   留在 Lua 里处理就只能一次吐一对（光标还停在末尾）。
            --   ⚠ PC 端保持原样（一次出一对），别为手机改坏桌面。
            if is_mobile() and (base_key_value == "apostrophe" or base_key_value == "quotedbl") then
                return 2
            end

            if base_key_value == "apostrophe" then
                env.engine:commit_text(pairTable["apostrophe"][1] .. pairTable["apostrophe"][2])
                env.last_processed_key = base_key_value
                env.last_processed_time = current_time
                context:clear()
                return 1
            end
            
            if base_key_value == "quotedbl" then
                env.engine:commit_text(pairTable["quotedbl"][1] .. pairTable["quotedbl"][2])
                env.last_processed_key = base_key_value
                env.last_processed_time = current_time
                context:clear()
                return 1
            end
            
            if is_direct_punct and not is_ascii_mode and not is_ascii_punct then
                local is_pair_symbol = pairTable[key_char] ~= nil
                if is_pair_symbol then
                    return 2
                else
                    local punct_symbol = direct_punct_map[key_char] or ""
                    env.engine:commit_text(punct_symbol)
                    return 1
                end
            end
            
            return 2
        else
            if is_direct_punct and not is_ascii_mode and not is_ascii_punct then
                local is_pair_symbol = pairTable[key_char] ~= nil
                if is_pair_symbol then
                    context:clear()
                    return 2
                else
                    local punct_symbol = direct_punct_map[key_char] or ""
                    env.engine:commit_text(punct_symbol)
                    context:clear()
                    return 1
                end
            end
            
            return 2
        end
    end
end

function segmentor.func(segmentation, env)
    local symkey = nil
    local context = env.engine.context

    if not context:get_option("pair_symbol") or segmentation:empty() then
        return true
    end

    local input_text = context.input or ""
    if not is_pure_symbol(input_text) then
        return true
    end
    
    if #input_text > 0 and #input_text <= 1 and string.byte(input_text) < 128 then
        return true
    end

    local selected_cand = context:get_selected_candidate()
    if not selected_cand or not is_pure_symbol(selected_cand.text) then
        return true
    end
    local target_txt = selected_cand.text

    if pairTable[target_txt] then
        symkey = target_txt
    end
    
    if not symkey then return true end
    
    local match_len = #target_txt
    local match_start = segmentation:get_current_start_position()
    local match_end = match_start + match_len
    local seg = Segment(match_start, match_end)
    seg.tags = Set({ tag_prefix .. symkey })
    segmentation:add_segment(seg)
    segmentation:forward()
    return true
end

function M.fini(env)
    if env.echo_translator then env.echo_translator = nil end
    if env.update_notifier then env.update_notifier:disconnect() end
    if env.select_notifier then env.select_notifier:disconnect() end
end

return {
    processor = { init = processor.init, func = processor.func, fini = M.fini },
    segmentor = { init = segmentor.init, func = segmentor.func, fini = M.fini },
}
