-- ============================================================
-- 帮助命令 /h（2026-09-29 新增；别名 /help）
--
-- 【用途】手机上打 /h，候选栏按分组列出全部功能命令，翻页可看完。
--   解决的实际问题：命令有 24 条，记不住；打错一个（比如 /bf）候选栏全空，
--   看着像输入法卡死，其实只是命令名不对 —— 有 /h 就能自己查到。
--
-- 【为什么按组给而不是一条命令一条候选】
--   24 条一条一候选要翻好几页，手机上很难扫。按组 8 条候选，一屏半看完，
--   命令名都平铺在候选文本里，眼睛扫一遍就够。
--
-- 【选中的内容会打出一串命令名 —— 是有意的吗】
--   是无奈但不影响：多数场景是「看一眼记住命令 → 清掉 → 再打命令」，
--   上屏什么并不重要。真要看命令效果，直接打命令即可。
--
-- 【挂载】4 份 schema.yaml 的 engine/translators 各加一行：
--     - lua_translator@*help_cmd
--   不需要额外 recognizer pattern：现有 punct: "^/([0-9]0?|[A-Za-z]+)$"
--   已能匹配 /h 与 /help（命令必须纯 ASCII，speller 不收汉字）。
--
-- 【与符号冲突吗】symbols.yaml 里 '/h' 是 h 的注音变体（ĥ ȟ ḣ …）。
--   不冲突：lua_translator 挂在 punct_translator 之前 ⇒ 帮助排在前、
--   注音符号排在后，翻页才看得到。想避免混淆就用别名 /help（未占用）。
--
-- ★ 新增 / 删除命令时，记得同步改下面的 GROUPS，否则帮助会漏。
-- ============================================================

-- { 候选文本, 候选注释 }
local GROUPS = {
    { "日期时间  /rq /sj /xq /dt",   "日期·时间·星期·日期时间" },
    { "农历节气  /jt /jq /gz /date", "日程·节气·干支·农历" },
    { "输入统计  /tj /qk /ks /js /tc", "统计·清空·开始·结束·退出" },
    { "智能联想  /lxql /lxgc /lxzt /lxdj", "清理·回收·状态·断句" },
    { "候选调序  /txql /txzq /txzj", "清除·自动清·自动检" },
    { "候选调序  /txdc /txdr /txtj", "调序·调频·统计" },
    { "符号面板  /tg /dz /xh /bd",  "天干·地支·星号·标点" },
    { "数字序号  /1 /2 /3 … /10",   "一/二/三…十（含大写）" },
}

local function translator(input, seg, env)
    if input ~= "/h" and input ~= "/help" then return end

    yield(Candidate("help", seg.start, seg._end,
                    "※ 命令速查：翻页看完，选中即上屏", "帮助"))

    for _, g in ipairs(GROUPS) do
        yield(Candidate("help", seg.start, seg._end, g[1], g[2]))
    end
end

return translator
