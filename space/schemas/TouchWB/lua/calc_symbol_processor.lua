-- ============================================================
-- 【来源与署名】★ 2026-09-30 补署
--   编写：Autophotia（超越输入法 · TouchWB 双键五笔方案）
--         https://github.com/Autophotia/TouchWubi
--
--   溯源：本文件由本方案编写，不是上游移植；它是 calculator.lua
--        （创意来源 Rime Calculator）的配套按键处理器。
--         为什么必须要有它：算式里的 + - * / ( ) ^ 等键会被方案自身的
--         speller / 标点处理器抢走，需要一个 processor 在「输入以 = 开头」
--         时整段接管按键，算式才打得完整
--         ⇒ ★ 必须排在 engine/processors 的首位。
--
--   ★ 缺陷请联系修改者。
-- ============================================================
local processor = {}

local key_char_map = {
    ["comma"] = ",",
    ["period"] = ".",
    ["question"] = "?",
    ["exclam"] = "!",
    ["semicolon"] = ";",
    ["colon"] = ":",
    ["slash"] = "/",
    ["backslash"] = "\\",
    ["caret"] = "^",
    ["tilde"] = "~",
    ["asterisk"] = "*",
    ["at"] = "@",
    ["numbersign"] = "#",
    ["dollar"] = "$",
    ["percent"] = "%",
    ["ampersand"] = "&",
    ["bar"] = "|",
    ["grave"] = "`",
    ["equal"] = "=",
    ["bracketleft"] = "[",
    ["bracketright"] = "]",
    ["braceleft"] = "{",
    ["braceright"] = "}",
    ["less"] = "<",
    ["greater"] = ">",
    ["parenleft"] = "(",
    ["parenright"] = ")",
    ["quotedbl"] = "\"",
    ["apostrophe"] = "'",
    ["minus"] = "-",
    ["plus"] = "+",
    ["underscore"] = "_",
    ["backspace"] = "BackSpace",
    ["delete"] = "Delete",
    ["tab"] = "Tab",
    ["return"] = "Return",
    ["enter"] = "Enter",
    ["space"] = " ",
    ["escape"] = "Escape",
}

-- Shift+基本键 对应的字符映射
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

local function is_calc_mode(context)
    local input = context.input
    if not input or input == "" then return false end
    return string.sub(input, 1, 1) == "="
end

local function get_base_repr(repr)
    -- 移除修饰符前缀
    return repr:gsub("^Shift%+", ""):gsub("^Control%+", ""):gsub("^Alt%+", ""):gsub("^Release%+", "")
end

local function is_equal_key(repr)
    if repr:match("^Shift%+") then
        return false
    end
    local base_repr = get_base_repr(repr)
    return base_repr == "=" or base_repr == "equal"
end

local function get_key_char(repr, has_shift)
    local base_repr = get_base_repr(repr)

    -- 单字符直接返回
    if #base_repr == 1 then
        if has_shift and shift_char_map[base_repr] then
            return shift_char_map[base_repr]
        end
        return base_repr
    end

    -- 查找 key_char_map
    local char = key_char_map[base_repr]
    if char then
        -- 如果带 Shift 且该字符有 Shift 版本
        if has_shift and shift_char_map[char] then
            return shift_char_map[char]
        end
        return char
    end

    return nil
end

function processor.init(env)
end

function processor.func(key, env)
    local context = env.engine.context

    if key:release() then
        return 2
    end

    local repr = key:repr()

    -- ★ 2026-11-03 修复：number 键盘 ascii_mode=1 时，= 键（send "="）进入编码栏后
    --   ascii_segmentor 把 "=" 切成 ascii 段 ⇒ 不产「= _ 々 〃」符号候选、空格键被
    --   ascii_composer 当作 ASCII 空格收进 input ⇒ 表现为「按空格上屏空白、再按出英文单引号」。
    --   修法：push "=" 时临时关 ascii_mode，让 "=" 走 punct 段，恢复候选与空格上屏（见下方）。
    --   恢复：计算器结束（input 清空）后把 ascii_mode 还原为 true（number 键盘默认值），
    --   数字键才能继续直接上屏；切键盘（Eisu_toggle）时作废恢复标志，避免污染 default 键盘。
    if get_base_repr(repr) == "Eisu_toggle" then
        env._calc_ascii_restore = false
        return 2
    end
    if context.input == "" and env._calc_ascii_restore then
        env._calc_ascii_restore = false
        context:set_option("ascii_mode", true)
    end

    if is_equal_key(repr) then
        if context.input == "" then
            context:push_input("=")
            if context:get_option("ascii_mode") then
                context:set_option("ascii_mode", false)
                env._calc_ascii_restore = true
            end
            return 1
        end
        if is_calc_mode(context) then
            context:push_input("=")
            return 1
        end
        return 2
    end

    -- ★ 2026-11-03 修复：@ 键（number 键盘上滑 send_equal 键 = send "@"）进编码栏触发邮箱后缀。
    --   number 键盘 ascii_mode=1 会把 "@" 切成 ascii 段 echo 掉（不出 email 候选）⇒
    --   与 = 键同理：临时关 ascii_mode，让 "@" 走 punct/abc 段触发 email_suffix_translator。
    if get_key_char(repr, repr:match("^Shift%+") ~= nil) == "@" then
        if context.input == "" then
            context:push_input("@")
            if context:get_option("ascii_mode") then
                context:set_option("ascii_mode", false)
                env._calc_ascii_restore = true
            end
            return 1
        end
        return 2
    end

    if not is_calc_mode(context) then
        return 2
    end

    local has_shift = repr:match("^Shift%+") ~= nil

    -- 退格键特殊处理
    -- ★ 2026-09-29 修复：pop_input() 缺参数（librime 要求 pop_input(n)），
    --   每次走到这里都抛
    --     "error(2): bad argument #3 to '?' (number expected, got no value)"
    --   librime 把抛错的 processor 当成「放行」，于是按键被 speller 照常收进去 ——
    --   表面上功能正常、日志里却一直在刷错误；而真退格时则是「放行 = 没删成」。
    -- ★ keycode 0x2E 是 ASCII 的 '.'（小数点），不是退格 ⇒ 见下方 TEMP 判定。
    if get_base_repr(repr) == "BackSpace" then
        if #context.input > 0 then
            context:pop_input(1)
            return 1
        end
        return 2
    end

    -- Delete 键放行
    if key.keycode == 0x2D or get_base_repr(repr) == "Delete" then
        return 2
    end

    -- Ctrl/Alt 修饰键放行
    if key:ctrl() or key:alt() then
        return 2
    end

    -- 功能键放行
    local base_repr = get_base_repr(repr)
    if base_repr == "Shift" or base_repr == "Control" or base_repr == "Alt" then
        return 2
    end

    if base_repr == "space" or base_repr == "Space" then
        return 2
    end

    if base_repr == "Return" or base_repr == "Enter" or base_repr == "Tab" then
        return 2
    end

    if base_repr == "Escape" then
        return 2
    end

    if base_repr == "Left" or base_repr == "Right" or base_repr == "Up" or base_repr == "Down" then
        return 2
    end

    -- 获取按键字符
    local char = get_key_char(repr, has_shift)
    if char then
        context:push_input(char)
        return 1
    end

    return 2
end

return {
    init = processor.init,
    func = processor.func
}
