-- ============================================================================
-- user_coined_db.lua —— 自造词数据服务层（2026-11-04 模块化重构）
--   从 Submit_text.lua 抽出的「纯数据/算法」层：14键工具、五笔编码查询、
--   路径管理、C++ UserDb 读写、自动造词转正、大字典释放。
--
--   【为何拆出来】
--     Submit_text.lua 曾是 1281 行的「杂货铺」：处理器状态机、translator、
--     字典加载、UserDb 操作、路径管理全挤在一起，并通过 rawset(_G, ...) 把
--     16 个符号泄漏到全局，供 auto_coined.lua / user_coined_cmd.lua 靠
--     type(_G.xxx)=="function" 防御式探测调用。
--     本模块把所有「数据服务」收敛到一处，通过 require 显式共享：
--       local db = require "user_coined_db"  →  db.uc_put_manual(...) 等
--     require 按 Lua 模块缓存，同一引擎内所有消费方拿到同一份 upvalue 状态
--     （uc_db / 字典缓存 / 路径），共享语义与原 _G 全局完全一致，但依赖显式、
--     无全局污染。
--
--   【职责边界】
--     本模块只做「数据/算法」，不含处理器状态机（手动造词逐字累积 _coin_* 留在
--     Submit_text.lua）、不含日志开关（kcoin/klog 留在 Submit_text.lua）。
--   类型注解：uc_db 等引用 lua/types.lua 定义的 UserDb 类型（LuaLS 全局索引解析）。
-- ============================================================================

local basic = require "lib/basic"
local utf8chars = basic.utf8chars

-- ============================================================================
-- == 14键双键布局映射 ==
-- ============================================================================

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

-- ============================================================================
-- == 标准五笔编码查询（全量字典懒加载 + 单字缓存 + 布隆过滤器）==
-- ============================================================================

-- 单字编码缓存（强引用，避免弱值表被 GC 频繁清空导致每键扫盘）
local char_code_cache = {}
local char_code_cache_n = 0

-- 全量字典哈希表 { 单字 -> code }（懒加载，扁平化省 table 对象）
local char_dict_cache   = nil
local char_dict_phrases = nil   -- 已废弃：2026-11-01 起不再构建（改布隆过滤器）
local char_dict_done    = false

-- 主词典多字词去重：布隆过滤器（替代 11.8 万条哈希集合，省 ~10MB 常驻）
-- ★ 2026-11-05 修复「自动造词」等合法新词被误判为「主词典已有词」而漏造：
--   旧 BLOOM_BITS=1200000 装入 ~11.5 万条多字词后，误判率约 0.68%（≈1/147），
--   真机实测「自动造词」命中误判 ⇒ in_main_dict 误判 true ⇒ build_phrases 跳过造词，
--   该词永远造不出、转不了正（用户报告「自动乖戾/自动千户/自动选词 都能转正，唯独
--   自动造词不行」）。放大到位数组 6M 位（≈750KB，仍远低于精确集合的 ~10MB）后，
--   误判率降到 ~5e-7（≈1/200万），漏造风险可忽略。
local BLOOM_BITS = 6000000
local BLOOM_K    = 7
local bloom_blocks = nil

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
    if h2 % 2 == 0 then h2 = h2 + 1 end   -- 保证 h2 为奇，与偶数模互质，双哈希覆盖完整
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
    if h2 % 2 == 0 then h2 = h2 + 1 end   -- 与 bloom_set 一致，保证奇 h2
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

-- 造词词条合法性：非空、不含字母、不少于 2 个字形
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

local MAX_CACHE_SIZE = 2000

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
        table.insert(dict_paths, dir .. "ly_wubi.dict.yaml")
        table.insert(dict_paths, dir .. "wubi.dict.yaml")
        table.insert(dict_paths, dir .. "wubi.extended.dict.yaml")
    end
    add_dir(rime_api and rime_api.get_user_data_dir and rime_api.get_user_data_dir())
    add_dir(rime_api and rime_api.get_schema_data_dir and rime_api.get_schema_data_dir())
    add_dir(rime_api and rime_api.get_shared_data_dir and rime_api.get_shared_data_dir())
    return dict_paths
end

local function parse_dict_line(trimmed)
    local text, code, weight = trimmed:match("^([^\t%s]+)[\t%s]+([a-z]+)[\t%s]+(%d+)$")
    if text and code then
        return text, code, tonumber(weight) or 0
    end
    local text2, code2 = trimmed:match("^([^\t%s]+)[\t%s]+([a-z]+)$")
    if text2 and code2 then
        return text2, code2, 0
    end
    return nil
end

-- 懒加载全量字典：一次性把整本 ly_wubi.dict.yaml 读进内存哈希表 { 字 → 最高权重编码 }
local function build_dicts()
    local dict = {}
    local wdict = {}
    bloom_blocks = {}
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
                            bloom_set(text)
                        end
                    end
                end
            end
            f:close()
            if next(dict) then
                break
            end
        end
    end
    if next(dict) then
        char_dict_done = true
    end
    char_dict_cache = dict
    char_dict_phrases = nil
end

local function ensure_dict_loaded()
    if not char_dict_done then
        build_dicts()
    end
end

local function get_char_wubi_code(char)
    if char_code_cache[char] then
        return char_code_cache[char]
    end

    ensure_dict_loaded()
    if char_dict_cache then
        local c = char_dict_cache[char]
        if c and c ~= "" then
            return code_cache_put(char, c)
        end
    end

    return code_cache_put(char, "")
end

-- 主词典已有词判定（布隆过滤器，~2% 误判方向为「漏造」不「重造」）
local function main_dict_has_phrase(text)
    if type(text) ~= "string" or text == "" then return false end
    ensure_dict_loaded()
    return bloom_check(text)
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

    local char_codes = {}
    for i, char in ipairs(utf8chars(text)) do
        local code = get_char_wubi_code(char)
        table.insert(char_codes, code)
    end

    local result = ""

    if len == 1 then
        result = (char_codes[1] or ""):sub(1, 4)
    elseif len == 2 then
        result = (char_codes[1] or ""):sub(1, 2) .. (char_codes[2] or ""):sub(1, 2)
    elseif len == 3 then
        result = (char_codes[1] or ""):sub(1, 1) ..
                 (char_codes[2] or ""):sub(1, 1) ..
                 (char_codes[3] or ""):sub(1, 2)
    elseif len >= 4 then
        result = (char_codes[1] or ""):sub(1, 1) ..
                 (char_codes[2] or ""):sub(1, 1) ..
                 (char_codes[3] or ""):sub(1, 1) ..
                 (char_codes[len] or ""):sub(1, 1)
    end

    return result
end

-- ============================================================================
-- == 路径管理 ==
-- ============================================================================

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
    rime_dir = rime_dir:gsub("\\", "/")
    if rime_dir:sub(-1) ~= "/" then
        rime_dir = rime_dir .. "/"
    end
    return rime_dir .. "user_coined_ext.txt"
end

local userphrasepath = init_userphrase_path()

local function get_userphrase_path()
    return userphrasepath
end

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

local function get_autophrase_path()
    if not autophrasepath or autophrasepath == "" then
        autophrasepath = init_autophrase_path()
    end
    return autophrasepath
end

-- ============================================================================
-- == 辅助：编码切分 ==
-- ============================================================================

local function splitinput(input, len)
    if not input or input == "" then
        return ""
    end

    local codes = {}
    for code in input:gmatch("([^`]+)") do
        table.insert(codes, code)
    end

    local result = ""

    if len == 2 then
        if #codes >= 2 then
            result = (codes[1] or ""):sub(1, 2) .. (codes[2] or ""):sub(1, 2)
        else
            result = input:sub(1, 4)
        end
    elseif len == 3 then
        if #codes >= 3 then
            result = (codes[1] or ""):sub(1, 1) ..
                     (codes[2] or ""):sub(1, 1) ..
                     (codes[3] or ""):sub(1, 2)
        else
            result = input:sub(1, 4)
        end
    elseif len >= 4 then
        if #codes >= len then
            result = (codes[1] or ""):sub(1, 1) ..
                     (codes[2] or ""):sub(1, 1) ..
                     (codes[3] or ""):sub(1, 1) ..
                     (codes[len] or ""):sub(1, 1)
        else
            result = input:sub(1, 4)
        end
    else
        result = input:sub(1, 4)
    end

    return result
end

-- ============================================================================
-- == 自造词存储：C++ UserDb（对标魔然，消除热路径 Lua 文件 IO）==
-- ============================================================================
-- key/value 设计：
--   永久词: "e\t<code>\t<text>"  value = "<seq>"    seq 单调递增，用于倒序列表/撤销
--   临时词: "a\t<code>\t<text>"  value = "<tick>"   tick 提交计数，用于淘汰
--   meta:   "\0seq"              value = 下一个 seq 号

---@type UserDb|nil
local uc_db = nil
local uc_migrated = false

local function uc_open()
    if uc_db and uc_db:loaded() then return uc_db end
    local db = LevelDb("lua/user_coined")
    if not db then return nil end
    local ok = pcall(function() db:open() end)
    if not ok or not db:loaded() then return nil end
    uc_db = db
    return uc_db
end

local function uc_manual_key(code, text) return "e\t" .. code .. "\t" .. text end
local function uc_temp_key(code, text)  return "a\t" .. code .. "\t" .. text end

local function uc_parse_key(k)
    local kind, rest = k:match("^([ea])\t(.*)$")
    if not rest then return nil end
    local code, text = rest:match("^([^\t]+)\t(.+)$")
    if not code or not text then return nil end
    return text, code, (kind == "a")
end

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
    if db:fetch(k) ~= nil then return false end
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

local function uc_old_db_exists()
    local dir = get_rime_user_dir()
    if dir == "" then return false end
    dir = dir:gsub("\\", "/")
    if dir:sub(-1) ~= "/" then dir = dir .. "/" end
    local f = io.open(dir .. "user_coined.userdb/CURRENT", "r")
    if f then f:close() return true end
    return false
end

-- 首次打开且 db 无写入痕迹时，迁移旧数据：旧 userdb 优先，其次历史 txt。
local function uc_migrate_once()
    if uc_migrated then return end
    uc_migrated = true
    local db = uc_open()
    if not db then return end
    if db:fetch("\0seq") ~= nil then return end

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
                        return
                    end
                end
            end
        end
    end

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

-- 把一条自动临时词「转正」为永久词（方案 B 后写入 C++ UserDb）。
local function append_manual(text, code)
    if not text or text == "" or not code or code == "" then return false end
    uc_migrate_once()
    local db = uc_open()
    if not db then return false end
    local k = uc_manual_key(code, text)
    if db:fetch(k) ~= nil then return true end
    db:update(k, tostring(uc_next_seq()))
    return true
end

-- 释放大字典，消除「关闭造词后卡顿延续」的 GC 压力（下次查码再懒加载）
local function release_dict()
    char_dict_cache   = nil
    char_dict_phrases = nil
    char_dict_done    = false
    char_code_cache   = {}
    char_code_cache_n = 0
    bloom_blocks      = nil
end

-- ============================================================================
-- == 导出 ==
-- ============================================================================

local M = {}

-- 14键工具
M.get_key_pair      = get_key_pair
M.normalize_14key   = normalize_14key
M.match_encoding    = match_encoding
M.is_14key_layout   = is_14key_layout

-- 字典 / 编码
M.ensure_dict_loaded      = ensure_dict_loaded
M.get_char_wubi_code      = get_char_wubi_code
M.main_dict_has_phrase    = main_dict_has_phrase
M.generate_standard_code  = generate_standard_code
M.release_dict            = release_dict

-- 路径
M.get_userphrase_path = get_userphrase_path
M.get_autophrase_path = get_autophrase_path

-- 辅助
M.valid_word = valid_word
M.u8len      = u8len
M.splitinput = splitinput

-- UserDb 操作
M.uc_open          = uc_open
M.uc_manual_key    = uc_manual_key
M.uc_temp_key      = uc_temp_key
M.uc_parse_key     = uc_parse_key
M.uc_next_seq      = uc_next_seq
M.uc_put_manual    = uc_put_manual
M.uc_put_temp      = uc_put_temp
M.uc_erase_manual  = uc_erase_manual
M.uc_erase_temp    = uc_erase_temp
M.uc_has_manual    = uc_has_manual
M.uc_list_manual   = uc_list_manual
M.uc_list_temp     = uc_list_temp
M.uc_clear_manual  = uc_clear_manual
M.uc_clear_temp    = uc_clear_temp
M.uc_migrate_once  = uc_migrate_once
M.append_manual    = append_manual

return M
