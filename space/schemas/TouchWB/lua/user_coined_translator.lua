--[[
    user_coined_translator.lua - 自造词即时查询翻译器
    功能：实时读取 C++ UserDb（lua/user_coined），高优先级显示用户自定义词条
    来源：2026-11-04 从 Submit_text.lua 拆出（原「翻译器：自造词即时查询」段），
         使 translator 成为可独立 require 的模块，与 auto_coined / user_coined_cmd 风格统一。
    依赖：user_coined_db（UserDb 打开 / 14键归一化 / 编码解析）、core（core.dbg 日志）。

    【命中优先级】质量值从高到低：
      永久词 exact          950
      永久词 dual_exact     900（14键归一化后精确）
      永久词 reverse_prefix 850（输入以存储码开头，5码输入命中短码词）
      永久词 dual_reverse   800
      永久词 prefix         850
      永久词 dual_prefix    750
      临时词 exact          950（带 ☯ 标记）
      临时词 dual_exact     900
]]

local db = require "user_coined_db"
local core = require "core"

-- 手动造词日志（与 Submit_text.lua 的 kcoin 同款，tag 前缀 COIN:）
local function kcoin(tag, msg)
    core.dbg("COIN:" .. (tag or "?"), msg or "")
end

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

    local query_input = raw_input:match("^[a-z]+$") or input
    if not query_input or not query_input:match("^[a-z]+$") then
        return
    end
    if #query_input < 2 then
        return
    end

    db.uc_migrate_once()
    local udb = db.uc_open()
    if not udb then return end

    local use_dual_key = db.is_14key_layout(env)
    local norm_input = use_dual_key and db.normalize_14key(query_input) or query_input

    local seen = {}
    local function yield_user_coined(text, code, quality, is_temp)
        if seen[text] then
            return
        end
        seen[text] = true
        local disp = is_temp and (code .. "☯") or code
        local cand = Candidate("user_coined", seg.start, seg._end, text, disp)
        cand.quality = quality
        yield(cand)
    end

    local code_prefix
    local function try_match(text, code, is_temp)
        code_prefix = code:sub(1, #query_input)
        local exact_match = (code == query_input)
        local prefix_match = (#query_input >= 2 and code:find("^" .. query_input) == 1)
        local reverse_prefix_match = (#query_input > #code and query_input:find("^" .. code) == 1)

        local dual_exact_match = false
        local dual_prefix_match = false
        local dual_reverse_prefix_match = false
        if use_dual_key then
            local norm_stored = db.normalize_14key(code)
            local norm_stored_prefix = db.normalize_14key(code_prefix)

            dual_exact_match = (not exact_match and #query_input == #code and norm_input == norm_stored)
            dual_prefix_match = (not exact_match and not prefix_match and #query_input >= 2 and #code >= #query_input and norm_input == norm_stored_prefix)
            dual_reverse_prefix_match = (not exact_match and not prefix_match and not reverse_prefix_match and #query_input > #code and norm_input:find("^" .. norm_stored) == 1)
        end

        if is_temp then
            if exact_match then
                yield_user_coined(text, code, 950, true)
                kcoin("recall", "临时词命中 [" .. text .. "]=" .. code .. " input=" .. query_input)
            elseif dual_exact_match then
                yield_user_coined(text, code, 900, true)
                kcoin("recall", "临时词模糊命中 [" .. text .. "]=" .. code .. " input=" .. query_input)
            end
        elseif exact_match then
            yield_user_coined(text, code, 950)
        elseif dual_exact_match then
            yield_user_coined(text, code, 900)
        elseif reverse_prefix_match then
            yield_user_coined(text, code, 850)
        elseif dual_reverse_prefix_match then
            yield_user_coined(text, code, 800)
        elseif prefix_match then
            yield_user_coined(text, code, 850)
        elseif dual_prefix_match then
            yield_user_coined(text, code, 750)
        end
    end

    local first = query_input:sub(1, 1)
    local prefixes = { first }
    if use_dual_key then
        local l, r = db.get_key_pair(first)
        prefixes = { l }
        if r then prefixes[#prefixes + 1] = r end
    end

    local function query_prefix(pfx)
        local acc = udb:query("e\t" .. pfx)
        if acc then
            for k in acc:iter() do
                local text, code = db.uc_parse_key(k)
                if text then try_match(text, code, false) end
            end
        end
        acc = udb:query("a\t" .. pfx)
        if acc then
            for k in acc:iter() do
                local text, code = db.uc_parse_key(k)
                if text then try_match(text, code, true) end
            end
        end
    end

    for _, p in ipairs(prefixes) do
        query_prefix(p)
    end
end

return user_coined_translator
