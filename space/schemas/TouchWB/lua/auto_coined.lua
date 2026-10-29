-- ============================================================================
-- auto_coined.lua —— TouchWB 自动连词造词（v2.1 · 2026-10-29 修复：最后一个字丢失 + 简码错字）
--   思路源于 sbsrf 声笔 auto_length，但按 TouchWB 现状重写。
--
--   【版本脉络】
--     v1   初版：临时词写进手动词库 user_coined_ext.txt 并整文件重写。
--          真机实测暴露五个问题：① 覆盖手动造词数据 ② 无文件头 ③ 只能造第一个词
--          ④ 临时词前缀匹配抢占前排候选 ⑤ 堵死手动造词。
--     v2   	a) 独立文件 user_coined_auto.txt（物理隔离手动词库）
--          	b) 写自己的注释头
--          	c) 所有相邻 2..5 窗口（原来只取以最新提交收尾的后缀）
--          	d) 临时词只在整码精确匹配时浮现（Submit_text.lua 侧）
--     v2.1 本次针对真机（00:15 会话）三个新现象：
--          A. 「最后一个字不参与造词」—— 见下方【陷阱】①
--          B. 造词结果稀疏不规则（打一串只出零星几个词）—— 见下方【陷阱】①②
--          C. 撞码：临时词「我人有」与主词典固有词「我们有」同码 twde，
--             永远召回不到 ⇒ 必定躲不过的垃圾词 —— 见下方【陷阱】④
--
--   【陷阱】—— 这些都是本 librime 构建实测出来的接口形态，不是故障，不必去“修”：
--     ① commit_history:back() **滞后一拍**：只有当次按键之后才看得到上一次提交。
--        后果：若完全依赖它，一串字打完停手，最后一次提交要等到「下一次按键」才被读到
--        ⇒ 每串最后一个字结构性丢失（真机现象：打「一二三四五六七」没有「六七」）。
--        ⇒ 修复（见 P_func 的 Signal A）：把本处理器排到 Submit_text **之前**，
--          空格这一拍就不会被 Submit_text 的 return 1 吞掉；在空格按下、提交尚未发生时，
--          用 get_commit_text() 拿到「真正要上屏的字」即时入链 —— 零滞后，最后一个字也入链。
--        commit_history(size+back) 保留为 Signal B 兜底，覆盖数字选词 / 顶字上屏等非空格路径。
--     ② commit_history:iter() 在本构建中**不适用**：绑定把底层 C++ 的 std::reverse_iterator
--        以 userdata 直接返回，而非返回能被 Lua 的 for … in 驱动的迭代函数。
--        这是绑定层暴露接口的形态（记录数据完好，size / back() 均能读），并非运行故障。
--        ⇒ 不遍历历史，用 size + back() 双信号（连打同词时 back 文本不变、size 会 +1，故要同时看 size）。
--     ③ commit_notifier 对空格/分号不触发 ⇒ 不用它。
--     ④ 五笔三字词组的编码规则是「前两字各取**第一码** + 末字取前两码」，
--        所以「我人有」与「我们有」同码（人、们首码都是 w）——这是五笔固有的一维降级，
--        不是 bug。主词典已有「我们有 twde」时，临时词永远抢不到 ⇒ 无法转正。
--        ⇒ 只在「自己两个词库内部」做撞码抑制（同一编码已被别的词条占用就不再造）；
--          与主词典的撞码无法从 processor 侧检测，保留为已知限制。
--     ⑤ get_commit_text() **抓早一拍会错字**（v2.1 曾踩坑）：
--        它返回的是「按键处理前」的高亮候选。用二级/三级简码打字时，最后一个编码键
--        会把候选换成别的字（如 二=fg：输入 f 时高亮是「地」，输入 fg 时才是「二」）。
--        ⇒ 所以 Signal A 只在「空格按下时」抓 get_commit_text()（此刻候选已是最终要上屏的
--          「二」），绝不在输入编码键（f/g）时抓 —— 简码错字不会复发。
--
--   【其它约定】
--     · 词组码复用 Submit_text.generate_standard_code（全局 auto_coined_stdcode），
--       与手动 ` 造词逐字节一致，召回零冲突。
--     · 每次提交只落盘一次。
--     · 临时 → 召回转正 → 过期淘汰：上屏文本命中某临时词 ⇒ 追加进手动词库转正。
--
-- ★ 本模块只新增一个处理器（lua_processor@*auto_coined*P），不改动任何现有逻辑；
--   开关 auto_coined 关（默认）时 P.func 直接放行，零开销。
-- ★ DEBUG_LOG：排查时改为 true，INFO 日志会逐条打印「检测到提交 / 造了哪些词 / 是否撞码」。
-- ============================================================================

local MAX_PHRASE       = 5     -- 临时词窗口：相邻 ≤5 条连续提交
local HIST_KEEP        = 6     -- _hist 缓冲保留条数（≥ MAX_PHRASE 即可）
-- ★ 2026-10-29 修复「第一个字不参与造词」：真机实测打一串字，第一个字（尤其生僻字
--   要想编码）和下一个字之间停顿常常超过 4 秒 ⇒ 被旧阈值误判成「新词组」断链，
--   于是整串词都从第二个字开始造（如「灾洋放扔你」只造出「洋放…」，没有「灾洋」）。
--   参考 smart_assoc 的 IDLE_BREAK_SEC=300 思路，把词组边界阈值放宽到 20 秒：
--   连续打一串字造词的正常停顿（含想生僻字编码）不会被切碎，只有明确停手换话题
--   （>20s）才断链。误连的代价很小——临时词只在整码精确匹配时才浮现，且会过期淘汰。
local PHRASE_GAP_SEC   = 20    -- 两次提交间隔超过此秒数 ⇒ 认为是新词组
local DELETE_THRESHOLD = 200   -- 临时词超过 200 次提交仍未被召回转正 ⇒ 淘汰
local MAX_TEMP_ENTRIES = 300   -- 临时词总量上限，超出则淘汰最旧的
local CLEANUP_EVERY    = 30    -- 每 30 次提交触发一次惰性清理
local DEBUG_LOG        = false -- 逐键诊断日志（真机 log.info 是同步写；2026-10-29 复测验收通过后已关）

local AUTO_HEADER = {
    "# 自动连词造词的临时词库（勿手工编辑）",
    "# 格式：词条<Tab>编码<Tab>temp:<提交序号>",
    "# 整码精确匹配时才浮现（候选带 ☯ 标记）；用该编码上屏一次 ⇒ 转正并入 user_coined_ext.txt",
}

-- ---- 键位判定（抄 smart_assoc.lua，避免「退格删空被误判成上屏」的坑） ----
local BS_KEYCODES = { [0xFF08] = true, [8] = true, [67] = true }   -- 67=安卓 DEL

local function base_repr(repr)
    if not repr or repr == "" then return "" end
    return (repr:match("([^%+]+)$") or repr):lower()
end

local function key_info(key)
    local repr, kc = "", nil
    pcall(function() repr = key:repr() or "" end)
    pcall(function() kc = key.keycode end)
    return repr, kc
end

local function is_backspace(repr, kc)
    local b = base_repr(repr)
    if b == "backspace" or b == "back" or b == "delete_l" then return true end
    return BS_KEYCODES[tonumber(kc) or -1] == true
end

local function is_escape(repr, kc)
    local b = base_repr(repr)
    if b == "escape" or b == "esc" then return true end
    local n = tonumber(kc) or -1
    return n == 0xFF1B or n == 27
end

-- ---- 诊断日志（真机 log.info 只接收第一个参数，故信息全部拼进去） ----
local function klog(tag, msg)
    if not DEBUG_LOG then return end
    pcall(function() if log and log.info then log.info(tag .. " " .. msg) end end)
end

-- ---- 运行态（进程级，跨按键保留） ----
local _hist       = {}          -- 最近提交缓冲，_hist[#_hist] 为最新
local _tick       = 0           -- 自增提交计数，作为临时词年龄基准
local _last_ts    = 0           -- 上一次提交的**发生时戳**，用于判定词组边界
local _last_back  = nil         -- 上一次消费过的 commit_history:back().text
local _last_size  = 0           -- 上一次消费过的 commit_history.size（连打同词时 size 也会 +1）
local _primed     = false       -- 首次进来先把 back 记下来，避免把历史提交当新提交
local _pend_ts    = 0           -- 上一个正常编码键按下的时戳（用于词组间隔的准确判定）

-- 纯汉字判定：UTF-8 中日韩基本区 U+4E00..U+9FFF ⇒ [\228-\233][\128-\191][\128-\191]
local CJK_RUN = "[\228-\233][\128-\191][\128-\191]"
local function is_cjk_word(s)
    if type(s) ~= "string" or s == "" then return false end
    -- ★ 2026-10-29 修复（此处历史上有两个坑，都要避开）：
    --   ① 最早写法 "^"..CJK_RUN.."+$" 里 + 只作用在最后一个字节类 [\128-\191] 上，
    --      只能匹配「单个汉字」，任何 2 字及以上的词（「国早」等）都被误判非中文 ⇒ BREAK 提前 return。
    --   ② 上一版改成 "^("..CJK_RUN..")+$" 是**更错**——Lua pattern 不是正则，(...) 是捕获组、
    --      不能跟 + 量词，导致连单字都匹配失败（真机实测：所有单字都 BREAK non-cjk、造词空文件）。
    --      之前用 Python 的 re 验证 "^(...)+$" 是 Python 正则语义，套到 Lua pattern 上是错的。
    --   正确做法：用 gsub 把每个汉字（3 字节）剥掉，剩空串即纯汉字。已用 LuaJIT 实测通过
    --   （欠/遥/国早/早于厅岂限 均 True；abc/国a/空串 均 False）。
    return s:gsub(CJK_RUN, "") == ""
end

-- ---- 依赖的全局（由 Submit_text.lua / 引擎提供） ----
local function stdcode(phrase)
    local f = _G.auto_coined_stdcode
    if type(f) ~= "function" then return "" end
    local ok, c = pcall(f, phrase)
    return (ok and c) and c or ""
end

local function get_path()
    if type(_G.get_autophrase_path) == "function" then
        local p = _G.get_autophrase_path()
        if p and p ~= "" then return p end
    end
    return ""
end

-- 手动词库路径（用于去重：已在手动库里的词不再生成临时词）
local function get_manual_path()
    if type(_G.get_userphrase_path) == "function" then
        return _G.get_userphrase_path() or ""
    end
    return ""
end

local function invalidate_cache()
    pcall(function()
        if type(_G.UserCoined_InvalidateCache) == "function" then
            _G.UserCoined_InvalidateCache()
        end
    end)
end

-- ---- 自动词库读写（只读/写自己的独立文件，绝不碰手动词库） ----
local function read_rows(path)
    local rows = {}
    if not path or path == "" then return rows end
    local f = io.open(path, "rb")
    if not f then return rows end
    for raw in f:lines() do
        raw = raw:gsub("\r$", "")
        if not raw:match("^#") then
            local text, code, flag = raw:match("^([^\t]+)\t([a-z]+)\t?(.*)$")
            if text and code then
                local n = tonumber((flag or ""):match("^temp:(%d+)$"))
                rows[#rows + 1] = { text = text, code = code, tick = n or 0 }
            end
        end
    end
    f:close()
    return rows
end

local function write_rows(path, rows)
    if not path or path == "" then return false end
    local tmp, old = path .. ".tmp", path .. ".old"
    local f = io.open(tmp, "wb")
    if not f then return false end
    for _, l in ipairs(AUTO_HEADER) do f:write(l, "\n") end
    for _, e in ipairs(rows) do
        f:write(e.text, "\t", e.code, "\ttemp:", tostring(e.tick), "\n")
    end
    f:close()
    os.remove(old)
    if os.rename(path, old) then os.remove(old) end
    if not os.rename(tmp, path) then
        os.remove(tmp)
        return false
    end
    invalidate_cache()
    return true
end

-- ★ v2.1 合并写：先把磁盘上的**最新内容**读回来，再叠加本次的增删。
--   理由：日志文件证实 App 进程也会加载本方案（app 的 INFO 里同样有
--   lua_processor@*auto_coined*P 的加载记录），两个进程各持一份内存镜像、
--   各自整文件重写 ⇒ 后写的会把先写的覆盖掉。改成「读回再合并」后，
--   即使镜像不是最新的也不会删掉别人的成果。
local function flush(adds, removes)
    local p = get_path()
    if p == "" then return end
    local seen, out = {}, {}
    for _, e in ipairs(read_rows(p)) do
        local k = e.text .. "\t" .. e.code
        if removes[k] then
            -- 转正 / 淘汰 ⇒ 不再写回
        elseif not seen[k] then
            seen[k] = true
            out[#out + 1] = e
        end
    end
    for _, e in ipairs(adds or {}) do
        local k = e.text .. "\t" .. e.code
        if not seen[k] then
            seen[k] = true
            out[#out + 1] = e
        end
    end
    write_rows(p, out)
end

-- 手动词库快照：每次提交只重建一次
local function snapshot_manual()
    local exist, owner = {}, {}
    local mp = get_manual_path()
    if mp ~= "" then
        local f = io.open(mp, "rb")
        if f then
            for raw in f:lines() do
                raw = raw:gsub("\r$", "")
                local t, c = raw:match("^([^\t]+)\t([a-z]+)")
                if t and c then
                    exist[t .. "\t" .. c] = true
                    owner[c] = true
                end
            end
            f:close()
        end
    end
    return exist, owner
end

-- 转正：命中的临时词 ⇒ 追加进手动词库
local function promote(text, code)
    local ok = false
    pcall(function()
        if type(_G.UserCoined_AppendManual) == "function" then
            ok = _G.UserCoined_AppendManual(text, code)
        end
    end)
    klog("auto_coined", "promote [" .. text .. "]=" .. code .. " ok=" .. tostring(ok))
    return ok
end

-- 惰性清理：超量（淘汰最旧的）+ 过期（超过 DELETE_THRESHOLD 次提交未召回）
local function cleanup()
    local p = get_path()
    if p == "" then return end
    local rows = read_rows(p)
    if #rows == 0 then return end
    local out = {}
    for _, e in ipairs(rows) do
        if (_tick - e.tick) <= DELETE_THRESHOLD then out[#out + 1] = e end
    end
    local trimmed = false
    if #out > MAX_TEMP_ENTRIES then
        table.sort(out, function(a, b) return a.tick < b.tick end)
        local keep = {}
        for i = #out - MAX_TEMP_ENTRIES + 1, #out do keep[#keep + 1] = out[i] end
        out, trimmed = keep, true
    end
    if #out ~= #rows or trimmed then
        write_rows(p, out)
        klog("auto_coined", "cleanup " .. #rows .. " -> " .. #out)
    end
end

-- 生成所有相邻 2..MAX_PHRASE 窗口的临时词。
--   v1 只取「以最新提交收尾的后缀」⇒ 第二个词组的子词取不到；这里改成全部相邻窗口。
local function build_phrases(adds, exist, owner)
    local n = #_hist
    if n < 2 then return end
    local start0 = math.max(1, n - MAX_PHRASE + 1)
    for s = start0, n - 1 do
        local phrase = ""
        for k = s, n do
            phrase = phrase .. _hist[k]
            local len = utf8.len(phrase) or 0
            if len > MAX_PHRASE then break end
            if len >= 2 then
                local code = stdcode(phrase)
                if code and #code >= 1 and #code <= 5 then
                    local key = phrase .. "\t" .. code
                    if exist[key] then
                        -- 已在临时库或手动库里 ⇒ 不重复造
                    elseif owner[code] then
                        -- ★ 撞码抑制：该编码已被别的词条占用 ⇒ 造出来也永远召回不到（打出来的一定是对方），
                        --   只是白白占位的垃圾词，直接不造。
                        klog("auto_coined", "skip collide [" .. phrase .. "]=" .. code)
                    else
                        exist[key] = true
                        owner[code] = true
                        adds[#adds + 1] = { text = phrase, code = code, tick = _tick }
                        klog("auto_coined", "temp [" .. phrase .. "]=" .. code)
                    end
                end
            end
        end
    end
end

-- ---- 一次提交落定后的处理 ----
--   ts：这次提交**发生时**的时戳（v2.1 关键：不能用「读到的时刻」，否则停手后的
--       最后一次提交会被算成隔了很久 ⇒ 被判定为词组边界 ⇒ 最后一个字掉队）
local function on_commit(text, ts)
    _tick = _tick + 1

    -- 非纯汉字（标点/英文/数字等）⇒ 断链
    if not is_cjk_word(text) then
        if #_hist > 0 then _hist = {} end
        _last_ts = ts
        klog("auto_coined", "tick=" .. _tick .. " BREAK non-cjk [" .. text .. "]")
        return
    end

    -- 词组边界：用提交发生时的真实间隔判定
    if #_hist > 0 and (ts - _last_ts) > PHRASE_GAP_SEC then
        _hist = {}
        klog("auto_coined", "tick=" .. _tick .. " gap=" .. (ts - _last_ts) .. "s -> new phrase")
    end
    _last_ts = ts

    _hist[#_hist + 1] = text
    if #_hist > HIST_KEEP then
        local t = {}
        for i = #_hist - HIST_KEEP + 1, #_hist do t[#t + 1] = _hist[i] end
        _hist = t
    end
    klog("auto_coined", "tick=" .. _tick .. " commit [" .. text .. "] hist=" .. table.concat(_hist, "|"))

    -- 索引：把临时库与手动库里现有的 「词条\t编码」和「编码」都登记进来。
    --   注意两份索引用途不同，必须分开：exist/owner 用于「造新词去重」，
    --   manual_exist 用于「转正判据」。若混用，临时库里已有的条目会被误判成
    --   「已在手动库」 ⇒ 永远转不了正。
    local rows = read_rows(get_path())
    local manual_exist, manual_owner = snapshot_manual()
    local exist, owner = {}, {}
    for k, v in pairs(manual_exist) do exist[k] = v end
    for k, v in pairs(manual_owner) do owner[k] = v end
    for _, e in ipairs(rows) do
        exist[e.text .. "\t" .. e.code] = true
        owner[e.code] = true
    end

    -- 本次提交若本身命中某条临时词（用户用词组码召回并上屏）⇒ 转正并入手动库
    local removes = {}
    for _, e in ipairs(rows) do
        local k = e.text .. "\t" .. e.code
        if e.text == text then
            if not manual_exist[k] then
                if promote(e.text, e.code) then
                    removes[k] = true
                end
            else
                -- 手动库已有同词同码（此前已转正），临时库里的同名条目是残留僵尸，
                -- 直接移除，避免候选栏同时出现「词」与「词☯」两个重复候选。
                removes[k] = true
            end
        end
    end

    -- 拼所有相邻 2..5 字窗口造临时词；本提交**只落盘一次**
    local adds = {}
    build_phrases(adds, exist, owner)
    if #adds > 0 or next(removes) then flush(adds, removes) end

    if _tick % CLEANUP_EVERY == 0 then cleanup() end
end

-- ---- 按键时戳捕获：按键处理**之前**记下「这一个正常编码键是何时按下的」 ----
--   ★ 2026-10-29 起不再用它抓「上屏文本」——那个交给 commit_history 读（见 P_func），
--   因为 get_commit_text() 在按键处理前抓到的是「当时的高亮候选」，用简码打字时
--   最后一个编码键会把候选换成另一个字（如 二=fg：f 时是「地」，fg 时才是「二」），
--   抓早了就会错字。这里只保留时戳（词组间隔要用「按键发生时刻」而非「被读到时刻」）。
--   退格 / Esc / 数字选词 / ; ' 都要排除：它们会让输入码「从非空变空」但不是提交。
local function capture_pending(ctx, key)
    local pend_input = ctx.input or ""
    _pend_ts = 0
    if pend_input == "" then return end
    local repr, kc = key_info(key)
    if is_backspace(repr, kc) then return end
    if is_escape(repr, kc) then return end
    local b = base_repr(repr)
    if b:match("^%d$") then return end
    local n = tonumber(kc) or -1
    if n == 0x3B or n == 0x27 then return end
    _pend_ts = os.time()
end

-- ---- 处理器：每个按键都跑；仅在开关开启且确有新提交时做事 ----
local function P_func(key_event, env)
    if not env or not env.engine or not env.engine.context then return 2 end
    local ctx = env.engine.context

    -- 开关 gate：关 ⇒ 直接放行，零开销
    local on = false
    pcall(function() on = ctx:get_option("auto_coined") end)
    if not on then return 2 end

    local input = ctx.input or ""

    -- 提交历史：size 是「累计提交次数」，back().text 是「最近一次上屏的文本」。
    local size, bt = 0, nil
    pcall(function() size = ctx.commit_history.size end)
    pcall(function()
        local b = ctx.commit_history:back()
        if b then bt = b.text end
    end)
    if not _primed then
        _primed, _last_back, _last_size = true, bt, size
    end

    local committed, ts = nil, 0

    -- Signal A（即时，主力）：空格键将上屏当前选中候选。
    --   ★ 2026-10-29 修复「最后一个字进不了临时词 / 转正不生效」：
    --   本处理器必须排在 Submit_text **之前**（见 schema processors 顺序），这样空格
    --   这一拍不会被 Submit_text 的 return 1 吞掉，我们能在提交发生前用
    --   get_commit_text() 拿到「真正要上屏的字」。这里抓的是「空格按下时」的高亮候选
    --   （不是输入第一个编码时的高亮），所以简码打「二=fg」也能拿到「二」而非「地」——
    --   上一版「错字」的坑不会复发。
    --   提交的文本仍与 commit_history 一致（真上屏账本），只是不再晚一拍。
    local kc = 0
    pcall(function() kc = key_event.keycode end)
    local is_space = (kc == 0x20) or (kc == 32)
    if is_space and input ~= "" and not input:find("`") then
        local has_menu = false
        pcall(function() has_menu = ctx:has_menu() end)
        if has_menu then
            local t = nil
            pcall(function() t = ctx:get_commit_text() end)
            if t and t ~= "" then
                committed, ts = t, os.time()
                -- 预登记：Submit_text 即将提交 t ⇒ commit_history 会 size+1、back 变 t。
                -- 把 _last_* 提前拨到提交后的值，避免下一键的 Signal B 把这次提交重复读一遍。
                _last_back, _last_size = t, size + 1
            end
        end
    end

    -- Signal B（兜底）：commit_history 变了（数字选词 / 顶字上屏 / 自动上屏等非空格路径）。
    if not committed then
        local has_new = (size ~= _last_size) or (bt and bt ~= _last_back)
        if has_new and bt then
            committed = bt
            -- 时间戳：优先用「上一个正常编码键按下的时刻」（_pend_ts），
            -- 数字选词 / ; ' / 退格等非编码键会把 _pend_ts 清 0，此时退回 os.time()。
            if _pend_ts and _pend_ts > 0 then
                ts = _pend_ts
            else
                ts = os.time()
            end
        end
        _last_back, _last_size = bt or _last_back, size
    end

    if committed and committed ~= "" then
        local ok, err = pcall(on_commit, committed, ts)
        if not ok then klog("auto_coined", "on_commit error: " .. tostring(err)) end
    end

    pcall(capture_pending, ctx, key_event)
    return 2
end

return {
    P = { func = P_func },
}

-- ============================================================================
-- 冒烟测试（真机验证清单）：
--   0. 部署 + 切一次方案后，确认日志里 lua_processor@*auto_coined*P 为 success=1。
--   1. 手工清理旧 user_coined_ext.txt 里所有带 `temp:` 的行（历史垃圾；新代码已自动跳过，仍建议删）。
--   2. 【验证 A】打开开关，逐字上屏「一二三四五」，打完**停手 3 秒以上**再干别的
--      ⇒ 这一次最后的「五」必须入链：文件里要有「四五」等以五收尾的词。
--      这是 v2.1 修复的核心用例（v2 会丢最后一个字）。
--   3. 【验证 B】正常速度打「我人有的和主」⇒ 应该一次性产出
--      我人/人有/有的/的和/和主/我人有/人有的/… 等全部相邻 2..5 窗口词。
--   4. 【验证 C】打两个字母（如 lh）⇒ 候选里不该出现带 ☯ 的自动词（整码精确匹配才浮现）。
--   5. 【验证转正】打出某临时词的完整编码（如 四五 的 lhgg）⇒ 出现带 ☯ 的「四五」候选；
--      上屏它 ⇒ user_coined_ext.txt 新增 `四五	lhgg`，user_coined_auto.txt 中移除。
--   6. 【已知限制】撞码：临时词与主词典固有词同码时（如「我人有」vs「我们有」同为 twde），
--      打出来的一定是主词典那个词 ⇒ 该临时词永远无法转正，只能等过期淘汰。这是五笔
--      三字词组「前两字只取首码」的固有降维，不是 bug。
--   7. 关掉 auto_coined 开关 ⇒ 不再产生新自动词，已转正的永久词正常召回。
--   8. 【验证 D·简码错字】用二级简码打「二」（码 fg，首码 f 高亮是「地」）上屏
--      ⇒ 造进新词的必须是「二」而不是「地」；连打「二二」两个相同字也要各自入链。
-- 排查：把本文件顶部 DEBUG_LOG 改成 true，重部署后 INFO 日志会打印每条提交的
--       （tick / 上屏文本 / 当前缓冲 / 造出的临时词 / 撞码跳过 / 词组边界重置）。
-- 回滚：删除 4 套 schema 里的 lua_processor@*auto_coined*P 一行与 auto_coined 开关，删除本文件；
--       再撤销 Submit_text.lua 的 get_autophrase_path / UserCoined_AppendManual / temp 相关改动。
-- ============================================================================
