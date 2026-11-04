-- core.lua — TouchWB 纯内存状态表（跨组件共享信号）
-- -----------------------------------------------------------------------------
-- 设计意图（参照 sbsrf 的 lua/sbxlm/core.lua 里的 core.state）：
--
--   跨组件需要传递的「瞬时状态信号」，一律写进 core.state 这张**纯 Lua 内存表**，
--   刻意**不写 option / property、不触发任何 notifier、不引起界面刷新**。
--
--   这替代了此前把 `_G.__touchwb_*` 当跨文件信号用的做法 —— `_G` 是全局命名空间，
--   谁都能写、谁都能读、名字易撞、语义难查；而 core.state 有明确的字段清单与注释，
--   状态来源单一、可检索、可类型标注，正是模块化重构要立的规矩。
--
--   作用域：require "core" 按 Lua 模块缓存，同一引擎（同一 Lua VM）内所有组件
--           拿到的是同一张表，与旧 `_G` 的作用域完全一致，语义零变化。
--
-- 使用方式：local core = require "core"  →  core.state.xxx
local core = {}

core.state = {
    -- 智能联想段标志（原 _G.__touchwb_assoc_seg）
    -- 写点：smart_assoc.lua 的 mark_assoc_seg()，true=处于联想段；off 时置 nil（非 false）。
    -- 读点：pair_punct.lua 标点豁免判据（唯一控制流读点）；smart_assoc.lua 探针日志。
    assoc_seg = nil,

    -- 标点豁免计数（原 _G.__touchwb_punct_exempt）
    -- 写点：pair_punct.lua 标点豁免分支自增 / 非豁免清 0；仅诊断探针用，不参与控制流。
    punct_exempt = 0,

    -- 标点决策诊断开关（原 _G.__touchwb_punct_dbg）
    -- 用途：排查「上屏后按标点乱出字」时临时置 true 打印决策现场，定位后改回 false。
    punct_dbg = false,

    -- 联想预测标志（原 _G.__touchwb_assoc_predicting）
    -- 状态：自 S88 起写点随长按语音代码被删、仅剩读点，已空转。保留字段位以对照历史。
    assoc_predicting = false,
}

-- ============================================================================
-- == is_mobile：移动端平台检测（5 份拷贝去重统一实现）==
-- ============================================================================
-- 原 super_sequence.lua / input_statistics.lua 的 is_mobile_device 与
-- Submit_text.lua / pair_punct.lua / smart_assoc.lua 的 is_mobile 判据不一致：
--   is_mobile_device 是 is_mobile 的严格超集（多了 distribution_code_name、
--   HOME 环境变量、iOS、/bundle/ 等检测）。统一采用超集实现，5 处调用点语义等价
--   （PC 返回 false、移动端返回 true），消除「近似拷贝」随版本漂移的风险。
-- 带 _mobile 缓存：首次调用检测一次，之后 O(1) 返回（与旧 is_mobile 的懒加载一致）。
-- 防御式访问 rime_api：core 会被多个不同加载时机的模块 require，须防方法未就绪。

local _mobile = nil

local function rime_user_dir()
    if rime_api and rime_api.get_user_data_dir then return rime_api.get_user_data_dir() or "" end
    return ""
end
local function rime_shared_dir()
    if rime_api and rime_api.get_shared_data_dir then return rime_api.get_shared_data_dir() or "" end
    return ""
end
local function rime_dist_code()
    if rime_api and rime_api.get_distribution_code_name then return rime_api.get_distribution_code_name() or "" end
    return ""
end
local function rime_dist_name()
    if rime_api and rime_api.get_distribution_name then return rime_api.get_distribution_name() or "" end
    return ""
end

function core.is_mobile()
    if _mobile ~= nil then return _mobile end
    _mobile = false

    local lower_dist = rime_dist_code():lower()
    local dist_name_lower = rime_dist_name():lower()
    local lower_path = rime_user_dir():lower()
    local sys_lower_path = rime_shared_dir():lower()
    local home = (os.getenv("HOME") or ""):lower()

    -- 1. 已知移动端输入法（distribution_code_name）
    if lower_dist == "trime" or lower_dist == "hamster" or lower_dist == "hamster3" then
        _mobile = true; return _mobile
    end

    -- 2. 超越输入法检测（RimeAPI + /space/ 路径）
    if dist_name_lower == "rimeapi" and
        (lower_path:find("/space/") or sys_lower_path:find("/space/")) then
        _mobile = true; return _mobile
    end

    -- 3. 通用移动路径关键词（Android/iOS/macOS）
    local mobile_keywords = {"/android/", "/mobile/", "/sdcard/", "/storage/emulated/",
                             "applications", "library"}
    for _, kw in ipairs(mobile_keywords) do
        if lower_path:find(kw) or sys_lower_path:find(kw) then
            _mobile = true; return _mobile
        end
    end

    -- 4. 鸿蒙系统路径特征（HarmonyOS / HarmonyOS NEXT）
    if lower_path:find("/harmony/") or lower_path:find("/hap/") or
        lower_path:find("/harmonyos/") or lower_path:find("/openharmony/") or
        sys_lower_path:find("/harmony/") or sys_lower_path:find("/hap/") then
        _mobile = true; return _mobile
    end
    if lower_path:find("/data/storage/el%d+") or sys_lower_path:find("/data/storage/el%d+") then
        _mobile = true; return _mobile
    end
    if lower_path:find("/bundle/") or sys_lower_path:find("/bundle/") then
        _mobile = true; return _mobile
    end
    if lower_path:find("/storage/users/") or sys_lower_path:find("/storage/users/") or
        home:find("/storage/users/") then
        _mobile = true; return _mobile
    end
    if dist_name_lower == "rimeapi" and
        (lower_path:find("/data/storage/el%d+") or lower_path:find("/space/") or
         home:find("/storage/users/")) then
        _mobile = true; return _mobile
    end

    -- 5. JIT 平台检测（Android/HarmonyOS）
    if jit and jit.os then
        local os_name = jit.os:lower()
        if os_name:find("android") or os_name:find("harmony") then
            _mobile = true; return _mobile
        end
    end

    -- 6. 环境变量检测
    if os.getenv("HMOS") or os.getenv("HARMONYOS") then
        _mobile = true; return _mobile
    end

    -- 7. iOS 路径检测
    if home:find("/var/mobile/") then
        _mobile = true; return _mobile
    end

    -- 8. HOME 目录回退检测（Android 兜底）
    if home:find("/storage/emulated/") then _mobile = true; return _mobile end
    if home:find("/data/data/") then _mobile = true; return _mobile end

    return _mobile
end

return core
