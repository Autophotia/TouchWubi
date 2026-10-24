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
    
    if is_equal_key(repr) then
        if context.input == "" then
            context:push_input("=")
            return 1
        end
        if is_calc_mode(context) then
            context:push_input("=")
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
