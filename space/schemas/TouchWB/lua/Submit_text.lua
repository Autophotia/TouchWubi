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

-- ★ 2026-11-04 模块化重构：数据服务层（14键工具 / 五笔编码查询 / 路径 / C++ UserDb）
--   已拆到 user_coined_db.lua；自造词即时查询翻译器已拆到 user_coined_translator.lua。
--   本文件只保留「处理器状态机 + 手动造词」。
local db = require "user_coined_db"
local core = require "core"

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
-- == 造词专用日志（统一走 core.dbg，由 core.state.debug_tags 门控，见 core.lua）==
-- =================================================================
local function kcoin(tag, msg)
    core.dbg("COIN:" .. (tag or "?"), msg or "")
end

-- ★ 移动端判定：统一走 core.is_mobile()（2026-11-04 去重，见 core.lua）。
--   用途：把「分号上屏第二候选 / 单引号上屏第三候选」这两个 PC 习惯快捷键
--   在手机上关掉（手机上点候选栏更快，这两个键会被截胡，纯添乱）。

-- ★ 逐键调试日志（统一走 core.dbg，由 core.state.debug_tags 门控）。
local function klog(tag, msg)
    core.dbg(tag, msg)
end

-- =================================================================
-- == 手动造词：逐字累积状态机 ==
-- =================================================================
-- ★ 2026-10-31：手动造词「点击候选栏 / 空格上屏」统一转正保存。
--   点候选栏 = 前端 Context::Select，不产生按键事件 ⇒ commit_text_processor 收不到。
--   保存靠 update_notifier 在提交后结算，判定「是否有新上屏」复用 auto_coined.lua
--   的 detect_and_settle 双判据（size 变 / back 文本变）。
-- ★ v2.11 废弃 super_sequence 的「输入码变空」判据③。
-- ★ v2.12 notifier 统一「单字/词组一律累积」。
local _coin_pending_input = nil
local _coin_buf = {}
local _coin_code_buf = {}
local _coin_last_size     = nil
local _coin_last_text     = nil
local _coin_hooked        = false
local _coin_hooked_schema = nil

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

                if _coin_last_size == nil then
                    _coin_last_size = size
                    _coin_last_text = bt
                    return
                end

                local has_new = (size ~= _coin_last_size) or (bt ~= nil and bt ~= _coin_last_text)
                _coin_last_text = (bt ~= nil) and bt or _coin_last_text
                _coin_last_size = size

                if not has_new then return end
                if _coin_pending_input == nil then return end
                if bt == nil or bt == "" then return end

                local pending_input = _coin_pending_input
                _coin_pending_input = nil
                local n = db.u8len(bt)
                if n >= 1 and not bt:find("%a") then
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

local function fileappendtext(filepath, context, input, env)
    if not context or context == "" or context:find("%a") then
        return
    end

    local len = utf8.len(context)
    local clean_input = ""

    if not filepath or filepath == "" then
        kcoin("write", "ABORT: filepath 为空，写不进去 context=[" .. context .. "]")
        return
    end

    clean_input = db.generate_standard_code(context)
    if not clean_input or clean_input == "" then
        -- 字典查不到（生僻字）降级用用户输入编码（14键 normalize 到标准左字母码）
        clean_input = db.normalize_14key(db.splitinput(input, len) or "")
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
    db.uc_migrate_once()
    if db.uc_put_manual(context, clean_input) then
        kcoin("write", "OK [" .. context .. "] code=" .. clean_input .. " -> userdb")
    else
        kcoin("write", "SKIP: 已存在相同条目 " .. context .. "\t" .. clean_input)
    end
end

-- =================================================================
-- == 处理器：自造词记录 ==
-- =================================================================

local function commit_text_processor(key, env)
    local engine = env.engine
    local context = engine.context
    local composition = context.composition
    local segment = composition:back()
    local input_text = context.input
    local candidate_count = 0

    -- ★ 2026-11-03 修复：PC 端关闭官方 predictor（prediction「总联想」开关）。
    if not core.is_mobile() and context:get_option("prediction") then
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
            -- ★ 2026-11-03 修复：不在「正在打码字母」状态时立即清空二三候选缓存。
            env.last_2th_text = {text="", type=""}
            env.last_3th_text = {text="", type=""}
        end
    end

    local key_code_num = tonumber(key.keycode) or key.keycode
    local is_space_key = (key_code_num == 0x20) or (key_code_num == 32)

    -- ★ 2026-10-31 v2.12 徐码式手动造词（逐字/词组上屏 + 累积保存）
    local function update_manual_userphrase()
        if input_text and input_text:find("`", 1, true) then
            _coin_pending_input = input_text
            -- ★ 造词开始（长按Z 出现反引号）就预加载全量字典
            db.ensure_dict_loaded()
        else
            _coin_pending_input = nil
            if input_text and input_text ~= "" and #_coin_buf > 0 then
                kcoin("buf", "abandon [" .. table.concat(_coin_buf) .. "]")
                _coin_buf = {}
                _coin_code_buf = {}
            end
        end
    end

    update_manual_userphrase()

    -- ★ v2.12 逐字造词结束键 = 长按Z（`）再按空格（放在 has_menu 之前，优先判定）
    if is_space_key and #_coin_buf > 0 and input_text and input_text:match("^`+$") then
        local word = table.concat(_coin_buf)
        local code_input = table.concat(_coin_code_buf)
        _coin_buf = {}
        _coin_code_buf = {}
        _coin_pending_input = nil
        if db.valid_word(word) then
            fileappendtext(db.get_userphrase_path(), word, code_input, nil)
            kcoin("end", "OK [" .. word .. "]")
        else
            kcoin("end", "discard [" .. word .. "]")
        end
        context:clear()
        return 1
    end

    -- 空格语义：有菜单就上屏选中（首）候选
    if is_space_key and context:has_menu() then
        local sel = nil
        if segment then sel = segment:get_selected_candidate() end
        if not sel then
            sel = context:get_selected_candidate()
        end
        if sel and sel.text and sel.text ~= "" then
            context:clear()
            engine:commit_text(sel.text)
            if core.stats_report then core.stats_report(sel.text) end
            return 1
        end
    end

    -- ★ 诊断：缓冲非空但本次空格未触发结束
    if is_space_key and #_coin_buf > 0 then
        kcoin("end", "space buf=" .. #_coin_buf .. " input=[" .. tostring(input_text) .. "] 未匹配^`+$")
    end

    -- 单引号键上屏第三候选（有候选菜单时）
    if key.keycode == 0x27 and not core.is_mobile() then
        klog("Submit_text", "apostrophe key pressed, input=[" .. tostring(context.input) .. "] input_len=" .. tostring(#(context.input or "")) .. " has_menu=" .. tostring(context:has_menu()) .. " is_composing=" .. tostring(context:is_composing()) .. " comp_empty=" .. tostring(composition:empty()) .. " prediction=" .. tostring(context:get_option("prediction")) .. " last_3th_text=" .. (env.last_3th_text and env.last_3th_text.text or "nil"))
        if context.input and context.input ~= "" and env.last_3th_text and env.last_3th_text.text ~= "" then
            klog("Submit_text", "committing 3rd candidate: " .. env.last_3th_text.text)
            context:clear()
            engine:commit_text(env.last_3th_text.text)
            if core.stats_report then core.stats_report(env.last_3th_text.text) end
            return 1
        end
    end

    -- 分号上屏第二候选（同上：手机上禁用，理由一样；判据同为 `input ~= ""`）
    if key.keycode == 0x3B and not core.is_mobile() then
        klog("Submit_text", "semicolon key pressed, input=[" .. tostring(context.input) .. "] input_len=" .. tostring(#(context.input or "")) .. " has_menu=" .. tostring(context:has_menu()) .. " is_composing=" .. tostring(context:is_composing()) .. " comp_empty=" .. tostring(composition:empty()) .. " prediction=" .. tostring(context:get_option("prediction")) .. " last_2th_text=" .. (env.last_2th_text and env.last_2th_text.text or "nil"))
        if context.input and context.input ~= "" and env.last_2th_text and env.last_2th_text.text ~= "" then
            klog("Submit_text", "committing 2nd candidate: " .. env.last_2th_text.text)
            context:clear()
            engine:commit_text(env.last_2th_text.text)
            if core.stats_report then core.stats_report(env.last_2th_text.text) end
            return 1
        end
    end

    return 2
end

-- =================================================================
-- == 模块导出 ==
-- =================================================================
-- 自造词即时查询翻译器已拆至 lua/user_coined_translator.lua（2026-11-04），
-- 由 schema 的 lua_translator@*user_coined_translator 直接 require 注册，本文件不再导出 _G。

return commit_text_processor
