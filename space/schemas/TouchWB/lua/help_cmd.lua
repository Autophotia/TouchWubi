-- ============================================================
-- 帮助命令 /h（2026-09-29 新增；别名 /help）
--
-- 【用途】手机上打 /h：
--   第 1 候选 = 候选栏**仅显示标题**「※ 【TouchWB 命令总览】」，
--     点候选 / 按空格即上屏整份命令总览（纯候选式、不在 translator 里改状态）；
--   第 2 候选起 = GROUPS 依次各行（日期 / 农历 / 打字 …），翻页可速查单条。
--   ★ 顺序约定：GROUPS 首行必须是「日期」，不要在它前面再加任何行，
--     否则第 2 候选就会变成别的分组。
--   解决的实际问题：命令有 26 条，记不住；打错一个（比如 /bf）候选栏全空，
--   看着像输入法卡死，其实只是命令名不对 —— 有 /h 就能自己查到。
--   ★ 2026-11-05 晚：独立的 /hz 命令已取消，总览并入 /h 首候选。
--
-- 【为什么按组给而不是一条命令一条候选】
--   24 条一条一候选要翻好几页，手机上很难扫。按组 10 条候选，一屏半看完，
--   命令名都平铺在候选文本里，眼睛扫一遍就够。
--
-- 【选中的内容会打出一串「⦑命令⦒含义」 —— 是有意的吗】
--   是无奈但不影响：多数场景是「看一眼记住命令 → 清掉 → 再打命令」，
--   上屏什么并不重要。真要看命令效果，直接打命令即可。
--   例外：第 1 候选是特意用来「上屏整份总览」的（见下方机制说明）。

-- ★★ 【为什么候选栏只显示标题、上屏却是全文 · 2026-11-05 深夜】★★
--   Rime 里候选的「显示文本」与「上屏文本」同源，都取自 Candidate::text()
--   （librime Composition::GetCommitText() 直接拼 cand->text()；
--    ShadowCandidate / preedit 都改不了这一点）。
--   想让两者不同，只能在「用户已选中、但 C++ 尚未拼 commit text」的窗口里
--   把候选文本还原成整份总览：
--     A. 点候选栏 / 数字键（原生 Context::Select → Commit）：
--        本模块在 select_notifier 与 commit_notifier 上各挂一个 **group = -1
--        的前置回调**，命中 type/text 为短标题时把选中候选的 text 改回 OVERVIEW
--        （librime-lua 的 cand.text setter 对 Candidate(...) 的 SimpleCandidate 有效）。
--        ★ group = -1 是关键：默认 group 时 C++ Engine::OnCommit 先执行并已
--          sink 短标题，回调再改来不及（实测只上屏 16 字标题）；-1 抢在它之前。
--        两个回调幂等（改完 get_commit_text() 就不再是 SHORT），互为兼容兜底。
--     B. 空格（Submit_text 的 Lua 快捷上屏 engine:commit_text，不走 notifier）：
--        Submit_text 识别候选 type=="help_short" 后，直接提交
--        core.state.help_overview（本模块写入）。
--   真实 rime.dll 沙盒验证：空格 / 数字键 / 点候选三条路径，上屏均为 792 字
--   完整总览（末尾恰 1 个换行 ⇒ 光标落空行），之后打码无「上屏字母 z」等
--   残留；多 session 正常。/h 的每条分组行上屏也各自带 1 个尾部换行。
--   ★ 这不是 /hz 初版那种「translator 里 context:clear()」：回调只改候选
--     文本，不碰 composition、不触发 update_notifier ⇒ 不重入、不卡死。
--   ★★ 回调**绝不持有 engine / ctx 等 C++ userdata**（只捕获字符串常量）：
--     初版曾在 commit_notifier 闭包里捕获 engine 调 engine:commit_text(BODY)，
--     功能正常但 RimeDestroySession 时稳定 use-after-free 崩溃（会话销毁/切方案
--     会踩到）；改成前置改文本后清理阶段干净通过。
--   ★ 副作用边界：commit type 仍是候选自身的 "help_short"，上屏后 predictor
--     行为与旧版一致；输入统计的 ^[※◉] 过滤会跳过整份清单，造词累积也会跳过。
--   ★ 部署：本次涉及 help_cmd.lua + Submit_text.lua 两个文件，纯 lua 改动，
--     覆盖到 TouchWB/lua/ 后重启引擎即可，无需重编译 schema。
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
-- ★ 新增 / 删除命令或快捷键时，只需改下面这一份 GROUPS ——
--   /h 的分组候选与首候选总览共用它，不会再出现「两处不同步导致帮助漏项」。
-- ============================================================

-- 【格式约定】每行 = "分组  ⦑命令⦒含义 ⦑命令⦒含义 …"
--   每条命令用 `⦑ ⦒` 包裹（在长串里一眼能认出命令），含义紧跟在 `⦒` 后面；
--   不再用 `~` 连接，也不使用候选注释列（注释统一传空串）—— 手机候选栏常把
--   注释挤掉，含义写进候选文本才最可靠。
--   ★ 这同一份数据：/h 第 1 候选 = 整份总览，其后每行 yield 一条分组候选。
local GROUPS = {
    "日期  ⦑/rq⦒日期 ⦑/sj⦒时间 ⦑/xq⦒星期 ⦑/dt⦒日期时间",
    "农历  ⦑/jt⦒今天 ⦑/jq⦒节气 ⦑/gz⦒干支 ⦑/nl⦒农历",
    "打字  ⦑/tj⦒统计 ⦑/qk⦒清空 ⦑/ks⦒开始 ⦑/js⦒结束 ⦑/tc⦒退出",
    "造词  ⦑/zctj⦒统计 ⦑/zcscNN⦒序号删除 ⦑/zccx⦒撤销",
    "造词  ⦑/zcqk⦒清空 ⦑/zcql⦒清临时词 ⦑/zcdr⦒导入备份",
    "联想  ⦑/lxqk⦒清空 ⦑/lxzt⦒状态 ⦑/lxdj⦒断句 ⦑/lxql⦒清过期",
    "联想  ⦑/lxdc⦒导出 ⦑/lxdr⦒导入",
    "调序  ⦑/txqk⦒清空 ⦑/txzq⦒清自动调频 ⦑/txzj⦒自检",
    "调序  ⦑/txdc⦒导出 ⦑/txdr⦒导入 ⦑/txtj⦒统计",
    "符号  ⦑/tg⦒天干 ⦑/dz⦒地支 ⦑/xh⦒星号 ⦑/bd⦒标点",
    "序号  ⦑/1⦒一 ⦑/2⦒二 ⦑/3⦒三 … ⦑/10⦒十（含大写）",
    "PC调序  ⦑Ctrl+J⦒前移 ⦑Ctrl+K⦒后移 ⦑Ctrl+L⦒复位 ⦑Ctrl+P⦒置顶",
    "PC键组  ⦑Ctrl+Shift+F⦒简繁(4/$同效) ⦑Shift+空格⦒全半角 ⦑Ctrl+.⦒中英标点",
    "PC键组  ⦑Ctrl+Shift+H⦒字根 ⦑Ctrl+Shift+J⦒隐拼音 ⦑Ctrl+Shift+K⦒隐编码",
    "PC键组  ⦑Ctrl+Shift+E⦒表情 ⦑Ctrl+Shift+U⦒字符集 ⦑Ctrl+Shift+P⦒配对标点",
    "PC键组  ⦑Ctrl+0⦒方案切换：流萤五笔 / 流萤双混 / 拇指五笔 / 拇指双混",
    "PC键组  ⦑Ctrl+0⦒功能切换：超级提示 / 自动调频 / 方案联想 / 固定词库 / 自动造词 / 总联想",
    "技巧  ⦑=⦒计算器 ⦑`⦒长按Z造词",
    "技巧  ⦑z⦒拼音反查 ⦑@⦒邮箱后缀",
}

-- 整份命令总览（/h 的第 1 候选点选后上屏的内容）：由 GROUPS 直接拼接，
-- /h 翻页看到什么、上屏就是什么，天然同源。
-- ★ 2026-11-05 深夜改为**末尾带一个换行**（见下方「上屏末尾空行」）：
--   上屏后光标自动落到内容后的空行，与 /tj 统计报告一致。
--
-- ★★ 【上屏完整性 · 2026-11-05 真机实测】这不是本方案的代码 bug ★★
--   引擎层 commit 始终是完整的多行文本（真实 rime.dll 沙盒逐字校验）。
--   上屏后「显示多少、显示多快」取决于目标编辑器对长文本与换行的处理：
--     · notepad--   会截断：只到第 256 个字符（含 8 个 \n ⇒ 显示 248 字，
--                   停在「联想  /lxdc~导出 /」），且停顿约 1 秒后才瞬间显示；
--     · notepad++   内容完整，但渲染很慢，一条一条慢慢显示；
--     · EmEditor    内容完整，且瞬间显示完整内容。
--   ⇒ 在个别编辑器里「上屏不完整 / 显示慢」属该编辑器自身的文本处理限制，
--     换用无此限制的编辑器（如 EmEditor）即可，无需改动本方案代码。
--   可选优化（非必需）：若确需兼容有长度限制的编辑器，可把下面的
--     table.concat(GROUPS, "\n") 换成 table.concat(GROUPS, " ｜ ") 压成单行
--     ——845 字单行版实测在各编辑器均全量上屏、无截断，但可读性略差。
--
-- ★★ 【事故教训 · 2026-11-05】严禁在 translator 里 commit/clear ★★
--   初版曾在总览分支直接调 `context:clear()` + `engine:commit_text()`。
--   translator 运行在 composition **构建阶段**，清空上下文会触发 update_notifier →
--   引擎重新 compose → translator 再次命中帮助分支 → 再次 clear/commit ⇒ 无限重入，
--   真机表现：桌面卡死；且 input 状态被反复清空/残留 ⇒「直接上屏字母 z」、
--   「输 /h 卡一下再出 z」、「输 z 又上屏总览」。
--   **正确做法**：translator 只 yield 候选、零副作用；上屏交给 Rime 原生的「选中候选」
--   （点候选 / 按空格），所有帮助候选（含首候选总览）都走这条安全路径。
-- ★ 首行加 `※`：复用 input_statistics.report_commit_text 的 `^[※◉]` 过滤，
--   避免整份清单被计入输入统计（也不会进造词缓冲：含字母，coin_accumulate 会跳过）。
--   SHORT 单独留一份：候选栏只显示它；BODY 是标题之后的正文，拼成 OVERVIEW。
--
-- ★★ 【上屏末尾空行 · 2026-11-05 深夜】★★
--   统计报告（`format_*_summary` 以 "◉ 方案：%s\n" 收尾）上屏后光标会自动落到
--   内容后的空行，用户要求 /h 的**每条**命令候选也有这个效果。
--   实现关键：**候选栏文本一律不带换行**（GROUPS 仍是唯一数据源，保持不变；
--   否则候选栏会把 `\n` 渲染出空白、又变成挡预览的问题），只在「用户已选中、
--   提交时」追加：
--     · 首候选 help_short → 展开成 OVERVIEW（末尾带 TAIL = "\n"）；
--     · 分组行 help       → 由 hook_commit 前置回调把 cand.text 改成 line .. "\n"；
--     · 空格 / 分号 / 引号三条 Lua 快捷上屏路径 → Submit_text.submit_text_for() 统一处理。
--   ⇒ 总览与每条分组行上屏后都恰有一个尾部换行，光标落在空行；候选栏完全不受影响。
local SHORT = "※ 【TouchWB 命令总览】"
local TAIL = "\n"
local BODY = "\n" .. table.concat(GROUPS, "\n")
local OVERVIEW = SHORT .. BODY .. TAIL

-- 跨组件共享：Submit_text 的空格快捷上屏路径需要整份总览（core.state 纯内存表）
local core = require "core"
core.state.help_overview = OVERVIEW

-- 点候选 / 数字键：在 C++ 拼 commit text 之前，把选中候选的 text 还原成总览，
-- 或给 /h 分组行补一个尾部换行（上屏后光标落到空行）。
-- ★ group = -1（前置）是硬要求：默认 group 时 C++ Engine::OnCommit 已先
--   sink 短标题，回调再改无效（实测只上屏 16 字）。两个 notifier 都挂，
--   任一生效即可；按 **cand.text 自身状态** 判幂等（不依赖 get_commit_text()，
--   避免多段拼接时误判），改完再触发的回调会直接跳过。
-- ★ 回调闭包只捕获 SHORT / OVERVIEW / TAIL 字符串，**不持有 engine / ctx userdata**
--   （否则 RimeDestroySession 时 use-after-free 崩溃，见上方事故说明）。
-- ★ context 级一次性闩锁：RimeSelectSchema / ApplySchema 会重建 translator
--   组件（新 env），但 Context 对象不变，旧连接仍在；只用 env 标记会连两次。
--   property 不带 `_` 前缀 ⇒ ClearTransientOptions 不会清掉，切方案后仍在。
local function hook_commit(env)
    local ctx = env.engine.context
    if not ctx or ctx:get_property("help_commit_hooked") == "1" then return end
    ctx:set_property("help_commit_hooked", "1")
    local function expand(c)
        pcall(function()
            local cand = c:get_selected_candidate()
            if not cand then return end
            local text = cand.text or ""
            if cand.type == "help_short" and text == SHORT then
                cand.text = OVERVIEW                    -- 整份总览（末尾带 TAIL）
            elseif cand.type == "help" and text ~= "" and text:sub(-1) ~= "\n" then
                cand.text = text .. TAIL                -- 每条分组行也留一个空行
            end
        end)
    end
    pcall(function()
        ctx.select_notifier:connect(expand, -1)
        ctx.commit_notifier:connect(expand, -1)
    end)
end

local function translator(input, seg, env)
    if input ~= "/h" and input ~= "/help" then return end
    hook_commit(env)

    -- 第 1 候选：候选栏仅显示标题；上屏前由 hook_commit（点候选/数字键）
    -- 还原成 OVERVIEW，空格则由 Submit_text 直接提交整份总览。
    -- type 用 "help_short" 作标记；此处绝不 commit_text / context:clear。
    yield(Candidate("help_short", seg.start, seg._end, SHORT, ""))

    -- 其后是分组速查；含义已用 `⦑命令⦒含义` 写在候选文本里，注释列留空
    for _, line in ipairs(GROUPS) do
        yield(Candidate("help", seg.start, seg._end, line, ""))
    end
end

return translator
