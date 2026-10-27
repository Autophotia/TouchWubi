-- ============================================================
-- 自造词管理命令（2026-10-27 新增）
--   编写：Autophotia（超越输入法 · TouchWB 双键五笔方案）
--        https://github.com/Autophotia/TouchWubi
--
-- 【为什么要有这个文件】
--   自造词只能加不能删：此前唯一的出路是连電腦/文件管理器打开
--   user_coined_ext.txt 手工改。手机上做不到，于是造错的词只能一直留着。
--   本文件提供五个命令，把「看得到 + 删得掉 + 删错了能救」补上：
--
--     /zctj        统计（自造词条数 + 备份条数）+ 倒序全量列表
--     /zcscNN      删除倒序第 NN 条（序号固定 2 位，01 = 最近造的那条，上限 99）
--     /zccx        撤销：一键删除最后造的词
--     /zcqk        清空全部（清空前自动备份到 user_coined_ext.bak）
--     /zcdr        导入：从 .bak 合并恢复（只补当前没有的词）
--
--   「备份」不单设命令，与 /zctj 合用：有备份就显示「有备份：共 N 条」。
--   清空时的备份是「合并去重」：把当前库里、备份里没有的词追加进备份，
--   备份永远是「历史上造过的所有词的并集」，条数只增不减，才谈得上兜底。
--
-- 【三条绕不开的约束 —— 决定了实现为什么长这样】
--   1. speller.alphabet 里没有数字（zyxwvutsrqponmlkjihgfedcba`/@=），
--      所以 "/zcsc01" 的 01 会被 speller 直接丢掉 ⇒ 数字必须由 P 用
--      context:push_input() 接管，和 calc_symbol_processor 处理算式數字同一套路。
--      序号固定 2 位（01~99），P 只在前 2 位内接管，满 2 位即触发删除。
--   2. 点击候选栏上屏不产生按键事件 ⇒ 「选中候选即删」做不到。
--      改用本方案既有的套路：副作用在 F（filter）里执行，命令串打完即生效，
--      和 /lxqk 完全一致。
--   3. 写入是 append，所以文件末行 = 最近造的词 ⇒ /zccx 直接删末行，
--      不依赖任何会话状态，中间打多少字都不受影响。
--
-- 【挂载】4 份 schema.yaml 各加三行：
--     processors:  - lua_processor@*user_coined_cmd*P
--     translators: - lua_translator@*user_coined_cmd*T
--     filters:     - lua_filter@*user_coined_cmd*F
--   另需在 recognizer/patterns 加（两份主方案即可，14键版靠 __include 继承）：
--     coin_cmd: "^/zc[a-z]+[0-9]+$"      # 只兜带参数的 /zcsc01，纯字母命令仍走 punct
--
-- ★ 新增 / 删除命令时，记得同步改 help_cmd.lua 的 GROUPS。
-- ============================================================

-- 单次执行锁：记住上一帧的 input 与最后一次的执行结果。
-- input 与上一帧相同 ⇒ 说明 compose 重跑了（翻页、重绘），此时：
--   ① 绝不重复执行删除（否则会连删两条）；
--   ② 把上次的结果候选再吐一条，用户不至于看不到执行结果。
local _prev_input = nil
local _last_res = nil

-- 列表展示上限：真有几百条也只显示最近的，超出部分用一条候选说明。
local LIST_LIMIT = 200

-- 清空后的文件头，与 Submit_text.lua 的 ensure_userphrase_file 保持一致
-- （三行、均无尾随换行，保证后续 append 不会多空出一个空行）
local HEADER = {
    "# 自造词文件",
    "# 格式：词条<Tab>编码",
    "# 即时生效，无需重新部署",
}

-- ============================================================
-- == 文件读写层 ==
-- ============================================================

-- 自造词文件路径。优先复用 Submit_text.lua 的全局函数（口径唯一）；
-- 拿不到（模块未加载/路径尚未就绪）时按同样规则自己拼一次。
local function get_path()
    local p = nil
    pcall(function()
        if type(get_userphrase_path) == "function" then
            p = get_userphrase_path()
        end
    end)
    if p and p ~= "" then return p end
    pcall(function()
        local d = rime_api and rime_api.get_user_data_dir and rime_api.get_user_data_dir() or ""
        if d == "" then return end
        d = d:gsub("\\", "/")
        if d:sub(-1) ~= "/" then d = d .. "/" end
        p = d .. "user_coined_ext.txt"
    end)
    return p or ""
end

-- 备份文件路径：单份 user_coined_ext.bak。
-- ★ 为什么是单份而非多份：备份采用「合并去重」，每轮清空只往备份里追加新词、
--   从不删旧，所以一份备份就完整覆盖全部历史，不需要多份轮转。
local function get_bak_path()
    local p = get_path()
    if p == "" then return "" end
    return p .. ".bak"
end

-- 让 Submit_text.lua 的自造词缓存（user_coined_translator 用的那份）立即失效，
-- 否则删完还会从旧缓存里冒出来，最多滞后一个 TTL（60 秒）。
local function invalidate_cache()
    pcall(function()
        if type(UserCoined_InvalidateCache) == "function" then
            UserCoined_InvalidateCache()
        end
    end)
end

-- 读文件：返回 lines（原样逐行，含注释行）与 entries（有效条目倒序表）
-- entries[i] = { text=词条, code=编码, line=在 lines 中的行号 }
-- 注意：entries 是**倒序**的（最新造的排第 1），与命令里用的序号口径一致。
local function read_all()
    local p = get_path()
    if p == "" then return nil, nil, "路径未就绪" end

    local f = io.open(p, "rb")
    local lines = {}
    if f then
        for raw in f:lines() do
            -- ★ 二进制读：Windows 文本模式会把 \r\n 翻成 \n（写入时反之亦然），
            --   那样同一个文件在 PC 上重写一遍就变 CRLF、回到手机又变回 LF，
            --   行尾来回漂更容易出问题。这里统一剥掉行尾的 \r，保证写出的永远是 LF。
            --   （循环变量在 Lua 5.5 起只读，故用 raw 转一道）
            local line = raw:gsub("\r$", "")
            lines[#lines + 1] = line
        end
        f:close()
    end
    -- 文件不存在 = 还没造过词，按空库处理（不是错误）

    local entries = {}
    for i, line in ipairs(lines) do
        if not line:match("^#") and line ~= "" then
            local text, code = line:match("^([^\t]+)\t([a-z]+)")
            if text and code then
                entries[#entries + 1] = { text = text, code = code, line = i }
            end
        end
    end

    local rev = {}
    for i = #entries, 1, -1 do rev[#rev + 1] = entries[i] end
    return lines, rev, nil
end

-- 原子化写回：临时文件写完再改名归位，避免写一半崩掉把自造词库弄坏。
-- ★ 不额外补行尾换行：还原文件原本的样子（原文件的最后一行是没有换行的，
--   Submit_text 的 fileappendtext 追加时才自己补 "\n"）。
local function write_lines(p, lines)
    local tmp = p .. ".tmp"
    local f = io.open(tmp, "wb")      -- ★ wb：不做行尾翻译，永远写 LF
    if not f then return false, "临时文件打不开" end
    for i, line in ipairs(lines) do
        if i > 1 then f:write("\n") end
        f:write(line)
    end
    f:close()

    local old = p .. ".old"
    os.remove(old)
    -- ★ 目标文件可能本来就不存在（写 .bak 备份 / 首次生成主文件都是这种情况），
    --   rename 会失败；这时不算错误，按「新建」处理，别把整次写入掐掉。
    local had_old = os.rename(p, old)
    if not had_old then os.remove(old) end

    if not os.rename(tmp, p) then
        if had_old then os.rename(old, p) end     -- 归位失败就把原件放回去
        os.remove(tmp)
        return false, "新文件归位失败"
    end
    if had_old then os.remove(old) end
    return true, nil
end

-- 删除 lines 里指定的行号，返回新 lines
local function drop_line(lines, lineno)
    local out = {}
    for i, line in ipairs(lines) do
        if i ~= lineno then out[#out + 1] = line end
    end
    return out
end

-- ============================================================
-- == 备份层 ==
-- ============================================================

-- 给内容打上备份时间戳（写成注释行，自造词 translator 本来就忽略 # 行）。
-- ★ 为什么必须自己写：Lua 拿不到文件的修改时间（没有 lstat），
--   不写进内容里的话用户永远不知道这份备份是哪天备的。
-- ★ os.date 在个别精简运行时里可能不可用 ⇒ pcall 兜底，取不到就只备份不记时。
local function stamp_lines(lines)
    local out = {}
    for _, l in ipairs(lines) do
        if not l:match("^#%s*备份时间") then out[#out + 1] = l end
    end
    local t = nil
    pcall(function() t = os.date("%Y-%m-%d %H:%M") end)
    if t and t ~= "" then table.insert(out, 1, "# 备份时间：" .. t) end
    return out
end

-- 写备份：合并去重（union）。
-- ★ 语义：备份 = 旧备份 ∪ 当前库。旧备份已有的词条原样保留（含编码与顺序），
--   当前库里、旧备份没有的词条按「旧→新」追加到备份末尾。
--   这样无论清空多少次、中间删过多少词，备份永远只增不减、不丢词。
-- ★ 判重键用「词条」而非「词条+编码」：与 /zcdr 恢复一致（同词两码无意义），
--   且以旧备份里已有的编码为准 —— 用户后来改过的编码不被覆盖。
-- 返回值：ok, added（成功时为本次并入的新词条数；失败时为错误串）
local function backup_lines(lines, entries)
    local p = get_bak_path()

    -- 读旧备份的物理行（正序，含注释头）与已有词条集合
    local bak_lines = {}
    local bak_have = {}
    local of = io.open(p, "rb")
    if of then
        for raw in of:lines() do
            local line = raw:gsub("\r$", "")
            bak_lines[#bak_lines + 1] = line
            local text = line:match("^([^\t]+)\t[a-z]+")
            if text then bak_have[text] = true end
        end
        of:close()
    end

    -- entries 是倒序（最新在前）；从尾到头遍历 = 正序（旧→新）追加，
    -- 保证备份物理顺序仍是「旧→新」，末行始终是本次并入里最新的词。
    local added = 0
    for i = #entries, 1, -1 do
        local e = entries[i]
        if not bak_have[e.text] then
            bak_lines[#bak_lines + 1] = e.text .. "\t" .. e.code
            bak_have[e.text] = true
            added = added + 1
        end
    end

    -- stamp_lines 会摘掉旧的「备份时间」行并在最前插新时间，因此时间戳始终新鲜
    local ok, werr = write_lines(p, stamp_lines(bak_lines))
    if not ok then return false, tostring(werr) end
    return true, added
end

-- 读备份：返回 entries（倒序，同 read_all 口径）、备份时间串。
-- 备份文件不存在不是错误 —— 返回空 entries，由调用方提示「暂无备份」。
local function read_backup()
    local p = get_bak_path()
    if p == "" then return nil, nil, "路径未就绪" end

    local f = io.open(p, "rb")
    if not f then return {}, nil, nil end

    local lines, stamp = {}, nil
    for raw in f:lines() do
        local line = raw:gsub("\r$", "")
        lines[#lines + 1] = line
        local s = line:match("^#%s*备份时间：(.+)$")
        if s then stamp = s end
    end
    f:close()

    local entries = {}
    for _, line in ipairs(lines) do
        if not line:match("^#") and line ~= "" then
            local text, code = line:match("^([^\t]+)\t([a-z]+)")
            if text and code then entries[#entries + 1] = { text = text, code = code } end
        end
    end

    local rev = {}
    for i = #entries, 1, -1 do rev[#rev + 1] = entries[i] end
    return rev, stamp, nil
end

-- ============================================================
-- == 操作层：三个动作 ==
-- ============================================================

local function op_delete_index(n)
    local lines, entries, err = read_all()
    if err then return false, err end
    if #entries == 0 then return false, "暂无自造词" end
    if n < 1 or n > #entries then
        return false, string.format("没有第 %d 条（共 %d 条）", n, #entries)
    end

    local target = entries[n]
    local p = get_path()
    local ok, werr = write_lines(p, drop_line(lines, target.line))
    if not ok then return false, tostring(werr) end

    invalidate_cache()
    return true, string.format("已删除第 %d 条：%s（%s）", n, target.text, target.code), #entries - 1
end

local function op_delete_last()
    local lines, entries, err = read_all()
    if err then return false, err end
    if #entries == 0 then return false, "暂无自造词" end

    local target = entries[1]
    local p = get_path()
    local ok, werr = write_lines(p, drop_line(lines, target.line))
    if not ok then return false, tostring(werr) end

    invalidate_cache()
    return true, string.format("已撤销最近造的词：%s（%s）", target.text, target.code), #entries - 1
end

local function op_clear_all()
    local lines, entries, err = read_all()
    if err then return false, err end
    if #entries == 0 then return false, "暂无自造词" end

    local p = get_path()
    -- 清空是唯一没法挽回的动作 ⇒ 先把当前库并进备份（合并去重），真后悔还能 /zcdr 翻回来
    local bok, added = backup_lines(lines, entries)
    if not bok then
        -- 备份失败就中止清空：宁可清不掉，也不冒「删光且没退路」的风险
        return false, "备份失败，已中止清空：" .. tostring(added)
    end

    local ok, werr = write_lines(p, { HEADER[1], HEADER[2], HEADER[3] })
    if not ok then return false, tostring(werr) end

    invalidate_cache()
    if added > 0 then
        return true, string.format("已清空 %d 条自造词（备份并入 %d 条新词）", #entries, added), 0
    end
    return true, string.format("已清空 %d 条自造词（词条均已在备份中）", #entries), 0
end

-- 导入恢复 /zcdr：把备份里的词条并回当前库（合并去重，只补缺）。
-- ★ 合并去重而非覆盖：覆盖会把「清空之后到现在」新造的词一起抹掉，
--   而真实的后悔场景基本都是「清空后想找回」，合并才不倒退。
-- ★ 判重键用「词条」而不是「词条+编码」：同一个词两个编码没有意义，
--   且以现有库为准 —— 用户后面改过的编码不该被旧备份盖回去。
local function op_restore()
    local bentries, _, err = read_backup()
    if err then return false, err end
    if #bentries == 0 then
        return false, "暂无备份（/zcqk 清空时会自动备份）"
    end

    local lines, cur, rerr = read_all()
    if rerr then return false, rerr end

    local have = {}
    for _, e in ipairs(cur) do have[e.text] = true end

    local added = 0
    -- ★ 按「备份的原始顺序」写回：read_backup 给的是倒序（最新在前），
    --   这里从尾到头遍历 = 正序 append，保证恢复后文件末行仍是备份里最新造的词，
    --   否则 /zccx、/zcscN 的序号语义（末行=最新）会被整个反转。
    for i = #bentries, 1, -1 do
        local e = bentries[i]
        if not have[e.text] then
            lines[#lines + 1] = e.text .. "\t" .. e.code
            have[e.text] = true
            added = added + 1
        end
    end

    if added == 0 then
        return true, "备份中的词条都已在库里，无需恢复", #cur
    end

    local p = get_path()
    -- 库原本就是空的（文件不存在）时补回注释头，让格式与 Submit_text 生成的一致
    if #lines == added then
        local l = { HEADER[1], HEADER[2], HEADER[3] }
        for _, x in ipairs(lines) do l[#l + 1] = x end
        lines = l
    end
    local ok, werr = write_lines(p, lines)
    if not ok then return false, "写回失败：" .. tostring(werr) end

    invalidate_cache()
    return true, string.format("已从备份导入 %d 条（备份共 %d 条）", added, #bentries),
           #cur + added
end

-- ============================================================
-- == 命令识别 ==
-- ============================================================

local function get_input(env)
    local inp = ""
    pcall(function() inp = env.engine.context.input or "" end)
    return inp
end

-- 返回该输入是否是本模块的命令（用于 T/F 决定是否接管）
-- 第二个返回值：del_n → 序号；其余命令无参数
-- ★ 序号固定 2 位（01~99）：/zcsc 输满 2 位数字才删除，天然定界，
--   避免变长序号在「输完即删」模型下「输 1 就被当删第 1 条」的歧义。
local function parse_cmd(inp)
    if type(inp) ~= "string" then return nil end
    -- /zcsc + 满 2 位数字 = 删除该序号（01~99）
    local n2 = inp:match("^/zcsc(%d%d)$")
    if n2 then
        local idx = tonumber(n2)
        if idx and idx >= 1 then return "del_n", idx end
        return "del_zero"          -- /zcsc00：序号 0 无效
    end
    -- /zcsc + 0~1 位数字（含纯 /zcsc）= 显示列表，等待补全到 2 位
    if inp:match("^/zcsc%d?$") then return "del_list" end
    if inp == "/zccx" then return "del_last" end
    if inp == "/zcqk" then return "clear" end
    if inp == "/zctj" then return "stat" end
    if inp == "/zcdr" then return "restore" end
    return nil
end

-- ============================================================
-- == T：翻译器 —— 负责 /zctj 展示，其余命令吐占位候选 ==
-- ============================================================

local function T(input, seg, env)
    local inp = get_input(env)
    local kind, arg = parse_cmd(inp)
    if not kind then return end

    local function put(text, comment)
        yield(Candidate("coin_cmd", seg.start, seg._end, text, comment or ""))
    end

    -- 倒序列表渲染（序号 2 位补零），/zctj 与 /zcsc 共用
    local function render_entries(entries)
        local shown = math.min(#entries, LIST_LIMIT)
        for i = 1, shown do
            local e = entries[i]
            put(string.format("%02d. %s", i, e.text), e.code)
        end
        if #entries > LIST_LIMIT then
            put(string.format("※ 仅显示最近 %d 条（共 %d 条）", LIST_LIMIT, #entries),
                "删到 " .. LIST_LIMIT .. " 条以内可看全")
        end
    end

    -- /zcsc00：序号 0 无效
    if kind == "del_zero" then
        put("※ 序号从 01 开始，如 01 删第 1 条", "00 不是有效序号")
        return
    end

    -- /zcsc（含 0~1 位数字）：直接显示词条列表，输满 2 位序号即删
    if kind == "del_list" then
        local _, entries, err = read_all()
        if err then
            put("※ 自造词文件不可用：" .. tostring(err), "")
            return
        end
        if #entries == 0 then
            put("※ 暂无自造词", "打「编码`编码」+ 空格可造词")
            return
        end
        put(string.format("※ 自造词共 %d 条 · 输 2 位序号删除", #entries),
            "如 01 删第 1 条、12 删第 12 条")
        render_entries(entries)
        return
    end

    -- 其余命令的候选由 F 产出，这里给一条占位，
    -- 保证该 segment 有候选 ⇒ F 一定会被调用（没有候选的段不会被 filter 处理）
    if kind ~= "stat" then
        put("※ 自造词管理 …", inp)
        return
    end

    -- ===== /zctj：统计 + 倒序列表 =====
    local lines, entries, err = read_all()
    if err then
        put("※ 自造词文件不可用：" .. tostring(err), "")
        return
    end

    -- 备份条数：不单设命令，直接并进摘要行回答「有没有备份」
    local b_entries, bstamp = read_backup()
    local b_count = (b_entries and #b_entries) or 0

    if #entries == 0 then
        if b_count > 0 then
            put(string.format("※ 暂无自造词 · 有备份：共 %d 条", b_count), "/zcdr 可从备份导入")
        else
            put("※ 暂无自造词", "打「编码`编码」+ 空格可造词")
        end
        return
    end

    -- 异常条目：编码长度不在 1~5 之间（正常五笔码 1~4，混输模式最多 5）
    local abnormal, dup = 0, 0
    local seen = {}
    for _, e in ipairs(entries) do
        if #e.code < 1 or #e.code > 5 then abnormal = abnormal + 1 end
        local key = e.text .. "\t" .. e.code
        if seen[key] then dup = dup + 1 end
        seen[key] = true
    end

    local head, head_comment
    if b_count > 0 then
        head = string.format("※ 自造词：共 %d 条 · 有备份：共 %d 条", #entries, b_count)
        head_comment = string.format("最新 %s（%s）", entries[1].text, entries[1].code)
            .. (bstamp and (" · 备份于 " .. bstamp) or "")
    else
        head = string.format("※ 自造词：共 %d 条", #entries)
        head_comment = string.format("最新 %s（%s）", entries[1].text, entries[1].code)
    end
    local tail = ""
    if abnormal > 0 then tail = tail .. string.format(" 异常 %d", abnormal) end
    if dup > 0 then tail = tail .. string.format(" 重复 %d", dup) end
    put(head, tail ~= "" and (head_comment .. " · 待整理：" .. tail) or head_comment)

    render_entries(entries)
end

-- ============================================================
-- == F：过滤器 —— 执行删除 / 清空，并吐结果候选 ==
-- ============================================================

local function F(input, env)
    local inp = get_input(env)
    local kind, arg = parse_cmd(inp)

    if not kind then
        _prev_input = inp
        _last_res = nil
        for cand in input:iter() do yield(cand) end
        return
    end

    -- /zctj、/zcsc 列表、/zcsc00 提示都只是展示，候选由 T 产出，原样放行
    if kind == "stat" or kind == "del_list" or kind == "del_zero" then
        _prev_input = inp
        for cand in input:iter() do yield(cand) end
        return
    end

    -- 重复触发：不重复删除，把上次的结果再显示一遍
    if _prev_input == inp then
        if _last_res then
            yield(Candidate("coin_cmd", _last_res.s, _last_res.e,
                            _last_res.text, _last_res.comment))
        else
            for cand in input:iter() do yield(cand) end
        end
        return
    end
    _prev_input = inp

    local ok, msg, left = false, "", 0
    if kind == "del_n" then
        ok, msg, left = op_delete_index(arg)
    elseif kind == "del_last" then
        ok, msg, left = op_delete_last()
    elseif kind == "clear" then
        ok, msg, left = op_clear_all()
    elseif kind == "restore" then
        ok, msg, left = op_restore()
    end

    local seg_start, seg_end = 0, #inp
    pcall(function()
        local seg = env.engine.context.composition:back()
        if seg then seg_start, seg_end = seg.start, seg._end end
    end)

    local comment = ""
    if ok then
        if kind == "clear" then
            comment = "/zcdr 可从备份导入"
        elseif kind == "restore" then
            comment = "/zctj 查看当前条数"
        elseif left and left > 0 then
            comment = string.format("还剩 %d 条", left)
        end
    end
    _last_res = { s = seg_start, e = seg_end, text = "※ " .. msg, comment = comment }
    yield(Candidate("coin_cmd", seg_start, seg_end, "※ " .. msg, comment))
end

-- ============================================================
-- == P：处理器 —— 接管 /zcsc 后面的数字键 ==
-- ==    alphabet 不含数字，不接管的话数字会被 speller 丢掉 ==
-- ==    序号固定 2 位：已输入满 2 位数字就不再接管，避免 3 位 ==
-- ============================================================

local function P(key, env)
    if key:release() then return 2 end
    if key:ctrl() or key:alt() then return 2 end

    -- 在 /zcsc 前缀下接管数字键，且已输入数字不足 2 位（满 2 位即触发删除）
    local inp = get_input(env)
    local ndigits = inp:match("^/zcsc(%d*)$")
    if not ndigits then return 2 end
    if #ndigits >= 2 then return 2 end

    local digit = nil
    pcall(function()
        local r = key:repr()
        digit = r:match("^(%d)$") or r:match("^KP_(%d)$")
    end)
    if not digit then return 2 end

    local ok = pcall(function() env.engine.context:push_input(digit) end)
    if ok then return 1 end        -- kAccepted
    return 2
end

return { P = P, T = T, F = F }
