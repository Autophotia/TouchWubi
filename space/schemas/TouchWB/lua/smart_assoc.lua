-- ============================================================
-- 【来源与署名】★ 2026-09-30 补署
--   创意来源：万象拼音（万象家族 lua）
--     上游：https://github.com/amzxyz/rime_wanxiang
--   修改：Autophotia（超越输入法 · TouchWB 双键五笔方案）
--         https://github.com/Autophotia/TouchWubi
--
--   溯源：主体为满足「超越输入法」需求而重写；以下两处创意移植自
--         万象 lua/wanxiang/user_predict.lua：
--           ① 往输入码塞占位符「›」凭空造段（详见下方「自建联想段的做法」）
--           ② J-2 衰减淘汰机制（万象 0.85，本方案放宽到 0.90）
--
--   ★ 上述创意归属万象，其余实现归本方案；
--     发现缺陷请联系修改者，不要反馈给上游。
-- ============================================================
-- smart_assoc.lua —— 基于用户历史记忆的逐级智能联想
--
-- 需求来源：space/输入法Lua智能联想需求文档.md（v1.1）
--
-- 做什么：
--   记住用户「上屏过的词和顺序」，下次打到同一段话的开头时，把历史上接着打的内容
--   作为联想候选**放在第一候选**；固定词库（随方案发布的 assoc_fixed.txt）的候选
--   照旧展示，但排在历史候选之后。点掉一个联想候选后继续联想下一段（逐级联想）。
--
-- 为什么不走 librime 自带的 predictor / 语言模型（结论，别再尝试）：
--   · predictor：本方案的 predict.db 里没有可用的中文词条，且联想段一个会话只出现一次；
--   · 语言模型（gram）：服务的是打字**过程中**的组词预测，不是上屏之后的联想，
--     而且是打分器不是词表 —— 没有候选池时仍然是 0 条。
--   ⇒ 本模块自建联想段。固定词库 assoc_fixed.txt 只解决「还没有历史时给什么候选」；
--     想改成纯靠养，把 FIXED_MAX 设 0 即可。
--
-- 自建联想段的做法（思路来自同目录方案 万象五笔5.4/lua/wanxiang/user_predict.lua）：
--   librime-lua 无法凭空造段（Segmentation 没有 add 方法，实测为 nil），
--   但可以**往输入码里塞占位符**造出一个真实存在的段：
--     ① 上屏后：ctx:push_input("›")（连续联想第 N 级就塞 N 个 "›"）
--     ② 翻译器：input 匹配 "^[›]+$" 时吐联想候选
--     ③ 用户一打正常字母：input 变成 "›z" ⇒ 清掉占位符，把 "z" 还回去
--   代价：编码栏会显示这个占位符"›"（万象系方案同样如此，属可接受代价）。
--   前提：speller 的 alphabet / initials 必须包含 "›"，否则造不出段（见各 schema）。
--
-- 组件：
--   P（processor）学习上屏 + 维护联想链 + 推占位符
--   T（translator）在 "›" 段上吐候选
--   F（filter）只处理 /lxqk /lxql /lxdj /lxzt /lxdc /lxdr 六个命令，其余原样放过
--
-- 挂载位置（硬约束，别随便挪）：
--   P（processor） → 必须放在 `lua_processor@*Submit_text` **之前**。
--       本方案的 Submit_text.lua 会用 engine:commit_text() 处理空格 / 分号 / 单引号
--       上屏并 return 1；放在它后面就永远看不到空格键。而"上屏了什么"必须在按键
--       处理**之前**抓（见下条），看不到空格 ⇒ 联想永远慢一拍。
--   T（translator）→ translators **最前面**（占位符段只有它出候选）
--   F（filter）    → 放在 `lua_filter@*super_sequence*F` 之后
--       （super_sequence*S 会按 quality 稳定重排，命令回显不能被它挤掉）
--
-- ★ 怎么知道"上屏了什么"（本模块最绕的一处）
--   commit_history 在这套方案上**滞后一个按键**（要等下一个 ProcessKey 才刷新），
--   commit_notifier 则不触发 ⇒ 用两条路径互相兜底：
--     路径 A  commit_history 的 size / back 变了 ⇒ back 就是刚上屏的文本（最可靠）
--     路径 B  按键处理**之前**先用 ctx:get_commit_text() 记下"按下就会上屏什么"；
--             等输入码真的空了就认定是它 ⇒ 立刻结算、立刻推占位符（不慢一拍）
--   两条路径用 _just_learned 去重，同一条上屏只学一次。
--
-- 命令（沿用「功能拼音首字母」约定，联想 = lx）：
--   /lxqk  联想清空   清空用户历史联想记录（整个库重来）
--   /lxql  联想清理   只删过期条目（EXPIRY_DAYS 天没再用过），保留还记得的
--   /lxdj  联想断句   手动断句（详见上文判据说明）
--   /lxzt  联想状态   自检：开关 / 上下文 / 命中码 / 已学条数
--   /lxdc  联想导出   导出历史联想记录至 assoc_<schema_id>.txt（已有更优备份时拒绝覆盖）
--   /lxdr  联想导入   从 txt 合并进当前库（count/时间戳取大，幂等）
--
-- ★ 衰减淘汰（2026-09-29 J-2）：排序不再纯看次数，而是
--     score = 次数 × DECAY_RATE ^ 距今天数
--   即「很久没用的熟词」会被「最近常用的词」顶下去，不用手动清库。
--   参数在下面「可调参数」区的 DECAY_RATE / EXPIRY_DAYS。
--
-- 开关：schema 的 switches 里加 `- name: smart_assoc`。
--   没声明开关时默认开启；声明后可用它关闭学习与联想。
--
-- ⚠ 与输入法「联想补丁」（grammar / predictor 补丁）互斥：两者都会抢「输入码为空」
--   这一刻，同时开会互相打架。用本模块请把那个补丁关掉（二选一）。
-- ===================================================================


local ASSOC_PREFIX = "\003as|"  -- 记录键前缀（\003 开头 ⇒ 与调序库互不干扰）
local SEP = "\001"              -- 键内 / 值内分隔符（汉字不会出现）

-- -------------------------------------------------------------------
-- 可调参数（改这里就能改手感，注释里写清每个值为什么是这个数）
-- -------------------------------------------------------------------
local MAX_KEY_LEN = 4            -- 索引 / 查询的 key 最长几个字
local MAX_CONTEXT_LEN = 12       -- 一句话在内存里保留的字数上限
local CANDIDATE_MAX_LEN = 4      -- 单个联想候选最长几个字
local GRANULARITY_MAX = 3        -- 一条后续最多展开几层（有 → 有点 → 有点冷）
local MAX_HISTORY = 3            -- 历史候选最多几条（需求文档示例 3：好 / 几点 / 好像）
local MAX_CANDIDATES = 9         -- 联想区总条数上限（= default.yaml 的 menu/page_size）
local MAX_PREDICTIONS = 4        -- 连续点联想最多几级（防无限联想）
local MAX_SENTENCE_TOKENS = 5    -- 一句话最多算几个词（超过就断句，见判据四）
local MERGE_STRICT = true        -- 多级拼接的候选要过一遍"像不像话"检查（见 build_candidates）
local MAX_CONT_PER_KEY = 20      -- 同一个 key 下最多保留几条不同后续
local MAX_CONT_TOKENS = 4        -- 一条后续最多由几个 token 拼成
local IDLE_BREAK_SEC = 300       -- 距上次上屏超过这么久 ⇒ 视为新的一句话
local LEARN_MAX_CHARS = 8        -- 单个上屏块超过这么长就不学
local FIXED_MAX = 6              -- 固定候选最多补几条
local FIXED_FILE = "lua/assoc_fixed.txt"

-- ===================================================================
-- ★ S101b-2：联想候选的「常用字白名单」—— 挡掉历史里养出来的生僻字
-- ===================================================================
-- 【真机问题】26 键打「测试」，方案联想给出「浿」「浿沁」。
--   已排除两条来源，所以只剩第三种：
--     · assoc_fixed.txt 里「浿」**0 命中**（既不是 key 也不是 value）⇒ 不是固定词库
--     · 切「应用联想」（只用官方 predictor）后联想是固定的「仪」  ⇒ 不是 predict.db
--   ⇒ 是**用户自己的历史库**。历史是「养」出来的：打过 `imy`（浿 的编码，
--     恰好是 `imya`=测试 的前缀）就会学进去，之后一打「测试」就把「浿」吐出来。
--
-- 【为什么只能在输出时拦】历史库（assoc_*.userdb）里只有「词 + 次数 + 时间」，
--   **没有词频权重**，写入那一刻无从判断这个字常不常用。
--   ⇒ 只能外挂一份字频表，在候选出栏前逐字过一遍。
--
-- 【阈值 5000 是实测选的，不是拍脑袋】
--   数据源 wb_spelling.dict.yaml（sort: original，正文按字频降序），
--   与 new_spelling.lua 的 COMMON_CHARS_3500 **同源同序**：
--     听 475 / 试 609 / 测 776 / 仪 1245 / 沁 3173          ← 必须放行
--     蔷 3505 / 蔼 3565 / 菇 3631 / 闰 3633 / 蘑 3787
--     藕 3821 / 韭 3822 / 呗 4163                          ← 次常用，必须放行
--     浿 11853                                              ← 必须拦掉
--   ⚠ **不能用 3500**：那正是 new_spelling.lua 把 COMMON_CHARS_STRICT 改回
--     false 的原因 —— 手机上没有切换入口，等于永久锁死在「常用」，
--     会把 呗/菇/藕/蘑/闰 一批日常字全挡在门外（已实测）。
--     5000 档这些字全部放行，而「浿」离它有 2.4 倍余量。
--
-- 【判据】多字候选**逐字**判定：任一汉字不在表内 ⇒ 整条丢弃。
--   非汉字（标点 / 数字 / 字母 / 隔音符号）沿用 new_spelling 的口径**放行**，
--   本表只管汉字生僻度，不替用户决定标点该不该出现。
--
-- 【失败策略：fail-open】表读不到（比如没打进包）⇒ **不过滤**，
--   宁可放过生僻字，也不能让联想整个空掉。加载结果可在 /lxzt 里看。
-- ===================================================================
local COMMON_FILE = "lua/assoc_common.txt"
local ASSOC_COMMON_ONLY = true   -- 关掉 = 退回 S101b 之前的行为（不拦生僻字）
local _common = nil              -- set[汉字] = true
local _common_tried = false
local _common_n = 0

-- ★★ 2026-09-29 J-2 衰减淘汰（移植自万象 user_predict.lua 的
--     score = count × DECAY_RATE ^ age_days，改了 rate 以适配联想库的语义）
--   老行为：排序纯看 count，时间戳只当同分 tiebreak ⇒ 三年前打过 100 次的词
--     永远压在今天打了 10 次的词前面，且只有 /lxqk 全清一条出路。
--   现在：score = count × DECAY_RATE ^ (距今天数)。
--     rate 0.90 ⇒ 一个打过 100 次的老词，约 22 天后与「打了 10 次的新词」同分；
--     万象给词组预测用的是 0.85（≈14 天），联想库更即时，这里放宽到 0.90。
--     想更快淘汰就调小（0.85 / 0.80），想更恋旧就调大（0.95）。
--   EXPIRY_DAYS：超过这么久没再被用过 ⇒ 视为过期，/lxql 时清理（也可在写入
--     同一 key 时顺手清，见 record）。
local DECAY_RATE  = 0.90         -- 每过 1 天，记忆权重乘以它（1.0 = 关掉衰减）
local EXPIRY_DAYS = 180          -- 过期天数（半年没再出现 ⇒ 回收）

-- -------------------------------------------------------------------
-- 字符工具（★ 本文件所有下标都是**字符**下标，不是字节 —— 汉字 3 字节，混用会错位）
-- -------------------------------------------------------------------
local function ulen(s)
    if not s then return 0 end
    local ok, n = pcall(utf8.len, s)
    if ok and type(n) == "number" then return n end
    return 0
end

local function to_chars(s)
    local out = {}
    if not s then return out end
    local b, n = 1, #s
    while b <= n do
        local c = s:byte(b)
        local w = 1
        if c >= 0xF0 then w = 4 elseif c >= 0xE0 then w = 3 elseif c >= 0xC0 then w = 2 end
        out[#out + 1] = s:sub(b, b + w - 1)
        b = b + w
    end
    return out
end

local function uhead(s, n)
    if not s or ulen(s) <= n then return s end
    local ok, b = pcall(utf8.offset, s, n + 1)
    if ok and b and b > 1 then return s:sub(1, b - 1) end
    local cs = to_chars(s)
    return table.concat(cs, "", 1, n)
end

local function utail(s, n)
    local L = ulen(s)
    if not s or L <= n then return s end
    local ok, b = pcall(utf8.offset, s, L - n + 1)
    if ok and b then return s:sub(b) end
    local cs = to_chars(s)
    return table.concat(cs, "", L - n + 1, L)
end

local function ufrom(s, k)
    if not s or k <= 1 then return s end
    local ok, b = pcall(utf8.offset, s, k)
    if ok and b then return s:sub(b) end
    local cs = to_chars(s)
    return table.concat(cs, "", k, #cs)
end

local function has_cjk(s)
    return s and s:find("[\228-\233][\128-\191][\128-\191]") ~= nil
end

-- 命令回显（super_sequence 的 /tx* 会吐「※ …」并被上屏，不能当词学）
local function is_command_echo(s)
    return s and (s:sub(1, 3) == "※" or s:sub(1, 1) == "/")
end

-- -------------------------------------------------------------------
-- 数据库
-- -------------------------------------------------------------------
local _dbs = {}

local function db_name(schema_id)
    return "lua/assoc_" .. tostring(schema_id)
end

local function get_db(schema_id)
    if not schema_id then return nil end
    local db = _dbs[schema_id]
    if db and db:loaded() then return db end
    db = LevelDb(db_name(schema_id))
    if not db then return nil end
    local ok = pcall(function() db:open() end)
    if not ok or not db:loaded() then return nil end
    _dbs[schema_id] = db
    return db
end

local function db_close(schema_id)
    local db = _dbs[schema_id]
    if db and db:loaded() then pcall(function() db:close() end) end
    _dbs[schema_id] = nil
end

-- -------------------------------------------------------------------
-- 运行时状态
-- -------------------------------------------------------------------
local _st = {}
local _stat = { learns = 0, writes = 0, queries = 0, hits = 0, err = nil,
                last_ctx = nil, last_key = nil, last_cands = nil }

local _sid = nil                -- 当前方案 id
local _prev_input = nil         -- 上一次 tick 时的输入码（判断「输入码被清空」）
local _hooked = false
-- ★ S82：记录「已连接」的会话身份。切方案 / App 重连会新建 context，
--   update_notifier 是新连接，必须重新 connect —— 用它来判断是不是同一会话。
local _hooked_key = nil

-- 「按下这个键就会上屏什么」——按键处理前先记下来（见 settle_if_new 路径 B）
local _pend_input = nil
local _pend_text = nil
local _pend_from_predict = false
local _just_learned = nil       -- 路径 B 已经学过的文本（防止路径 A 重复学）
-- ★ 我们自己清掉联想（Esc / 回车 / 退格 / 移动端数字键 / 标点）时，输入码会从
--   "›" 变成空 ⇒ 正好命中路径 B 的判据「输入码从非空变空」，被误判成一次上屏，
--   于是又学一遍、又推一次联想（表现：回车清不掉、按几次才换行）。
--   清空前把这个标志置上，settle_if_new 会跳过这一次。
local _suppress_settle = false

-- ★★★★★ S96 曾在此引入 `_assoc_user_cleared`（用户主动收联想的持久标记），
--   语义：clear_assoc 之后、下一次真上屏结算之前，挡住 EAGER/REGAIN 当场补算。
--   它是 S95 B4 退格拦截的配套（B4 吞退格 → clear_assoc → 不许补回候选）。
-- ★ S97 已随 B4 一并撤除（用户指示：恢复 S94/S93 退格行为）。
--   B4 不存在后，没有路径需要「清联想后不补算」这个语义，
--   留着只会偏离 S94 的既有行为。
--   完整教训（含 S96 真机日志证据）保留在 P.func 空段放行口的注释里。

-- 联想链
local pending_cands = nil       -- 本次联想待展示的候选（历史 + 固定）
local pending_hist = nil        -- 其中属于「历史」的部分（判断是不是点了联想）
local _last_offered = nil       -- 上一次实际展示出去的候选（判断用户是不是点了联想）
local predict_count = 0         -- 当前是连续联想的第几级
local _chained = false          -- 本次「句子」里用户有没有点过联想候选

-- ★★★ S65：联想「时机」标记，与 pending_cands **彻底分离**
--   起因（S64 真机探针实测）：S63 让 T.func 用 `pending_cands ~= nil` 判空段，
--   现象是「联想偶尔出现」——因为两者存活窗口对不上：
--     窗口1 数据：settle_commit 置位 → 下个按键就可能被 reset_chain 清掉
--     窗口2 空段：predictor 要在**稍后某一次** context 更新里才建段
--   短窗口的判据查长窗口的事件 ⇒ 命中与否看运气。
--   探针铁证：
--     [22:19:06] T.func in="" pending=true  mode=ph   ← 数据在
--     [22:19:07] T.func in="" pending=false mode=pred ← 数据没了，段没建出来
--   ⇒ 本标记在 settle_commit 置位，**只**在真正该清联想时清除
--     （clear_assoc / 开关关闭 / 断句 / reset_chain），
--     存活窗口足够长，覆盖 predictor 建段时机。
local _assoc_ready = false

-- ★★★★★ S90：恢复「当前是联想段」的跨文件标志（语义已收窄，与长按语音无关）
-- ------------------------------------------------------------------------
-- 【为什么 S88 删掉之后必须补回来】
--   S88 撤掉了 S79~S87 的长按语音代码，连带删了ASSOC_FLAG / mark_predicting。
--   那一轮**删得对**：那个标志是为「把空格让给长按」设计的，
--   而长按时空格根本不进引擎（19:41:10 实测 Lua 侧零事件），
--   旧标志只剩「短按时扣住空格」这一种有害行为。
--   ★ 但它同时承担着**另一个毫不相关的职责**，S88 一并带走了：
--       pair_punct.lua:405     联想段上按标点，只上屏标点，不带联想词
--       super_sequence.lua:1038 联想段上不做手动调序
--   原注释自己就写着这个标志是「四方共享：
--   smart_assoc / Submit_text / pair_punct / super_sequence」——
--   S88 只处理了 Submit_text，漏了另外两个。
--   ⇒ 后果（用户实测回归）：上屏后候选栏还有联想候选时，
--      点标点 / 上滑 / 下滑都会把第一候选一起顶上去屏。
--      「句号」打成「女。」就是这样来的。
--
-- 【这一版与 S88 那个标志的区别：语义收窄】
--   · 名字改成 ASSOC_SEG_FLAG，含义只有一个：**当前处于联想段**。
--     不再有任何「让路给长按」的语义，也不参与任何空格判断。
--   · 写入点只有一处：clear_assoc 之外的所有路径都不清它，
--     只在 clear_assoc（用户主动收联想）与关闭开关时清。
--     判据直接用 `_assoc_ready` —— 文件里 952 行已经论证过
--     它「存活窗口足够长、覆盖 predictor 建段时机」，
--     是本项目唯一被反复验证过的可靠时机标记。
--   · 写 _G 不用 ctx:set_property：pair_punct / super_sequence 里
--     `get_property("assoc_predicting")` 这条通道在部分 librime-lua
--     版本上取不到，留着只会让人误以为有第二条通道。
--     本轮实测（tools/sandbox_s90_punct.py ❷a/❷b）确认：写点与读点已全部空转。
local ASSOC_SEG_FLAG = "__touchwb_assoc_seg"

-- ★ S90 探针用：本轮进 P.func 时是否处于联想段（模块级，供函数尾部读取）
local _was_assoc_seg = false

--- 置位/清除「当前处于联想段」（供 pair_punct / super_sequence 判据用）
local function mark_assoc_seg(on)
    rawset(_G, ASSOC_SEG_FLAG, on and true or nil)
end

-- ★★★★★ S84：上一句的上下文快照（空段轮次的唯一可用数据源）
-- ------------------------------------------------------------------------
-- 【前五轮全部失败的共同根因，本轮终于定量定案】
--   空段轮次里 **state(sid).toks 恒为空**：
--       真机 `空段待补算 toks=0 命中=false` 出现 190 次，命中=true 0 次
--       沙箱 `T.func S83空段 toks=0 命中=false` 出现  37 次，命中=true 0 次
--   原因不是时序 unlucky，而是**架构性的**：
--       ① predictor 在上屏那一刻就建好空段（`P 空段放行 kc=32 in=`）
--       ② 唯一写 toks 的 settle_commit 跑在 update 回调里，**必然晚于**①
--   ⇒ 空段那一轮 toks 还没被写过，`context_of(sid)` 返回 nil，
--     于是 query()/fixed_candidates() 都无从下手 —— 前五轮（含 S83 现行判据）
--     「空段时只看有没有历史」这个问题，**问的就是这个恒为空的字段**。
--
-- 【S84 的判据】不查 state，查**我们自己维护的跨轮快照**：
--   settle_commit 每次上屏成功后，把当时的 context_of(sid) 抄进 _last_ctx。
--   空段那一轮 toks 为空 → 退回用 _last_ctx 建候选。
--   ⇒ 这样空段与结算之间**不再有任何时序依赖**：
--     要么本句已结算过（_last_ctx 有值，直接用），
--     要么还没结算过（_last_ctx 为 nil，老实不吐词——用户确实还没打过词）。
--
-- 【为什么不用 commit_history（已实测排除）】
--   `ctx.commit_history:back().text` 听起来是更权威的账本，但沙箱实测
--   37 次空段轮次里 `size=0 back=nil` —— 全部发生在**任何上屏之前**。
--   它和 toks 一样受制于「空段建立早于结算」这条时序，不能单独当判据。
--
-- 生命周期：settle_commit 写；break_sentence / clear_assoc / /lxqk 清空。
local _last_ctx = nil

-- 固定词库（懒加载）
local _fixed = nil
local _fixed_tried = false

-- 调试日志开关：置 true 时把关键流程写进日志（排查完置回 false）
-- ★ 两条输出通道，原因：
--     ① log.info(tag, msg) —— 真机（鸿蒙超越）**只有第一个参数 tag 会进日志**
--        （实测：Submit_text.lua 的 log.info("Submit_text","input_text=..") 在
--        全部拼进**第一个参数**，第二个参数会被丢掉。
--     ② 写文件 —— 只在 PC（小狼毫）上有效，手机上没有可写路径，两个都留着。
local DEBUG_LOG = false     -- ★ 2026-09-27 真机三大问题全部验证通过，关闭调试日志
local LOG_PATH = "C:/Users/xoaii/AppData/Local/Temp/assoc_dbg.txt"
local function dbg(fmt, ...)
    if not DEBUG_LOG then return end
    local msg = fmt
    if select("#", ...) > 0 then
        local ok, s = pcall(string.format, fmt, ...)
        if ok and s then msg = s end
    end
    msg = "[assoc] " .. msg
    pcall(function() if log and log.info then log.info(msg) end end)
    -- 通道②：PC 文件
    pcall(function()
        local f = io.open(LOG_PATH, "a")
        if f then f:write(msg .. "\n"); f:close() end
    end)
end

-- ============================================================
-- ★★ 临时取证通道（2026-10-02）：真机 log.info **已经不产出日志**了
--     （log/keyboard/ 空目录、log/app 停在 10-01），而排查空格长按
--     必须知道「前端一次按键到底派发了几个事件、松开事件长什么样」。
--     ⇒ 自己写文件取证，不依赖 App 的日志系统。
-- ============================================================
-- 路径取法照抄 new_spelling.lua / schedule.lua（那两处是真机上验证过的写法）：
--     rime_api.get_user_data_dir() 优先，否则拿 schema_dir 砍掉最后一段。
--   写出来的文件落在 space 目录里 ⇒ 同步到 PC 就能看到。
--
-- ★ S66 基线版：默认**关闭**。基线版是给日常使用的，不该每次按键都写文件。
--   需要排查问题时改成 true 再打包；查完记得改回来。
--   打开后会在 schemas/TouchWB/log/assoc_probe.log 里留下记录，
-- ★ S100：**真的关了**。S80~S99 一直是 true（那时候每版都要盯着
--   T.func 有没有出候选），代价是 assoc_probe.log 长到 77 MB（S98 清理过一轮）。
--   S100 是用户明确要的**基线版本** ⇒ 按上面那条 S66 规矩恢复默认值 false。
--   要排查时把下一行改回 true、重新打包即可（注释别删，免得下次忘了为什么）。
-- ★ S80 历史：那一版要验证「候选挂在 predictor 空段上」，光看候选栏分不清是我们的词还是
--   官方预测（S64 曾因此被"随机联想"骗了一轮）⇒ 必须有 T.func 级日志，故当时 PROBE_ON=true。
local PROBE_ON = false   -- ★ S116 取证已结束，关回基线（S100 规矩：基线版默认 false）
local _probe_path = nil
local _probe_tried = false

local function probe(msg)
    if not PROBE_ON or not _probe_path then return end
    pcall(function()
        local f = io.open(_probe_path, "a")
        if f then
            -- ★ 必须带时间戳：不带的话无法与 App 的 keyboard 日志对齐，
            --   也就分不清「哪两个事件是同一次按键」(2026-10-02 复盘时才发现)
            local ts = "?"
            pcall(function() ts = os.date("%H:%M:%S") end)
            f:write("[" .. ts .. "] " .. tostring(msg) .. "\n")
            f:close()
        end
    end)
end

-- 把一个按键事件能问出来的信息全问一遍（哪一项报错就记 ERR）
--   ⇒ 一眼看出这台机器的 KeyEvent 到底暴露了什么、release 位在哪。
local function kdump(ke)
    local t = {}
    local function g(n, fn)
        local ok, v = pcall(fn)
        t[#t + 1] = n .. "=" .. (ok and tostring(v) or "ERR")
    end
    g("kc", function() return ke.keycode end)
    g("mod", function() return ke.modifier end)
    g("repr", function() return ke:repr() end)
    g("rel", function() return ke:release() end)
    g("shift", function() return ke:shift() end)
    g("ctrl", function() return ke:ctrl() end)
    g("alt", function() return ke:alt() end)
    return table.concat(t, " ")
end

-- 在 P.init 里调一次：挑一个真能写的路径（都写不了就退化，不影响正常输入）
local function probe_init(env)
    if _probe_tried or not PROBE_ON then return end
    _probe_tried = true
    local base = ""
    pcall(function()
        if rime_api and rime_api.get_user_data_dir then
            base = rime_api.get_user_data_dir() or ""
        end
    end)
    if base == "" then
        pcall(function()
            local sd = env and env.engine and env.engine.schema
                       and env.engine.schema.schema_dir or ""
            base = sd:match("^(.+[/\\])") or ""
        end)
    end
    if base ~= "" and not base:match("[/\\]$") then base = base .. "/" end
    for _, p in ipairs({ base .. "log/assoc_probe.log", base .. "assoc_probe.log",
                         "log/assoc_probe.log", "assoc_probe.log" }) do
        local ok, f = pcall(io.open, p, "a")
        if ok and f then
            pcall(function() f:close() end)
            _probe_path = p
            break
        end
    end
    probe("==== probe start ====")
    probe("base=" .. tostring(base) .. " path=" .. tostring(_probe_path))
end

local function state(sid)
    local s = _st[sid]
    if not s then
        s = { toks = {}, chars = {}, size = nil, back = nil,
              last_time = 0, seen = {} }
        _st[sid] = s
    end
    return s
end

local function reset_sentence(s)
    s.toks, s.chars, s.seen = {}, {}, {}
end

local function reset_chain()
    predict_count = 0
    pending_cands = nil
    pending_hist = nil
    -- ★ S65：**故意不清 _assoc_ready**。
    --   「数据没了」不等于「这一轮不联想了」——predictor 建段可能还没发生。
    --   真正该清的是 clear_assoc（用户主动收联想）和开关关闭，见那两处。
end

-- 「一句话结束」：上下文和联想链一起清掉。
-- ★ _chained 必须在这里清：它标记的是"当前这句里点过联想"，句子没了标记自然跟着没。
--   但 reset_chain() **不**清它 —— 用户按 Esc 或开始打字只是放弃了本次联想，
--   句子还没结束，要等他真正上屏一个新词时再判断（见 settle_commit 的断句判据一）。
local function break_sentence(s)
    reset_sentence(s)
    reset_chain()
    _chained = false
    -- ★★ S84：断句 = 上下文作废。
    --   空段那一轮读不到 state.toks（恒为 0，真机 190/190 沙箱 37/37），
    --   _last_ctx 是那时唯一的上下文来源。句子断了还留着旧快照，
    --   会让新句子的空段拿到上一句的尾巴 ⇒ 联想出「跨句噪声词」
    --   （冷→今天 / 冷→早晨 那类，见 settle_commit 里的断句判据说明）。
    _last_ctx = nil
end

-- ===================================================================
-- 一、学习
-- ===================================================================

-- 取「字符下标 e 之后」的后续文本。
--   · e 落在某个 token 中间 ⇒ 先取该 token 的剩余部分（需求文档 5.5.1）
--   · 再往后接完整的 token，累计不超过 CANDIDATE_MAX_LEN 个字（需求文档 5.5.2）
-- ★ 只接**完整** token（超长就停），这样 key+cont 永远落在真实的上屏边界上，
--     下一层展开（query 里的 lookup_best）才能查得到。
local function cont_after(toks, e)
    local out, total = {}, 0
    local pos = 1
    for _, t in ipairs(toks) do
        local n = ulen(t)
        local ts, te = pos, pos + n - 1
        if te > e then
            local from = e + 1
            if from < ts then from = ts end
            local piece = ufrom(t, from - ts + 1)
            local pn = ulen(piece)
            if #out == 0 then
                out[1] = uhead(piece, CANDIDATE_MAX_LEN)
                break
            end
            if total + pn > CANDIDATE_MAX_LEN then break end
            out[#out + 1] = piece
            total = total + pn
            if #out >= MAX_CONT_TOKENS then break end
        end
        pos = te + 1
    end
    if #out == 0 then return nil end
    return table.concat(out)
end

-- 衰减打分：count × DECAY_RATE ^ 距今天数（★ J-2 核心，只有这一个函数）
-- now 由调用方传进来 ⇒ 一次查询只取一次 os.time()。
local function decay_score(c, t, now)
    local age = (now - (t or 0)) / 86400
    if age < 0 then age = 0 end          -- 时钟回拨 / 脏数据兜底
    if DECAY_RATE >= 1 then return c or 0 end
    return (c or 0) * (DECAY_RATE ^ age)
end

local function is_expired(t, now)
    return (now - (t or 0)) / 86400 > EXPIRY_DAYS
end

-- 写一条「key → 后续」记录。值 = 次数 \001 最近使用时间
local function record(sid, key, cont)
    local db = get_db(sid)
    if not db then return end
    local k = ASSOC_PREFIX .. key .. SEP .. cont
    local now = os.time()
    local count = 1
    local old = db:fetch(k)
    if old then
        local c = tonumber(tostring(old):match("^(%d+)"))
        if c then count = c + 1 end
    end
    db:update(k, count .. SEP .. now)
    _stat.writes = _stat.writes + 1

    -- ★ 2026-09-29 S14：只在**新建**条目时才需要扫描裁剪。
    --   old 存在 ⇒ 这条记录本来就在库里，本 key 下的条目数一个都没多 ⇒ 不可能突破
    --   MAX_CONT_PER_KEY ⇒ 完全不用扫。
    --   老写法每次写库都全前缀扫一遍（把该 key 下最多 20 条全读出来建表、排序、删多余的），
    --   每次上屏要写 #token × MAX_KEY_LEN ≈ 8 条 ⇒ 8 次全前缀扫描 / 上屏。
    --   库「养熟」之后绝大多数写都是更新已有条目 ⇒ 扫描次数趋近 0。
    if old then return end

    local acc = db:query(ASSOC_PREFIX .. key .. SEP)
    if acc then
        local items, dead = {}, {}
        local now = os.time()
        for kk, vv in acc:iter() do
            local c, t = tostring(vv):match("^(%d+)" .. SEP .. "(%d+)$")
            local cc, tt = tonumber(c) or 0, tonumber(t) or 0
            -- ★ J-2：顺手把本 key 下的过期条目标出来。反正已经在遍历了，零额外开销。
            --   ⚠ 不能在 iter() 里直接 erase（迭代中改库）⇒ 先攒着，循环外再删。
            if is_expired(tt, now) then
                dead[#dead + 1] = kk
            else
                items[#items + 1] = { k = kk, t = tt, c = cc, s = decay_score(cc, tt, now) }
            end
        end
        acc = nil
        for _, k in ipairs(dead) do db:erase(k) end
        -- 裁到上限：删**分数最低**的。旧行为是删「最旧」的，那会把「很久没用但以前
        --   很熟」和「刚用两次」一视同仁 ⇒ 用 score 才符合衰减淘汰的语义。
        if #items > MAX_CONT_PER_KEY then
            table.sort(items, function(a, b)
                if a.s ~= b.s then return a.s < b.s end
                return a.t < b.t
            end)
            for i = 1, #items - MAX_CONT_PER_KEY do db:erase(items[i].k) end
        end
    end
end

-- 为「本次新增的尾位置」建索引。
-- ★ 关键设计：库里存的是「紧跟在 key 后面的**那一个** token」，不是「key 之后的整条尾巴」。
--     这样值不会随句子变长而改变 ⇒ 已写过的记录无需重写，每次上屏只写
--     #token × MAX_KEY_LEN 条（2 字上屏 ≈ 8 次写库），而不是每次把整句重新索引（≈ 40 次）。
--     更长的候选（有 → 有点 → 有点冷）由查询时**逐层展开**拼出来。
local function index_new(sid, from_pos, new_len, chars, toks)
    local from = from_pos
    if from < 1 then from = 1 end
    for e = from, new_len - 1 do
        local cont = cont_after(toks, e)
        if cont and cont ~= "" then
            local maxlen = MAX_KEY_LEN
            if maxlen > e then maxlen = e end
            for len = 1, maxlen do
                local key = table.concat(chars, "", e - len + 1, e)
                local kk = key .. SEP .. cont
                local s = state(sid)
                if not s.seen[kk] then
                    s.seen[kk] = true
                    record(sid, key, cont)
                end
            end
        end
    end
end

local function trim(s)
    while #s.toks > 1 and #s.chars > MAX_CONTEXT_LEN do
        local t = table.remove(s.toks, 1)
        for _ = 1, ulen(t) do table.remove(s.chars, 1) end
    end
end

local function learn_token(sid, token)
    local s = state(sid)
    if not has_cjk(token) then
        reset_sentence(s)
        return false
    end
    if ulen(token) > LEARN_MAX_CHARS then return false end

    s.toks[#s.toks + 1] = token
    for _, c in ipairs(to_chars(token)) do s.chars[#s.chars + 1] = c end
    trim(s)
    local new_len = #s.chars

    -- ★ 从「新 token 起始位置的前一格」开始建索引就够了：
    --   更早的位置 e，它后面的 token 没变 ⇒ 之前已经建过（s.seen 也会去重）。
    --   ⚠ 千万不能用 #chars 的前后差来算起点：trim 丢掉句首字符后差值会变成 0，
    --      起点被推到最后 ⇒ 「早晨→好像」这类"上一个 token 结尾接新 token"的记录
    --      会整条漏建（实测示例 3 少了一个分支）。
    local from = new_len - ulen(token) - 1
    if from < 1 then from = 1 end

    index_new(sid, from, new_len, s.chars, s.toks)
    s.last_time = os.time()
    _stat.learns = _stat.learns + 1
    _stat.last_ctx = utail(table.concat(s.chars), MAX_CONTEXT_LEN)
    return true
end

-- ===================================================================
-- 二、如何判断「发生了一次新的上屏」
-- ===================================================================
-- 本 librime 版本实测（2026-09-26）：
--   · commit_history:iter() 在本构建不适用：迭代出来的是 std::reverse_iterator 结构体（无法被 Lua 的 for … in 遍历）。这是绑定层暴露接口的形态（记录数据完好，可经 size / back() 读取），并非运行故障，不必“修复”。
--   · commit_history.size 是**属性**（数字）而不是方法；`size()` 会报
--     "attempt to call a number value"。
--   · commit_history:back() 可用，.text / .type 都能取。
--   · commit_notifier / select_notifier 实测只对数字键触发，空格与分号不触发
--     ⇒ 万象 user_predict.lua 用 commit_notifier 做学习，在本环境不可靠，
--       所以这里改成「update_notifier + 三判据」。
-- 三判据：① size 变了 ② back().text 变了 ③ 输入码从非空变空（覆盖队列满 + 连打同词）
local function read_commit(ctx)
    local size, back
    pcall(function() size = ctx.commit_history.size end)
    pcall(function() back = ctx.commit_history:back().text end)
    return size, back
end

-- ===================================================================
-- 三、查询
-- ===================================================================
local function lookup(sid, key)
    local db = get_db(sid)
    if not db then return nil end
    local pfx = ASSOC_PREFIX .. key .. SEP
    local acc = db:query(pfx)
    if not acc then return nil end
    local items = {}
    local head = #pfx
    local now = os.time()
    for k, v in acc:iter() do
        if k:sub(1, head) == pfx then
            local cont = k:sub(head + 1)
            local c, t = tostring(v):match("^(%d+)" .. SEP .. "(%d+)$")
            local cc, tt = tonumber(c) or 0, tonumber(t) or 0
            items[#items + 1] = { cont = cont, c = cc, t = tt,
                                  s = decay_score(cc, tt, now) }
        end
    end
    acc = nil
    if #items == 0 then return nil end
    -- ★ J-2：按衰减分降序（旧行为是按 count 降序，时间只当同分 tiebreak）。
    table.sort(items, function(a, b)
        if a.s ~= b.s then return a.s > b.s end
        return a.t > b.t
    end)
    return items
end

local function lookup_best(sid, key)
    local items = lookup(sid, key)
    if not items then return nil end
    return items[1].cont
end

-- min_len：命中键的**最短**长度（默认 1 = 最长后缀一路退到单字）。
-- ★ 为什么需要它：刚上屏一个 3 字 token「有点冷」时，若允许退化到 1 字键「冷」，
--     查到的其实是「冷」这个**字**的所有历史接续，而不是「有点冷」这个**词**的接续。
--     字级别的接续本就杂（而且一旦跨句污染，字级键最先被污染），
--     越往深层级联想越明显。限定 min_len = 刚上屏 token 的字数之后，
--     逐级联想只会沿着真实的上屏边界往前推，查不到就干净地回退固定词库。
local function query(sid, ctx_text, min_len)
    if not ctx_text or ctx_text == "" then return nil end
    _stat.queries = _stat.queries + 1

    local key, items
    local maxlen = MAX_KEY_LEN
    local cl = ulen(ctx_text)
    if maxlen > cl then maxlen = cl end
    local lo = min_len or 1
    if lo < 1 then lo = 1 end
    if lo > maxlen then
        -- 上下文比刚上屏的 token 还短（只可能出现在超长 token 上）：别硬凑
        _stat.last_key = nil
        return nil
    end
    for len = maxlen, lo, -1 do
        key = utail(ctx_text, len)
        items = lookup(sid, key)
        if items then break end
    end
    if not items then
        _stat.last_key = nil
        dbg("[q] key=%s -> 无命中", tostring(key))
        return nil
    end
    _stat.last_key = key
    do
        local t = {}
        for _, it in ipairs(items) do t[#t + 1] = string.format("%s(c%d,t%d)", it.cont, it.c, it.t % 100000) end
        dbg("[q] key=%s -> %d 项: %s", tostring(key), #items, table.concat(t, " "))
    end

    -- 逐层展开：第 1 层 = 每条分支的下一个 token（好 / 几点 / 好像）；
    -- 第 2、3 层 = 各分支再往下接一个 token（有 → 有点 → 有点冷）。
    -- ★ 按「层」而不是按「分支」输出，让多个历史分支都在第一屏露脸。
    local out, seen = {}, {}
    local level = {}
    for i, it in ipairs(items) do
        if i > MAX_HISTORY then break end
        level[#level + 1] = { key = utail(key .. it.cont, MAX_KEY_LEN), acc = it.cont }
    end

    local late = {}                 -- 拼出来「不像话」的长候选，最后没位置就不给
    local depth = 1
    while depth <= GRANULARITY_MAX and #level > 0 and #out < MAX_HISTORY do
        local nxt = {}
        for _, item in ipairs(level) do
            if #out >= MAX_HISTORY then break end
            local acc = uhead(item.acc, CANDIDATE_MAX_LEN)
            if acc ~= "" and not seen[acc] and ulen(acc) <= CANDIDATE_MAX_LEN then
                seen[acc] = true
                out[#out + 1] = acc
            end
            local sub = lookup_best(sid, item.key)
            if sub then
                local merged = item.acc .. sub
                if ulen(merged) <= CANDIDATE_MAX_LEN then
                    local node = { key = utail(item.key .. sub, MAX_KEY_LEN), acc = merged }
                    -- 拼出来的（≥2 个 token 接起来的）要过一遍固定词库：
                    --   首字 + 后续 能在本方案的词典里找到 ⇒ 是个像话的短语，正常给；
                    --   找不到 ⇒ 只是"你上次刚好连着打了这两个词"（打字+时候=打字时候），
                    --   放进 late，等自然候选都排完了还有空位再补在最后。
                    if MERGE_STRICT and ulen(merged) > 2 and not natural_phrase(merged) then
                        late[#late + 1] = node
                    else
                        nxt[#nxt + 1] = node
                    end
                end
            end
        end
        level = nxt
        depth = depth + 1
    end

    for _, item in ipairs(late) do
        if #out >= MAX_HISTORY then break end
        local acc = uhead(item.acc, CANDIDATE_MAX_LEN)
        if acc ~= "" and not seen[acc] then
            seen[acc] = true
            out[#out + 1] = acc
        end
    end

    if #out == 0 then return nil end
    _stat.hits = _stat.hits + 1
    _stat.last_cands = table.concat(out, " ")
    return out
end

local function context_of(sid)
    local s = state(sid)
    if #s.chars == 0 then return nil end
    return utail(table.concat(s.chars), MAX_CONTEXT_LEN)
end

-- ===================================================================
-- 四、固定词库（随方案发布的 assoc_fixed.txt）
-- ===================================================================
-- 生成方式见 .workbuddy/tmp/gen_assoc_fixed.py（v3，2026-09-26）：从 ly_wubi.dict.yaml
-- 取所有 2~4 字词条，首字当 key、剩余部分当「后续」；
--   ① 按词典**第三列的词频权重**降序取每个 key 的前 12 条（词典文件顺序 ≈ 编码顺序，
--      不是词频！v1/v2 踩的就是这个坑，取出来全是「编码靠前」的生僻接续）
--   ② 后续 ≥2 字时**必须自身也是词典词条** ⇒ 淘汰「冷→若冰霜」这类成语机械切分
--   结果：4325 首字 / 28611 条 / 135.5 KB。可用开关 `assoc_fixed` 关掉（纯历史模式）。
-- 为什么不直接查词典：Lua 拿不到词典文件，只能离线生成一份随方案走。
-- 候选路径按顺序试：共享目录（方案所在，随方案发布的词库就在这）→ 用户目录 → 相对路径。
-- ★ Windows 上 Lua 的 io.open 走 ANSI 码页，中文目录可能打不开 ⇒ 必须多试几个，
--   并把实际命中的路径记进 _stat.fix_path，好在 /lxzt 里自查。
--   assoc_fixed.txt 是固定联想词库，随方案发布，需要重新生成见 gen_assoc_fixed.py。
local function fixed_paths()
    local out = { FIXED_FILE }
    pcall(function()
        local d = rime_api.get_user_data_dir()
        if d and d ~= "" then out[#out + 1] = d .. "/" .. FIXED_FILE end
    end)
    pcall(function()
        local d = rime_api.get_shared_data_dir()
        if d and d ~= "" then out[#out + 1] = d .. "/" .. FIXED_FILE end
    end)
    -- 去重，用户目录优先
    local seen, res = {}, {}
    for i = #out, 1, -1 do
        local p = out[i]
        if p and not seen[p] then seen[p] = true; res[#res + 1] = p end
    end
    return res
end

local function load_fixed()
    if _fixed or _fixed_tried then return _fixed end
    _fixed_tried = true
    local tried = {}
    for _, path in ipairs(fixed_paths()) do
        tried[#tried + 1] = path
        local f = io.open(path, "r")
        if f then
            local t = {}
            for line in f:lines() do
                local k, v = line:match("^(.-)\t(.*)$")
                if k and v and k ~= "" then
                    local list = {}
                    for w in v:gmatch("%S+") do list[#list + 1] = w end
                    if #list > 0 then t[k] = list end
                end
            end
            f:close()
            _fixed = t
            _stat.fix_path = path
            _stat.fix_n = (function() local n = 0; for _ in pairs(t) do n = n + 1 end; return n end)()
            return _fixed
        end
    end
    _stat.err = "固定词库打不开:" .. table.concat(tried, " | ")
    return nil
end

-- 固定词库开关 `assoc_fixed`（2026-09-26 新增，schema switches 里声明）：
--   states: [ 纯历史, 带词库 ]，reset: 1 ⇒ 默认带词库。
--   关掉它 = 万象那种「纯靠养」模式：只有自己上屏过的历史才有联想，
--   冷启动一个候选都没有。没声明这个开关时按「开」处理。
--   FIXED_MAX <= 0 也等价于关掉（连文件都不去读）。
local _ctx = nil
local function fixed_on()
    if FIXED_MAX <= 0 then return false end
    local ok, v = pcall(function() return _ctx:get_option("assoc_fixed") end)
    if ok and v == false then return false end
    return true
end

-- 固定候选：基于上下文**最后 max_k 个字**（需求文档 5.4.1）
--
-- ★★ S101b-3：为什么改成「最长后缀优先」+「多字上屏不许退化到单字」
--
--   原实现只查 context 的**最后一个字**，于是：
--       上屏「测试」 ⇒ 查「试」 ⇒ 拿到「试听/试用/试验…」的后半截「听」
--       ⇒ 联想候选是**追加**上屏的 ⇒ 选了就变成「测试听」，根本不通。
--
--   根因不是数据错，是**匹配粒度错**：「试 + 听 = 试听」能成立的前提是
--   context 末尾**恰好**就是 key「试」。换了「测试」还去用「试」的接续，
--   等于默认「任何以「试」结尾的词都能接「听」」，这个默认站不住。
--
--   ⇒ 修法：① 多字 key（v3 新增 8185 条）优先匹配，**最长者胜**；
--           ② 刚上屏的是**多字词**时，宁可不给固定联想，也不退化到单字
--              （v3 之前这里就是半截词的唯一来源）。
--           ③ 刚上屏的是**单字**时才查单字 key（这套数据的设计前提）。
--
-- ⚠ last_tok 的语义：明确传入「刚上屏的那个词」，比截取 context 后 N 字更准。
--   不传（旧的调用点 / 诊断命令）时退化为 kmin=1，保持旧行为不变。
local MAX_FIXED_KEY = 3        -- 参与匹配的最长后缀（生成端 key 长度上限就是 3）
local function fixed_candidates(context, used, last_tok)
    if not fixed_on() then return nil end
    if not context or context == "" then return nil end
    local t = load_fixed()
    if not t then return nil end

    -- ① key 长度下限
    local kmin = 1
    if last_tok and ulen(last_tok) >= 2 then kmin = 2 end
    local clen = ulen(context)
    local maxk = clen < MAX_FIXED_KEY and clen or MAX_FIXED_KEY
    if maxk < kmin then
        -- context 比 kmin 还短（极少见）：只能允许单字，否则一条都查不到
        maxk, kmin = clen, 1
    end

    -- ② 最长后缀优先，第一个命中即用
    local list = nil
    for L = maxk, kmin, -1 do
        local suf = utail(context, L)
        if t[suf] then list = t[suf]; break end
    end
    if not list then return nil end

    local out = {}
    for _, w in ipairs(list) do
        if #out >= FIXED_MAX then break end
        -- ★ 这里**不要**写 used[w]：去重由 build_candidates 统一做。
        --   写过一次就会导致「先标后判」，固定候选一条都进不了最终列表。
        if not used[w] and ulen(w) <= CANDIDATE_MAX_LEN then
            out[#out + 1] = w
        end
    end
    return #out > 0 and out or nil
end

-- -------------------------------------------------------------------
-- 常用字白名单：加载 + 判定（S101b-2，说明见文件头的常量区）
-- -------------------------------------------------------------------
local function common_paths()
    local out = { COMMON_FILE }
    pcall(function()
        local d = rime_api.get_user_data_dir()
        if d and d ~= "" then out[#out + 1] = d .. "/" .. COMMON_FILE end
    end)
    pcall(function()
        local d = rime_api.get_shared_data_dir()
        if d and d ~= "" then out[#out + 1] = d .. "/" .. COMMON_FILE end
    end)
    local seen, res = {}, {}
    for i = #out, 1, -1 do
        local p = out[i]
        if p and not seen[p] then seen[p] = true; res[#res + 1] = p end
    end
    return res
end

local function load_common()
    if _common or _common_tried then return _common end
    _common_tried = true
    local tried = {}
    for _, path in ipairs(common_paths()) do
        tried[#tried + 1] = path
        local f = io.open(path, "r")
        if f then
            local s = f:read("*a")
            f:close()
            if s and s ~= "" then
                local t = {}
                for _, c in ipairs(to_chars(s)) do
                    if c ~= "" then t[c] = true end
                end
                _common = t
                local n = 0
                for _ in pairs(t) do n = n + 1 end
                _common_n = n
                return _common
            end
        end
    end
    -- ★ fail-open：表读不到就**不拦**，宁可放过生僻字也不能让联想空掉
    _stat.common_err = "常用字表打不开:" .. table.concat(tried, " | ")
    return nil
end

-- 字符的 Unicode 码点（只处理 1~3 字节，够用）
local function codepoint(c)
    if not c or c == "" then return nil end
    local n = #c
    local b1, b2, b3 = c:byte(1), c:byte(2), c:byte(3)
    if n == 1 then return b1 end
    if n == 2 and b2 then return (b1 % 32) * 64 + (b2 % 64) end
    if n == 3 and b2 and b3 then return (b1 % 16) * 4096 + (b2 % 64) * 64 + (b3 % 64) end
    return nil
end

-- 是否「需要查白名单」的字符：CJK 扩展A 起点 0x3400 以上（汉字及更高区）。
-- 之下的（ASCII、拉丁、西里尔、假名、CJK 符号如「。」U+3002）一律放行 ——
-- 本表只管汉字生僻度，不替用户决定标点该不该出现。
local function need_common_check(c)
    local cp = codepoint(c)
    return cp ~= nil and cp >= 0x3400
end

-- 整条候选要不要留：多字**逐字**判定，任一汉字不在表内 ⇒ 整条丢弃。
local function common_ok(w)
    if not ASSOC_COMMON_ONLY then return true end
    if not w or w == "" then return true end
    local t = load_common()
    if not t then return true end        -- fail-open
    for _, c in ipairs(to_chars(w)) do
        if need_common_check(c) and not t[c] then
            _stat.common_blocked = (_stat.common_blocked or 0) + 1
            return false
        end
    end
    return true
end

-- 「多级拼接出来的候选像不像话」：
--   把 w 拆成「首字 + 后续」，去固定词库（= 本方案词典的 2~4 字词）里查。
--   查得到 ⇒ 是个像话的短语（有点冷 / 上班时间）；查不到 ⇒ 只是用户上次恰好连着
--   打了这两个词（打字+时候 = 打字时候），看着像脏东西。
natural_phrase = function(w)
    local fx = load_fixed()
    if not fx then return true end        -- 词库没加载（或关了）⇒ 不拦
    local n = ulen(w)
    if n < 3 then return true end         -- 2 字以内基本都是词，不查
    local list = fx[uhead(w, 1)]
    if not list then return false end
    local rest = utail(w, n - 1)
    for _, c in ipairs(list) do
        if c == rest then return true end
    end
    return false
end

-- ===================================================================
-- 五、组装一次联想（历史在前，固定补后）
-- ===================================================================
local natural_phrase = nil      -- 前向声明：实现在固定词库那节（要用到 load_fixed）

local function build_candidates(sid)
    local s = state(sid)
    local context = context_of(sid)
    if not context then return nil end

    -- 命中键至少要覆盖「刚上屏的那个 token」的长度（上限 MAX_KEY_LEN）
    local last = s.toks[#s.toks]
    local min_len = last and ulen(last) or 1
    if min_len > MAX_KEY_LEN then min_len = MAX_KEY_LEN end

    local hist = query(sid, context, min_len)
    dbg("[build] ctx=%s hist=%s", tostring(context), hist and table.concat(hist, " ") or "nil")
    local list, used = {}, {}
    if hist then
        for _, w in ipairs(hist) do
            if #list >= MAX_CANDIDATES then break end
            if not used[w] then used[w] = true; list[#list + 1] = w end
        end
    end
    local n_hist = #list
    -- ★ S101b-3：把「刚上屏的整个词」传给固定词库 ⇒ 多字 key 优先，
    --   且多字上屏时不再退化到单字（半截词的根）。
    local fx = fixed_candidates(context, used, last)
    dbg("[build] fixed=%s", fx and table.concat(fx, " ") or "nil")
    if fx then
        for _, w in ipairs(fx) do
            if #list >= MAX_CANDIDATES then break end
            if not used[w] then used[w] = true; list[#list + 1] = w end
        end
    end
    if #list == 0 then return nil end

    -- ★ S101b-2：出栏前过一遍常用字白名单（历史 + 固定两路都在这里拦）
    --   为什么放在**出口**而不是各路内：历史候选、固定候选，以及历史里
    --   多级拼出来的（如「浿沁」）都要拦，放在出口一处即可全覆盖。
    --   ⚠ list 的前 n_hist 条是历史、其后是固定词库补的；过滤**保序**，
    --     所以 kept 里历史仍然排在前面 ⇒ 用它重算 n_hist 即可。
    if ASSOC_COMMON_ONLY then
        local kept, kept_n = {}, 0
        for i, w in ipairs(list) do
            if common_ok(w) then
                kept[#kept + 1] = w
                if i <= n_hist then kept_n = #kept end
            end
        end
        -- ⚠ 一条都不剩时**保留原样**（fail-open）：
        --   白名单误伤（联想整条空掉）比放过一两个生僻字更糟。
        if #kept > 0 then
            list, n_hist = kept, kept_n
        end
    end

    if #list == 0 then return nil end

    local only_hist = {}
    for i = 1, n_hist do only_hist[i] = list[i] end
    return list, only_hist
end

-- -------------------------------------------------------------------
-- 移动端判定 + 联想状态标记（2026-09-26 新增）
-- -------------------------------------------------------------------
-- 移动端「下滑数字」和 PC 端数字键是两种完全不同的意图：
--   移动端：数字键 = 想输入这个数字（选候选靠点击候选栏）
--   PC 端  ：数字键 = 选第 N 个候选
-- 联想状态下不管的话，移动端下滑的数字会被 super_sequence 当成手动调频吃掉。
-- 判据与 super_sequence.lua 的 is_mobile_device() 保持一致（鸿蒙 /data/storage/elN、
-- /space/、/harmony/…），这里只取最关键几条。
local _mobile = nil
local function is_mobile()
    if _mobile ~= nil then return _mobile end
    _mobile = false
    if jit and jit.os then
        local o = (jit.os or ""):lower()
        if o:find("android") or o:find("harmony") then _mobile = true; return _mobile end
    end
    pcall(function()
        local d = ((rime_api.get_user_data_dir() or "") .. " " ..
                   (rime_api.get_shared_data_dir() or "")):lower()
        if d:find("/data/storage/el%d") or d:find("/android/") or d:find("/storage/emulated/")
            or d:find("/sdcard/") or d:find("/harmony") or d:find("/hap/")
            or d:find("/space/") or d:find("/storage/users/") then
            _mobile = true
        end
    end)
    return _mobile
end

-- ★ S88：原先这里有 `ASSOC_FLAG` + `mark_predicting()` 一整套「共享联想态标志」
--   （写 _G 全局 + ctx:set_property 双通道），配合 Submit_text 的空格豁免使用。
--   已随那段豁免一并删除，理由见下方 mark_ph_mode 的撤销记录。
--
--   ★ 若将来确实需要「跨文件告知别人现在是联想段」，
--     先想清楚是不是真需要 —— 上一轮就是**为了一个不存在的功能**加的，
--     加完只有 `on=false` 一个方向在用（S86 才补上 on=true，而它服务的功能不存在）。

-- S65：读「当前是否处于联想态」。
--   ⚠⚠ 这条判定被坑过三次，逐个记在这里避免重犯：
--     ① S60：读 `_ph_mode`（模块级 local）—— refresh 同步重入 + predictor
--        建段在稍后 ⇒ 易失，315 次只有 3 次命中
--     ② S63：读 `_G.__touchwb_assoc_predicting` —— 它被 smart_assoc /
--        Submit_text / pair_punct / super_sequence **四方共享**，
--        任一方清它就影响 T ⇒ pending=true 但 pred_st=false 的矛盾
--     ③ S64：读 `pending_cands ~= nil` —— 那是**数据**不是**时机**，
--        存活窗口比 predictor 建段短 ⇒ 联想「偶尔」出现
--   ⇒ 正确做法：用专用的时机标记 `_assoc_ready`（settle_commit 置位，
--     clear_assoc / 关开关才清），窗口足够长。
local function in_predicting()
    return _assoc_ready == true
end

-- S62：安全读一个 option，拿不到就返回 "?"（排错探针用，不影响主逻辑）。
local function ctx_get_option_safe(env, name)
    local ctx = env and env.engine and env.engine.context
    if not ctx then return "?" end
    local ok, v = pcall(function() return ctx:get_option(name) end)
    if not ok then return "?" end
    if v == nil then return "nil" end
    return tostring(v)
end

-- ===================================================================
-- 六、组件
-- ===================================================================
-- ★★★ S77：PC 端**无条件**不启用联想（assoc_pc 开关已删除）
-- 【为什么删掉这个开关】
--   原本有「仅移动 / 双端」两档，但「双端」那一档**在 PC 上根本用不了**，
--   不是「默认关」的问题，而是**架构上不可能**：
--     PC（小狼毫 / Weasel）的候选栏是**跟随 composition 的浮窗**，
--     一上屏就消失，下次打码才重新出现。
--     而我们的联想是靠往输入码里塞占位符 `›` 硬造出一个段 ——
--     PC 上这个段会一直挂着，于是变成：
--       ① 上屏之后候选栏**不消失**（占位符段还在，联想词一直挂着）
--       ② 编码栏常驻 `›`
--       ③ 随手按空格 / 数字会把联想词误上屏（段上有候选 ⇒ 空格 = 选第一条）
--     也就是说「双端」档在 PC 上只会添乱，不会带来任何可用效果。
--   用户原话（2026-10-04）：「PC 上没见到谁家输入法打字上屏后候选窗还留着，
--   所以这个也永远无法在 PC 端使用。」
--   ⇒ 「双端」是一个**只会产生误解、从不产生价值**的选项，删掉。
--     联想从此是**纯移动端功能**，由 is_mobile() 单一判据决定。
--
-- 【现在的判据】两条，都不可配置：
--     ① smart_assoc 开关是「关想」      → 关闭
--     ② 不是移动端（PC / 小狼毫）        → 关闭
local function enabled(ctx)
    local ok, v = pcall(function() return ctx:get_option("smart_assoc") end)
    if ok and v == false then return false end
    -- ★ S77：非移动端一律关闭，不再看 assoc_pc 开关（该开关已删）
    if not is_mobile() then return false end
    return true
end


-- -------------------------------------------------------------------
-- S60：predictor 空段模式
-- -------------------------------------------------------------------
-- ★★★ 本项目最硬的一条铁律（S59 双端真机实测得出）：
--   「长按空格唤起语音」要求 App 在 touch-down 时看到**输入区为空**才启动
--   0.51 秒长按计时器。占位符 `›` 让输入区恒为非空 ⇒ 无论 lua 怎么改返回值、
--   怎么吞键、主题怎么挂 long_click，都过不了这道门（v1~v6 六轮全败）。
--   唯一可行路径：段由官方 predictor 原生创建 —— 它的输入码天然为空。
--
-- 本模式做的事：
--   旧路：settle_commit → need_push → ctx:push_input("›")  → 自建段（输入码=›）
--   新路：settle_commit → 只备好 pending_cands，由 predictor 建空段，
--         T.func 在 input=="" 且处于预测态时吐我们的联想候选。
--
-- 判定「当前是 predictor 空段」而不是普通空输入：
--   predictor 段在 context 上留下标记（has_menu / predicting 状态），
--   且我们没推过占位符。两者同时成立才算。

-- 我们最近一次是「自己推占位符」还是「交给 predictor 建段」
--   "ph"   = 旧路：ctx:push_input("›") 自建段
--   "pred" = 新路：predictor 原生建段（输入码为空）
-- ★ S79：两档都能走到，所以这个标记**恢复双值**。
--   保留它还有一个理由：三处 probe 打印 segmode，日志里靠它一眼看出
--   当前处于哪条路 —— 真机排查时这行是判断「有没有走错」最快的锚点。

-- ★★★★★ S88：这里原先是S86 加的「长按标志同步」逻辑，已删除
-- ------------------------------------------------------------------------
-- 【为什么删掉—— 长按语音从来不需要 Lua 配合】
--   S86 的全部内容是：进入 pred 空段时把 `_G.__touchwb_assoc_predicting`
--   置真，好让 `Submit_text.lua` 里那段「把空格让给长按」的豁免生效。
--   而S88 实测证明这条链路的前提是错的：
--
--   ① 用户澄清（2026-10-04，决定性）：
--      「长按空格唤醒语音功能一直好用，从没失效过。」⇒ 从来没有 bug。
--   ② 19:41:10 真机实测：长按成功的那一刻，
--      App 侧 = [STTBannerContainerController] didAppear
--              → startRecording source=didAppear#3
--              → [SpeechFSM] Starting -> Listening
--      同一时刻 `assoc_probe.log` 里 19:41:09~19:41:12 **一行都没有**。
--      ⇒ App 在手指还按着时就判定为长按并消费掉这次交互，
--        **空格按键从未派发到 Rime**，引擎侧零事件。
--
--   ⇒ 所以「把空格让给长按」这个思路本身是空的：
--     长按根本不需要空格，也就永远走不到那段豁免；
--     那段代码只在**短按**时命中，判据一旦成立就把用户的空格扣住不上屏
--     ⇒ 是纯粹的用户可感知损害（S88 已把那段代码一并删除）。
--
-- 【教训（比这段代码本身重要）】
--   ★ 八轮（S79~S87）都在修一个不存在的功能，而且每轮都用真机日志"验证通过"。
--   根因是**从不回头问用户"这个功能坏过吗"**。
--   ⇒ 修任何功能之前，先确认它在用户那里到底有没有坏过、
--     坏时的具体现象是什么。**否则日志只会把我们带得更远。**
--
-- 【_ph_mode 已移除（S118-2 清理）】
--   原以为它还有合法用途（T.func 区分「打码中 / 联想态」），但核查后：
--   in_pred_mode() 全代码只被 dbg/probe 调用，行为判据早已是
--   is_pred_seg（= want_pred and in_predicting()，读 _assoc_ready）。
--   ⇒ _ph_mode / mark_ph_mode / in_pred_mode 纯属探针噪声，已删除。
--   此段仅作历史保留。
-- ===================================================================
-- ★★★ S80：不再二选一，恒走 predictor 空段路
-- -------------------------------------------------------------------
-- 【S80 的依据是本机沙箱实验，不是推测】（记录：tools/S80_沙箱实验记录.md）
--   沙箱 = D:/rimetest，一套可用的 librime 1.13.1，可直接跑，不必赌手机复测。
--   四组对照，只动两个变量：
--     A  predictor 在 + prediction 开关 ON                     → 空段 3 次 input=""
--     B  predictor 在 + prediction 开关 OFF                    → 空段 1 次（仅 init）
--     C  predictor 在 + 开关**整个不定义**                     → 空段 3 次，**与 A 一致**
--     D  predictor **组件移除**                                → 空段 0 次
--   判读：
--     · C ⇒ **`prediction` 开关不是空段的载体**
--     · D ⇒ **空段的唯一载体是 `predictor` 组件本身**
--     · A/B 之差 ⇒ 开关只管「段里填不填官方预测词」，不管「段建不建」
--   我们要的是「段」（输入码为空 ⇒ App 启长按计时器），
--   不要「官方词」⇒ **两件事在架构上可分离**。
--
-- ★ 另一条铁证：沙箱自省显示 `ctx.add_segment -> type=nil`
--   ⇒ **Lua 侧根本没有建段API**，我们无法自己造空段，只能靠 predictor。
--   这从 API 层面否掉了「不用 predictor 也能造空段」这条路。
--
-- 【所以 S80 删掉 `assoc_pred`】
--   S79 加它是为了在「空段 / 占位符」之间二选一，
--   前提假设是「两套联想必须互斥、只能选一个」。
--   ★ **沙箱证明这个前提本身是错的**：
--     predictor 在场就有空段，我们的候选可以挂在这个空段上（T.func），
--     **不需要二选一**。⇒ 这个开关从一开始就没有存在的必要。
--   删掉它还顺带解决了用户反馈的
--   「三个开关被 App 绑定同开同关」—— 少一个 `reset: 1` 开关，绑定链短一环。
--
-- 【历史：为什么绕回来了】
--   S74 删 predictor、S75 清custom.yaml、S78 连文件都不打包 ——
--   错在只看到「菜单里多一个重复的联想开/关」这个**表面症状**，
--   没看到「长按空格唤起语音的唯一载体」这个**架构作用**。
--   （复盘铁律第 5 条：移除一个组件前，先确认它是不是别的功能的唯一载体。）
--   S79 恢复它但用开关做二选一；S80 沙箱证明二选一多余，于是彻底简化。
local function use_pred_segment()
    -- ★ S80：恒为 true。
    --   空段由 `predictor` 组件（engine/processors 首位）保证，
    --   我们的候选由 T.func 挂在这个空段上—— 不再需要 `assoc_pred` 开关。
    return true
end

-- ★ S80：`use_our_placeholder()` 已删除。
--   它原本是 `not use_pred_segment()`，S80 起 use_pred_segment 恒 true
--   ⇒ 该函数恒false，而唯一调用它的那处（update_cb 建段）也已改写。
--   留着一个恒假的函数只会让人以为「还能切回占位符路」—— 不能切（S52/S59）。

-- 「本轮是否已提交过联想数据」的时机标记。
--   ★ 四次修判定的结论（前三次的教训都在in_predicting 的注释里）：
--     ① 数据本身（pending_cands）—— 存活窗口比 predictor 建段短
--     ② 全局共享标记 —— 会被别的文件清掉
--     ③ 易失的模块标记 —— refresh 同步重入导致慢一拍
--     ④ **本标记** —— settle_commit 置位，reset_chain **故意不清**它，
--        只在 clear_assoc / 开关关闭时清 ⇒ 窗口足够长
local function use_our_candidates()
    return use_pred_segment()
end


-- 「联想占位符还在输入码里」时，哪些键可以照常往下走（拼码 / 选候选 / 移动光标），
-- 其余一律视为「要打别的字符了」⇒ 先把占位符清掉。
-- 不清的后果：punctuator 会先把 composition 上屏再打标点 ⇒ 联想词被莫名其妙打出去。
local KEEP_KEYS = {
    space = true, Return = true, KP_Enter = true, Escape = true,
    BackSpace = true, Delete = true, Tab = true, ISO_Left_Tab = true,
    Left = true, Right = true, Up = true, Down = true,
    Home = true, End = true, Page_Up = true, Page_Down = true,
    Prior = true, Next = true, Insert = true,
    Shift_L = true, Shift_R = true, Control_L = true, Control_R = true,
    Alt_L = true, Alt_R = true, Super_L = true, Super_R = true, Caps_Lock = true,
}
local function is_keep_key(repr)
    if not repr or repr == "" then return false end
    local base = repr:match("([^%+]+)$") or repr   -- 带修饰键时只取最后一段
    if KEEP_KEYS[base] then return true end
    return base:match("^%w$") ~= nil               -- 单个字母/数字：交给 speller 拼码
end

-- 回车键的马甲很多：不同前端（小狼毫 / 鸿蒙超越 / 安卓）送进来的名字和 keycode 都不一样。
-- 只认 "Return" 会在真机上漏判 ⇒ 表现就是「按回车换行了，但联想候选栏没清」。
-- 所以名称、keycode（X11 keysym 系列 + Android KEYCODE_ENTER）一起兜。
local ENTER_REPRS = {
    Return = true, KP_Enter = true, Linefeed = true,
    ISO_Enter = true, Enter = true, KP_Return = true,
}
local ENTER_KEYCODES = { [0xFF0D] = true, [0xFF8D] = true, [0xFE08] = true }
local function is_enter(repr, kc)
    if repr and repr ~= "" then
        local base = repr:match("([^%+]+)$") or repr   -- 去掉 Shift+ / Ctrl+ 前缀
        if ENTER_REPRS[base] then return true end
        if kc == 66 and not base:match("^%a$") then return true end  -- Android 66=ENTER
    end
    return ENTER_KEYCODES[kc] == true
end

-- 同一个物理键在不同端上名字可能不同大小写/不同叫法，统一取末段并转小写再比。
--   （标准是 "BackSpace"，部分键盘/前端送 "Backspace"/"backspace"）。
--   一律 lower 之后再比，并且补上 keycode 兜底，避免再漏。
local function base_repr(repr)
    if not repr or repr == "" then return "" end
    return (repr:match("([^%+]+)$") or repr):lower()
end

local SPACE_KEYCODES = { [0x20] = true, [0xFF80] = true, [62] = true }  -- 62=安卓 SPACE
local function is_space(repr, kc)
    local b = base_repr(repr)
    if b == "space" or b == "kp_space" then return true end
    return SPACE_KEYCODES[kc] == true
end

local BS_KEYCODES = { [0xFF08] = true, [8] = true, [67] = true }        -- 67=安卓 DEL
local function is_backspace(repr, kc)
    local b = base_repr(repr)
    if b == "backspace" or b == "back" or b == "delete_l" then return true end
    return BS_KEYCODES[kc] == true
end

-- 这个按键事件是「按下」还是「松开」。
--   用来区分空格的**短按**（= 上屏联想词）与**长按**（= 交给前端启动语音）。
--   librime 的 KeyEvent 自带 release 位；个别版本只在 repr 里带 Release+ 前缀。
--   ⚠ 收不到 release 事件的前端（只在按下时调用 ProcessKey）会一直返回 false，
--     那时「语音优先」档会退化成"永远放行"—— 已知代价（S76 已删该档）。
local function is_release(key_event)
    local ok, r = pcall(function() return key_event.release and key_event:release() end)
    if ok and r == true then return true end
    -- ② modifier 的 release 位（kReleaseMask = 1<<30）。
    --   用 `>=` 而不是位与：Lua 5.1 没有 &，写成 >= 语义等价（release 是最高位）。
    local ok2, m = pcall(function() return key_event.modifier end)
    if ok2 and type(m) == "number" and m >= 0x40000000 then return true end
    local repr = ""
    pcall(function() repr = key_event:repr() or "" end)
    return repr:match("Release%+") ~= nil
end

-- 「清掉联想」的标准动作。四处（回车 / Esc / 退格 / 数字 / 标点）必须完全一致，
-- 顺序与内容都不能改：
--   ① _pend_text = nil + _suppress_settle = true
--      ⇒ 否则「输入码从 '›' 变空」会被路径 B 当成一次上屏，又学一遍又推联想
--   ② 先 reset_chain() 再 ctx:clear()
--      ⇒ clear() 会触发 update 回调（S80 起占位符机制已移除，need_push 不复存在；此句仅作历史）
--   ③ clear() 之后再 refresh_non_confirmed_composition()
--      ⇒ 光 clear 只改引擎状态；部分前端（鸿蒙超越）只在收到显式刷新时才隐藏
--        候选栏，不刷就会留着上一次的联想词不消失。
-- "rime_tx_clear_stroke_filter: RefreshNonConfirmedComposition exception"，
-- 怀疑这个 API 在真机上就是坏的 ⇒ 候选栏清不掉。先测出来再决定换什么手段。）
local _refresh_ok, _refresh_seen = nil, false
local _engine = nil                  -- 由 P.func 注入，备用刷新手段要用
local function clear_assoc(ctx)
    local before = ctx.input or ""
    _pend_text = nil
    _suppress_settle = true
    reset_chain()
    -- ★ S65：这里是「用户主动收联想」（回车/Esc/退格/数字/标点），
    --   联想到此为止 ⇒ 时机标记必须清，否则空段里还会冒出上一轮的联想。
    _assoc_ready = false
    -- （S96 曾在此置 `_assoc_user_cleared`，S97 已随 B4 一并撤除。）
    -- ★ S90：同步清「联想段」标志（与 _assoc_ready 严格成对）
    mark_assoc_seg(false)
    -- ★★ S84：快照同步清空。语义与 _assoc_ready 一致 ——
    --   用户主动收了联想，就不该在随后的空段里再冒词。
    --   （标点/回车本来还会经 settle_commit → break_sentence 清一次，
    --     这里是为了「数字选词」「Esc」这些不经过上屏的路径也能清干净。）
    _last_ctx = nil
    ctx:clear()
    -- ★ 兜底刷新（S118-2：占位符机制已于 S80 移除，下面仅作历史说明）：
    --   某些 librime / 前端上 clear() 会同步触发 update 回调——历史上若那时
    --   占位符(›)还有残留就会把它推回来，punctuator / 前端一看 composition
    --   里又有候选就把首候选（联想词）先上屏（真机表现：按句号打出「…句子女。」）。
    --   ⇒ 那时要靠这个兜底再清一次。S80 起联想走 predictor 空段、input 本就为空，
    --   is_ph_input 恒不成立，占位符推送已不存在；但下方 refresh + 空 commit
    --   刷新信号仍保留（PC/标准 librime 与移动端 candidate 重绘都依赖它）。
    local ok_ref = pcall(function() ctx:refresh_non_confirmed_composition() end)
    _refresh_ok, _refresh_seen = ok_ref, true

    -- ★ 真正能让移动端候选栏消失的信号，不是 refresh，而是 commit。
    --   对着同一份日志逐行比对出来的结论：
    --
    --     [clr] before="›" after="" refresh_ok=true      ← clear 成功、refresh 也没报错
    --       ↓
    --     回车/退格路径：后面**什么都没有**
    --       ⇒ 前端没触发 getCandidateList ⇒ 候选栏还挂着上一批联想词（用户报的问题 1/2）
    --       ↓
    --     数字键路径（那里本来就调了 commit_text）：立刻
    --       getCandidateList begin → candidate_list_from_index failed
    --       ⇒ 拉到空列表 ⇒ 候选栏消失 ✅
    --
    --   也就是说：refresh_non_confirmed_composition() 在 tx 引擎上「调用成功但没人听」，
    --   前端只认 commit。所以 refresh 照旧保留（PC/标准 librime 还得靠它），
    --   **之后再无条件补一次空 commit 当刷新信号**。
    --   空 commit 不会往编辑器写字符，前端收到 commit 事件又必去重拉候选列表。
    if _engine then
        _suppress_settle = true      -- commit("") 会触发 update，别把它当成一次上屏
        local ok_c = pcall(function() _engine:commit_text("") end)
        _suppress_settle = true
        dbg("[clr] commit刷新 ok=%s", tostring(ok_c))
    end

                              -- 复位成 ph（= 还没有 predictor 段在起作用）
    dbg("[clr] before=%q after=%q refresh_ok=%s", before, ctx.input or "",
        tostring(ok_ref))
end

-- ===================================================================
-- 联想状态下的空格：v5「按下清空输入区 + 吞掉」（2026-10-02）
-- ===================================================================
--
-- ★★ 先说结论：**第一次长按永远不可能起语音，这是 App 侧的规则，不是我们的问题。**
--    2026-10-02 17:15~17:16 的 keyboard 日志 + assoc_probe.log 对齐后得到的硬证据：
--
--    【铁证 1】App 在**手指落下那一刻**就做了判断，引擎是后来才被调用的：
--      · 输入区非空（联想中）⇒ **立刻**把键派发给引擎（按下后 8ms 就
--        `[InsertTextCommand] 插入文本: " "`），并且**根本不启动长按计时器**。
--      · 输入区为空 ⇒ **不派发**，先等；按住满 **0.51s** ⇒ 起语音
--        （实测 9 次全部是 touch-down + 0.51s 后 `SpeechFSM ... -> Starting`）；
--        不满 0.51s 就松手 ⇒ 才把这次按键当成普通点击派发给引擎。
--      ⇒ 我们在按下时改什么返回值都晚了 —— App 已经决定「不计时」。
--
--    【铁证 2】为什么官方联想补丁不受影响：**它的联想段输入码是空的**。
--      官方 predictor 走原生 API 建段，不 push_input ⇒ `ctx.input == ""`
--      ⇒ App 认为「没在打码」⇒ 长按计时器正常启动。
--      我们的占位符方案做不到这点（librime-lua 没有 AddSegment），输入码永远是 `›`。
--      ⇒ ★ 想让「第一次长按就起语音」，唯一的路是让联想段**输入码为空**（见 README
--         「关于长按语音」一节），不是在这里改返回值。
--
-- ★★ 前三版被证伪的过程（别再回头）：
--   ① v1「什么都不做 return 2」⇒ 连按空格连续上屏首候选
--      （**放行 ≠ 没人处理**：输入码非空，下游 express_editor 照样确认当前候选）。
--   ② v2「clear_assoc + return 2」⇒ 松手冒一个空格符，长按仍不起。
--   ③ v3「return 0（kRejected）」⇒ 这台定制 tx 引擎上 0 ≡ kNoop，链条照跑满
--      14 个 processor，副作用一个不少。
--
-- ★★ v5 做的是**把损失降到最小**：既然这一下必然起不了语音，就别再留下垃圾字符。
--     · 按下：清掉联想（让输入区空掉）→ **吞掉（return 1）** ⇒ 不上屏任何东西
--     · 松开：同样吞掉 ⇒ 长按松手不会再冒出一个空格符
--     · 结果：**第一次按/长按空格 = 只是把联想收起来**；之后（输入区已空）
--       再长按空格 ⇒ 0.51s 后正常起语音。
--     S76 起assoc_space 开关已删，空格只有一种行为：清联想 + 上屏一个空格符。
local _sp_armed = false      -- 上一次空格是「按下」，在等它的松开
local _sp_press_time = 0     -- 上一次按下的时刻（配对兜底用）

local function handle_assoc_space(ctx, env, key_event)
    -- ★★★ S73 彻底改写：空格**由 lua 自己接管**，不再放行给 App。
    -- -------------------------------------------------------------------
    -- 为什么不能继续「交App」（v6 的做法）：
    --   v6 假设「短按上屏候选交给 App 原生开关『空格上屏联想』」，实测**不成立**，
    --   而且**两种上屏方式不对称**（用户 2026-10-04 实测）：
    --     · 打字后按空格上屏 → 再按空格 = 上屏一个空格符      ✅ 顺
    --     · 打字后点候选上屏 → 再按空格 = **上屏一个无关候选**❌ 多一步
    --   根因（本次才想清楚，S72 的诊断是错的）：
    --     App 按空格时看到输入码里挂着 `›`，就把它当成「你在打码，按空格 = 选词」
    --     ⇒ 它从**我们自建的联想段**里取首候选上屏。那个候选是「词库联想」，
    --     不是用户刚打的词 ⇒ 看起来就是「无关候选」。
    --     而点空格上屏那条路能对上，是因为空格经过 P.func，我们的空格分支
    --     先把联想清掉了，App 取不到候选，才落到 punctuator 打出空格符。
    --     ⇒ 差异不在「按了哪种键」，而在**「按空格时联想段还在不在」**。
    --
    -- ★★ 关键约束：**「按空格」这个动作必须由 lua 做完，不能放行。**
    --   候选是由 T.func 吐的，判据是 `is_ph_input(段上的 input)`；
    --   一旦放行，App 会按「你在打码，按空格 = 选首候选」处理，从我们自建的
    --   联想段里取词上屏 ⇒ 那个词与用户刚打的无关 ⇒ 就是用户报的
    --   「上屏一个无关候选」。这条与用户是「按空格」还是「点候选」无关，
    --   只与**按空格时联想段还在不在**有关，所以两种上屏方式才会不对称。
    --
    -- ★★ S72 的教训（写在这里防止再犯）：
    --   S72 曾在 settle_if_new 里「清残留 › 段」想修这个不对称 ——
    --   方向完全错了。清段 = 自己把联想候选杀掉（T.func 收不到 › 就不吐词），
    --   于是「上屏无关候选」照旧。**那一版等于什么都没改。**
    --   本轮（S73）反过来：主动清段 + lua 自己 commit 空格符，
    --   让两条路归一到同一条可行路径上。
    --
    -- 现在的做法：**保留联想段，只把「空格」这个动作自己做完**。
    --   · 清联想（reset 状态、不清段）→ 让 App 下次触屏能启动长按计时器
    --   · 自己 commit_text(" ") 上屏空格符（吞掉按键，不让下游再处理）
    --   ⇒ 两种上屏方式彻底对称：点候选后按空格 = 直接得到空格符。
-- ★★★ S76：**assoc_space 开关已删除**，空格只剩一种行为。
    -- 【为什么删】用户实测（2026-10-04 13:18）：
    --   切到「收起」档后，按空格的观感是：
    --     第1 下→ 上屏联想候选（正常选词）
    --     第 2 下 → 清掉候选，**什么都不上屏**  ← 没用的一下
    --     第 3 下 → 还是什么都不上屏            ← 没用的一下
    --     第 4 下 → 才上屏一个空格符
    --   也就是说「收起」档把空格变成了**要按两三次才有一个空格**，
    --   而「按空格」本来就是最基础的输入动作，失效掉是纯粹的倒退。
    --   用户原话：「这个逻辑是错的，第二下按空格是无效了，反正也没用，删除即可。」
    --   ⇒ 结论：两档里「收起」那档**没有使用价值**，只有「空格符」档是对的。
    --     合并成一种行为，不做开关。
    --
    -- 【现在按空格一律做这件事】
    --   清掉联想段 + 自己 commit_text(" ") 上屏一个空格符 + 吞掉按键。
    --   与 S73 修好的那条路径完全一致（S73 的 bug 本来就在空格上，
    --   这条路径已真机验证过 5+ 次 commit=true、输入区清空）。

    local rel = false
    pcall(function() rel = is_release(key_event) == true end)
    local now = 0
    pcall(function() now = os.time() end)
    -- ★ 这台机器的 KeyEvent **永远不带 release 标记**（实测 mod=0 / repr=space /
    --   release()=false）⇒ 只能靠「上一次是按下且间隔 ≤1 秒」把这次当成松开。
    local paired = _sp_armed and (now - _sp_press_time) <= 1

    probe(string.format("EV space rel=%s paired=%s in=%q | %s",
        tostring(rel), tostring(paired), ctx.input or "", kdump(key_event)))

    if rel or paired then
        -- 松手：按下那一次已经把空格符上屏了，这里只需清配对标志、吞掉松手，
        -- 避免「松手又触发一次上屏」而多出一个空格。
        _sp_armed = false
        probe("UP -> swallow(1)：空格符已在按下时上屏")
        return 1
    end

    -- ── 按下 ──
    _sp_armed = true
    _sp_press_time = now

    -- ★ S73 定案：**清段 + 自己上屏空格符**。
    --   为什么必须清段：App 在 touch-down 那一刻就决定要不要启动 0.51 秒长按计时器，
    --   判据是「输入区是否为空」（S59~S65 六轮实测铁律）。`›` 挂着 ⇒ 输入区非空
    --   ⇒ **本次触屏永远起不了语音**。清掉它，长按才有可能。
    --   注意这与「点候选上屏」那条路的现状一致（那条路也是清段后 App 才打空格符），
    --   所以两种上屏方式在这里**彻底对称**了。
    --   代价：联想链在这一下断掉（不能无限续链）—— 这是占位符方案的本质限制，
    --   S59~S65 九轮已证明「保留段的输入码为空」在 librime-lua 上做不到
    --   （没有 AddSegment API）。要续链就点候选，别按空格。
    clear_assoc(ctx)

    -- ★ S76：原「收起」档已删（它让空格要按两三次才生效，是倒退）。
    --   现在**一律自己上屏一个空格符**，然后吞掉按键。
    --   ★ 为什么用 commit_text 而不是放行：放行会让下游 punctuator 或
    --     express_editor 继续处理，可能再上一个字符、或把残留段的首候选顶上来
    --     —— 「上屏一个无关候选」正是这么来的（旧病根：App 从联想段取首候选）。
    --   ★ 顺序很重要：**先 commit 再吞**。commit(" ") 是非空提交，
    --     前端收到 commit 事件必重画候选栏 ⇒ 联想词随之消失。
    local ok_c = pcall(function() env.engine:commit_text(" ") end)
    probe(string.format("DOWN commit=%s after=%q -> swallow(1)",
        tostring(ok_c), tostring(ctx.input or "")))
    return 1
end

-- 按键处理前记录「按下这个键就会上屏什么」。
--   · 普通编码段：ctx:get_commit_text() 就是当前高亮候选（空格/回车上屏它）
--   · 联想占位符段：数字键 / 空格 ⇒ 选中的就是 pending_cands 的第 n 条
--   · 普通编码段按数字选词：Lua 拿不到第 n 条，只能留空 ⇒ 交给 commit_history 兜底
-- keycode：
--   · 0x3B(;) / 0x27(') 在本方案里被 Submit_text 劫去上屏第 2 / 第 3 候选，
--     不是当前高亮候选 ⇒ 抓不到，只能留给 commit_history 兜底。
local function capture_pending(ctx, repr, keycode)
    _pend_input, _pend_text, _pend_from_predict = ctx.input or "", nil, false
    if _pend_input == "" then return end


    -- ★ 退格 / Esc 必须排除（真机「删空后冒出 ›」的根因）
    --   退格删掉**最后一个**编码时，输入码同样会「从非空变空」—— 这不巧正是
    --   settle_if_new 路径 B 判「上屏」的判据。于是"删字"被当成"上屏"：
    --     ① 学了一个**根本没上屏**的词（t 的首候选「主」被学了进去）
    --     ② settle_commit 顺势置 need_push ⇒ 占位符 `›` 凭空冒出来
    --   真机表现：打完编码逐个退格删空，最后一个编码删掉后冒出一个 `›`，
    --   再按退格也删不掉、候选栏一直挂着。
    --   ⇒ 退格是"删字符"不是"提交"，压根不该记 pend。Esc 同理。
    if is_backspace(repr, keycode) then return end
    if base_repr(repr) == "escape" then return end

    if repr:match("^%d$") then return end          -- 数字选词：交给 commit_history
    if keycode == 0x3B or keycode == 0x27 then return end
    pcall(function() _pend_text = ctx:get_commit_text() end)
    if not _pend_text or _pend_text == "" then _pend_text = nil end
end

-- -------------------------------------------------------------------
-- P：学习 + 维护联想链 + 推占位符
-- -------------------------------------------------------------------
local P = {}

-- ★ 前向声明：import_assoc 定义在本文件靠后的导出区（约 2865 行），
--   但 P.init 需要在引擎加载时调它做「启动自动导入」。先声明 local，
--   函数体稍后赋值，P.init 里的引用才能正确绑定为 upvalue（否则会编译成全局 nil）。
local import_assoc

function P.init(env)
    _sid = env and env.engine and env.engine.schema and env.engine.schema.schema_id
    pcall(probe_init, env)
    local db = get_db(_sid)
    -- ★ B（2026-10-27）：启动自动导入，补齐联想与调序的不对称。
    --   调序 P.init 已 import_from_file；联想此前只有手动 /lxdr。此处对齐：
    --   启动时若存在 /lxdc 导出的备份，自动合并进当前库（max 合并，幂等）。
    --   无备份 / 失败 / schema 不符一律静默降级，不打断输入。
    pcall(import_assoc, db, _sid)
    --   ★ S71：把 assoc_mode 的**原始返回值**和**解读出的语义**一起打出来。
    --     这两行对照着看，就能一眼确认 S71 的档位反转是否真的修好了：
    --       raw=false ⇒ 语义应为「我们的联想」（占位符路）
    --       raw=true  ⇒ 语义应为「官方+语音」（predictor 空段）
    --     若 raw 与语义对不上，说明设备上的 lua 还是旧版。
    -- ★★★ S80 版本：**恒走 predictor 空段路**（`assoc_pred` 开关已删）。
    --     沙箱实验结论（tools/S80_沙箱实验记录.md）：
    --       空段的唯一载体是 `predictor` 组件，**与 `prediction` 开关无关**。
    --     这三个值是本轮的全部验证抓手，日志里第一行就能看清状态：
    --       smart_assoc    = 我们的联想总开关（开想 / 关想）
    --       prediction     = 联想段里填谁的词（联想词库 / 官方预测）
    --                        ★★ S93 更正：此前这里写的是「predictor 总闸（文案已改
    --                          语音开/语音关）」，**是错的**：
    --                            · 它不是 predictor 的总闸，空段也不依赖它
    --                            · 它与长按空格语音毫无关系
    --                            · 它与 smart_assoc 独立（真机日志 SWAP#643/#667 为证）
    --                          用户实测纠正：「当前开关实测控制的是联想功能」。
    --                          开关文案已同步改为「联想词库 / 官方预测」。
    --       mobile         = 是否移动端（PC 端一律不启用联想）
    if PROBE_ON then
        probe(string.format("smart_assoc=%s prediction=%s mobile=%s",
            tostring(ctx_get_option_safe(env, "smart_assoc")),
            tostring(ctx_get_option_safe(env, "prediction")),
            tostring(is_mobile())))
    end
end

function P.fini(env)
    local sid = env and env.engine and env.engine.schema and env.engine.schema.schema_id
    if sid then db_close(sid) end
    -- ★ S90：引擎卸载时清「联想段」标志。
    --   _G 是进程级的，残留会活过方案切换 / 引擎重建，
    --   让 pair_punct 在新会话里误判「还在联想段」。
    _assoc_ready = false
    mark_assoc_seg(false)
end

-- 上屏结算：学习 + 重算待展示候选
-- text：本次上屏的文本（由 settle_if_new 判定后传进来）
-- from_predict：这次上屏是不是「点了联想候选」
settle_commit = function(ctx, sid, text, from_predict)     -- ★ 上面有前向声明，这里不能再写 local
    local s = state(sid)

    local now = os.time()
    if s.last_time > 0 and (now - s.last_time) > IDLE_BREAK_SEC then
        break_sentence(s)
    end

    if not text or text == "" or is_command_echo(text) then
        if is_command_echo(text) then break_sentence(s) end
        reset_chain()
        return
    end

    pending_cands, pending_hist = nil, nil

    if not has_cjk(text) then
        -- 标点 / 英文 / 数字：一句话结束，不联想
        -- ★ S115（2026-10-11）修订：此处**不再**做 ctx:clear()。
        --   S115-B 曾在这里加「上屏非中文后清 predictor 空段」，但 settle_commit
        --   是从 update_notifier 回调（settle_if_new）里跑的，回调内部 ctx:clear()
        --   是 no-op（沙箱 s83_api 穷举 YCNT=0）⇒ 无效。
        --   真正的修复见 P.func 空段档「字母键清联想」（按键处理路径里 clear 有效）。
        break_sentence(s)
        return
    end

    -- -----------------------------------------------------------------
    -- ★ 断句判据（决定「上下文」能不能接着用）
    -- 为什么这三条必须存在：实测如果不断句，用户打完一句「今天天气好像有点冷」后
    --   没打标点就接着打下一句，模块会把「上一句最后一个字 → 下一句第一个词」
    --   当成真实接续学进去 —— 库里于是出现 冷→今天 / 冷→早晨 / 冷→继续 这类
    --   **跨句噪声**。之后逐级联想的末级（上下文尾部 4 字「像有点冷」）就会把这些
    --   词翻出来，而且因为它们是"历史候选"，会排在固定候选**之前**，看起来非常突兀。
    --   （实测复现：点完「有点冷」后候选 = 今天 / 嘴里 / 今天天气 / 若冰霜 / 却水 …）
    -- -----------------------------------------------------------------

    -- 判据一「联想链被放弃」：这句里用户**点过**联想（_chained），
    --   但这一次是**手动打字**上屏 ⇒ 他不想接着联想了、要另起一句。
    --   ⚠ 反过来不判：没点过联想的纯手动连续输入（今天→天气→好像…）是句内，
    --     绝不能断，否则「今天→天气」根本学不到。
    if _chained and not from_predict then
        dbg("[brk] 判据一 放弃联想链 上屏=%s", tostring(text))
        break_sentence(s)
    end

    -- 判据二「重复起点」：这次上屏的词 == 当前句子的**句首词**，且不是点联想来的
    --   ⇒ 几乎可以肯定用户是在重打一句（打完「…有点冷」又打「今天」）。
    --   这条兜住判据一漏掉的「整句纯手打、没跑过联想链」的情况。
    if not from_predict and #s.toks > 0 and s.toks[1] == text then
        dbg("[brk] 判据二 重复起点 上屏=%s 句首=%s", tostring(text), tostring(s.toks[1]))
        break_sentence(s)
    end

    -- 判据四「一句话写太长了」：正常说话一句话也就几个词 / 十来个字。
    --   还在往下写，十有八九是没打标点就写了下一句 —— 这正是跨句污染的入口。
    -- ★ 必须在 learn_token **之前**断：这样「句末词 → 下一句首词」根本不会被学进库。
    --     判据一只能挡"点过联想"的情况，纯手打的长句以前是漏的
    --     （实测：打完「打过一遍后再打字时候」接着打「继续」，候→继续 就被学进去了）。
    --   ⚠ 这只是**限制污染链的长度**（不让它一句接一句无限串下去），不是精确断句；
    --     要精确，请在句末打个标点，或用 `/lxdj` 手动断句。
    if #s.toks >= MAX_SENTENCE_TOKENS or #s.chars >= MAX_CONTEXT_LEN then
        dbg("[brk] 判据四 句子过长 toks=%d chars=%d 上屏=%s",
            #s.toks, #s.chars, tostring(text))
        break_sentence(s)
    end

    learn_token(sid, text)
    -- ★★★★★ S84：结算成功后立刻存上下文快照。
    --   必须在 learn_token **之后** —— 那时 chars 才是「刚上屏这个词之后」的
    --   完整上下文，早一行存就少算了刚打的那个词。
    --   这个快照是空段轮次唯一的上下文来源（那时 state.toks 恒为空，
    --   真机 190/190、沙箱 37/37，见 _last_ctx 声明处的说明）。
    do
        local ok2, c2 = pcall(context_of, sid)
        if ok2 and c2 and c2 ~= "" then
            _last_ctx = c2
            if PROBE_ON then
                probe("S84 存快照 ctx=" .. tostring(c2))
            end
        end
    end
    dbg("[settle] 上屏=%s from_predict=%s pc=%d chained=%s ctx=%s",
        tostring(text), tostring(from_predict), predict_count,
        tostring(_chained), tostring(context_of(sid)))

    if from_predict then
        predict_count = predict_count + 1
        _chained = true
    else
        predict_count = 1
    end

    -- 判据三「联想链跑满」：用户一路点到底了 ⇒ 这句话到此为止。
    --   不断句的话，下一句的首词又会挂到这一句的尾巴上（判据一只能挡"点过联想"的情况，
    --   而这里是链自己跑满的）。
    if predict_count > MAX_PREDICTIONS then
        dbg("[brk] 判据三 联想链跑满 pc=%d", predict_count)
        break_sentence(s)
        return
    end

    local list, only_hist = build_candidates(sid)
    if not list then
        dbg("[settle] build_candidates=nil -> 断链")
        reset_chain()
        return
    end
    dbg("[settle] cands=%s", table.concat(list, " "))
    probe(string.format("SETTLE cands=%d 首=%s",
                        #list, tostring(list[1])))
    pending_cands = list
    pending_hist = only_hist
    _last_offered = list
    -- ★ S65：置「本轮有联想数据」的时机标记（详见变量声明处的说明）
    _assoc_ready = true
    -- （S96 曾在此解除 `_assoc_user_cleared`，S97 已随 B4 一并撤除。）
    -- ★ S90：同步置「联想段」标志（与 _assoc_ready 严格成对）
    mark_assoc_seg(true)
    -- ★ S90：同步置「当前处于联想段」跨文件标志。
    --   pair_punct / super_sequence 靠它豁免（联想段上按标点只出标点、不带联想词）。
    probe(string.format("READY=1 cands=%d 首=%s", #list, tostring(list[1])))

    -- ★★★ S83：**删除** S80 的 refresh 与 S81/S82 的空 commit_text("")。
    --
    -- 【为什么删——librime 源码 + 沙箱穷举双重定案，三轮修复全部作废】
    --   S80 我写的是"refresh 会触发翻译层重算，T.func 会带着_pending_cands 再跑一次"。
    --   S81 补了空 commit_text("")，S82 又把 capture_pending 提前。
    --   **三轮都无效**，用户三次反馈"跟之前一样"。现在查了 librime 源码才看清：
    --
    --   ❶ refresh_non_confirmed_composition() 在**这个时刻**必然是空操作：
    --       bool Context::RefreshNonConfirmedComposition() {
    --         if (ClearNonConfirmedComposition()) { update_notifier_(this); return true; }
    --         return false;          // ★ 什么都没清 ⇒ 连通知都不发
    --       }
    --       而 settle_commit 是从 update_notifier 回调里跑的 ⇒ 那一刻 composition
    --       早就被上屏清空了 ⇒ ClearNonConfirmedComposition 返回 false ⇒ 整个函数
    --       直接 return，**翻译层压根不会被重跑**。
    --       ⚠ 我们日志里那句 `refresh=true` 是 pcall 没报错而已，**不代表引擎重算**——
    --         这个探针骗了 S80 和 S81 两轮。判断依据必须换。
    --
    --   ❷ 空 commit_text("") 同样无效：
    --       void ConcreteEngine::CommitText(string text) {
    --         context_->commit_history().Push(CommitRecord{"raw", text});
    --         FormatText(&text); sink_(text);   // ★ 只是往 App 推一个空串
    --       }
    --       不重置 composition、不调 update_notifier ⇒ T.func 一次都不会被再调用。
    --
    --   ❸ 沙箱穷举 5 个入口（tools/sandbox_s83_api.py），数 T.func 的 yield 次数：
    --       A 只 refresh                → YCNT=0
    --       B refresh + 空 commit      → YCNT=0   ← S81/S82 现状
    --       D push_input + pop_input   → YCNT=0
    --       E commit_text(" ")         → YCNT=0
    --       F ctx:clear()              → YCNT=0
    --       **五个全部为 0**。在 update 回调内部重入引擎是徒劳的——
    --         此刻正在这一轮update 里，再怎么折腾 composition 都不会重新Translate。
    --
    -- 【那正确的做法是什么】——不在结算后补救，**在空段那一轮就地补算**。
    --   真机 S82 日志第 24~30 行（唯一有活动的会话，16:24:22）把时序记得很清楚：
    --       T.func in="" pend=false ready=false seg=[0,0] mode=ph   ← ① 空段先到
    --       T.func 空段待补算 toks=0 命中=false                      ← ② 无历史，放弃
    --       T.func SKIP 输入码="" 想要空段=true 时机=false
    --       SETTLE cands=9 首=更新                                   ← ③ 词在这儿才算出来
    --       READY=1 / 结算后重拉候选 / REGAIN 补算
    --   ⇒ **空段(①) 早于 结算(③)**，这就是三轮都接不上的时序错位。
    --   而 mode 也印证了：第 24 行是 mode=ph，第 32 行（下一个按键）才 mode=pred。
    --
    --   ⇒ 修法：既然结算必然晚于建段，就**别等结算**。
    --     T.func 看到 input=="" 且这一句已经上屏过词（state.toks 非空）时，
    --     直接自己 build_candidates 出来 yield。build_candidates 是纯函数
    --     （只依赖 state 的历史），幂等、可重入，这里调用完全安全。
    --     真正的修复在 T.func 里（见 is_pred_seg 那段的 S83 注释）。
    --
    -- 【为什么以前没走通这条路】
    --   S60/S65 试过"就地补算"，条件是 `not _assoc_ready and has_hist`，
    --   而真机日志 `空段待补算 ... toks=0 命中=false` 出现 190 次、
    --   `EAGER` 出现 **0 次** ⇒ 那条路要求 `_assoc_ready` 为假，
    --   但真机上这 190 次 has_hist 全为 false（toks=0），根本进不去。
    --   ⇒ S83 去掉 _assoc_ready 这个前置条件：**只看有没有历史**。
    if PROBE_ON then
        probe(string.format("READY=1 后不补救 cands=%d（等 T.func 就地补算）",
            #list))
    end
end

-- -------------------------------------------------------------------
-- 上屏检测（三判据）
-- ★ 必须定义在 P.func 之前：P.func 会直接调用它，Lua 的 local 函数
--     没有前向声明的话值就是 nil。
--   三判据：① size 变了 ② back().text 变了 ③ 输入码从非空变空
--   （③ 用来覆盖「提交队列满导致 size/back 都不变」和「连打同一个词」）
-- 幂等：每条上屏只结算一次（两条路径互相兜底，用 _just_learned 去重）。
local function settle_if_new(ctx, sid)
    if not ctx or not sid then return end
    if _suppress_settle then
        _suppress_settle = false
        dbg("[chk] 跳过：这次「输入码变空」是我们自己清联想造成的，不是上屏")
        return
    end
    local size, back = read_commit(ctx)
    local input = ctx.input or ""
    local s = state(sid)

    local text, from_predict = nil, false

    -- 【路径 A】commit_history 刷新了 ⇒ back 就是刚上屏的文本（最可靠）。
    if back ~= nil and ((size ~= s.size) or (back ~= s.back)) then
        s.size, s.back = size, back
        if back == _just_learned then
            -- 这条上屏已经由【路径 B】学过了，别学第二遍
            _just_learned = nil
            dbg("[chk] A 跳过重复 %s", tostring(back))
        else
            text = back
            -- 是不是点了联想候选：看它是不是上次展示过的
            if _last_offered then
                for _, w in ipairs(_last_offered) do
                    if w == text then from_predict = true; break end
                end
            end
        end
    end

    -- 【路径 B】输入码「从非空变空」且我们在按键前记过"按下就会上屏的文本"
    --   ⇒ 就是这次上屏的文本。
    -- ★ 为什么需要路径 B：实测 commit_history 在本 librime 上**滞后一个按键** ——
    --     上屏后紧接着的 update_notifier 里读到的还是上一条，要等下一个按键才刷新；
    --     而 ctx.commit_notifier 干脆不触发（实测一行日志都没有）。
    --     只用路径 A 的话，联想候选会永远慢一拍（显示的是上上词的后续）。
    if not text and _pend_text and _pend_input and _pend_input ~= "" and input == "" then
        text = _pend_text
        from_predict = _pend_from_predict
        _just_learned = text
    end
    -- ★ 只有在「输入码已经空了」时才丢弃待上屏文本。
    --   输入码还非空就丢的话，Submit_text 清串那一次的 update 上已经没值了。
    if input == "" then _pend_text = nil end

    dbg("[chk] input=%q size=%s/%s back=%s/%s pend=%s -> %s",
        input, tostring(size), tostring(s.size), tostring(back), tostring(s.back),
        tostring(_pend_text), tostring(text))

    _prev_input = input

    if text then pcall(settle_commit, ctx, sid, text, from_predict) end
end

local function update_cb(ctx, sid)
    local input = ctx.input or ""
    dbg("[upd] input=%q pc=%d", input, predict_count)

    -- 【S118-2 清理】原此处有一段「need_push 且刚清过 ⇒ 作废 need_push」的逻辑，
    --   用于防止占位符(›)被重新推出来。占位符机制(S80)已彻底移除，该段随之删除，
    --   仅保留此说明作为历史。

    -- 开关已关 / PC 端被平台门控 ⇒ 不推占位符；已经推了的要赶紧收回去
    if not enabled(ctx) then
        -- S88：这里原先还有一句 `mark_predicting(ctx, false)`，
        --   用于在关想时清掉「长按标志」，理由是「标志仍为真会把空格一直扣住」。
        --   该标志连同 Submit_text 的空格豁免已在 S88 一并删除，这句也就不再需要。
        -- ★ S115（2026-10-11）修订：此处**不再**做 ctx:clear()。
        --   历史：S115-A 曾在这里加「input=="" 时无条件清 composition」想清
        --   predictor 空段残留，但沙箱穷举（tools/sandbox_s83_api.py）早已证明
        --   update_notifier 回调内部 ctx:clear() 是 no-op（YCNT=0）——
        --   本函数正是 update 回调，clear 无效，反而引入 _pc_clearing 防重入复杂度。
        --   PC 端（非移动端）predictor 空段残留的真正修复见 P.func 空段档
        --   的「字母键清联想」分支（S115 核心，按键处理路径里 clear 才是有效的）。
        return
    end

    -- ① 建段：★ S80 **恒走空段路**，什么都不做。
    --   predictor 原生建段，它不 push_input，输入码天然为空
    --   ⇒ App 才肯启动长按计时器（S52铁律）⇒ 这是长按空格唤起语音的唯一前提。
    --
    -- 【为什么不再二选一】（S80 沙箱实验结论，tools/S80_沙箱实验记录.md）
    --   S79 之前这里是「占位符档 push_input("›") / 空段档不推」二选一，
    --   由 `assoc_pred` 开关控制。沙箱证明**二选一的前提是错的**：
    --     · predictor 在场就有空段（实验 A/C/D）
    --     · 我们的候选可以挂在那个空段上由 T.func 吐出（S79 已实证）
    --   ⇒ 两件事不互斥，没必要做这个开关。
    --
    --   ⚠ 旧路`push_input("›")` 已**完全移除**（不只是不用）：
    --     它输入区恒非空 ⇒ 长按语音永远唤不起来（S52/S59 双重铁证），
    --     留着只会让人以为还能切回去。

    -- ★★★ S79 恢复 S65 的「REGAIN 补算」兜底
    --   场景（S64 真机取证发现）：predictor 把空段建好了，但我们的 pending_cands
    --   在它建段**之前**就被 reset_chain 清掉了 ⇒ T.func 无词可吐，
    --   用户看到的是 predictor 自己的官方预测（S64 当时评价为「随机联想」）。
    --   治法：时机还在（_assoc_ready）而数据没了，就按历史**重算一次**。
    --   build_candidates 是纯函数（只依赖 state(sid) 的历史）⇒ 幂等、可重入，
    --   在这里重算安全。
    --
    -- ★★ S80 沙箱补的一条更早的竞态（tools/S80_沙箱实验记录.md 端到端段）：
    --   沙箱日志实测顺序是
    --       T.func in="" 时机=false        ← predictor 已建空段，但我们还没结算
    --       P 空段放行 kc=32 in=          ← 空格已放行（空段已就位）
    --       SETTLE cands=7 / READY=1       ← 结算才发生，**晚于**建段
    --   ⇒ 上一段的条件 `_assoc_ready` 为真时补算**救不了这一种**，
    --     因为那一刻时机还没置位。
    --   治法：空段已存在（input=="" 且引擎已把段建好）时，
    --     若本会话**已经上屏过词**（有历史可联想）就直接补算并置位，
    --     不等 settle_commit。
    --   为什么要紧：这一刻正是用户按下空格、长按语音计时器启动的时刻，
    --   若此刻候选栏挂的是 predictor 的官方词，用户看到的就不是我们的联想。
    -- ★ S97：S96 曾在此加「用户主动收过联想 ⇒ 本轮不许补算」的门
    --   （`_assoc_user_cleared`，B4 退格拦截的配套），已随 B4 一并撤除，
    --   恢复 S94 行为（clear_assoc 后允许 EAGER/REGAIN 兜底补算）。
    if use_pred_segment() and input == "" and not pending_cands then
        -- ★ 判据用 `state(_sid).toks`（已上屏的 token 序列）——
        --   ⚠ state() 结构里**没有** `.history` 字段，别想当然写。
        --   ⚠ 必须用模块级 `_sid`（T.init 赋值），局部 sid 在这里可能是 nil。
        local has_hist = false
        pcall(function()
            local s = state(_sid)
            has_hist = (s ~= nil and s.toks ~= nil and #s.toks > 0)
        end)
        if not _assoc_ready and has_hist then
            local list = build_candidates(sid)
            if list and #list > 0 then
                pending_cands = list
                _last_offered = list
                _assoc_ready = true            -- ★ 顺手置位，让 T.func 能认这一轮
                -- ★ S90：同步置「联想段」标志（与 _assoc_ready 严格成对）
                mark_assoc_seg(true)
                probe(string.format("EAGER 抢在结算前补算 cands=%d 首=%s",
                    #list, tostring(list[1])))
                pcall(function() ctx:refresh_non_confirmed_composition() end)
            else
                probe("EAGER 无可补算（确实没历史）")
            end
        end
        if _assoc_ready and not pending_cands then
            local list = build_candidates(sid)
            if list and #list > 0 then
                pending_cands = list
                _last_offered = list
                probe(string.format("REGAIN 补算 cands=%d 首=%s", #list, tostring(list[1])))
                -- 补算后要通知前端重画：空段上已有候选，得刷一次
                pcall(function() ctx:refresh_non_confirmed_composition() end)
                return
            else
                -- 确实没有可联想的内容（库里查不到）⇒ 收掉时机，
                -- 别让 predictor 的官方预测挂出来冒充我们的联想。
                _assoc_ready = false
                -- ★ S90：同步清「联想段」标志（与 _assoc_ready 严格成对）
                mark_assoc_seg(false)
                probe("REGAIN 无可补算⇒ 收掉时机")
            end
        end
    end

    -- ② 用户开始打正常字 ⇒ 清掉占位符，把真输入码还回去

    -- ③ 空段档下用户开始打真字（输入码不是空、也不含占位符）
    --   ⇒ 说明 predictor 还没建段，或者段已被消费。此时不必清段，
    --   只要把「时机」留着，等下一轮空段建好时 T.func/REGAIN 还能用。
    --   `_assoc_ready` 故意**不清** —— 这正是 S65 那次修判定的要点：
    --   predictor 建段发生在「稍后某次context 更新」，比结算晚得多；
    --   若这里把时机清掉，等它真建段时我们已经没有数据可给了（S64 的失败）。
    if use_pred_segment() and input ~= "" then
        if PROBE_ON then
            probe(string.format("UP 空段档收到真字in=%q 保留时机 ready=%s our_cand=%s",
                tostring(input), tostring(_assoc_ready), tostring(use_our_candidates())))
        end
        return
    end
end

function P.func(key_event, env)
    local ctx = env.engine.context
    if not ctx then return 2 end
    -- ★ S90 探针：先记下「进本函数时是否处于联想段」。
    --   必须在任何 clear_assoc 之前取 —— P.func 自己会清标志，
    --   等 P.func 返回后 pair_punct 再看就已经是 false 了，
    --   而这恰恰是「清空因为时序没生效」时唯一还留有信息的一拍。
    _was_assoc_seg = _G.__touchwb_assoc_seg and true or false
    _engine = env.engine              -- clear_assoc 的备用刷新手段要用
    _suppress_settle = false         -- 上一次按键若没消费掉，别带到这一次
    _ctx = ctx                       -- 给 fixed_on() 读开关用
    local sid = env.engine and env.engine.schema and env.engine.schema.schema_id
    if sid then _sid = sid end

    -- ★★★ S82：实时开关快照（每 6 个按键打一行，不是每次都打）。
    -- 【为什么必须加这个 —— S81 教训】
    --   S81 我只能靠 P.init 的水印判断开关状态，而水印**只在引擎加载那一刻写一次**，
    --   之后切开关不重写 ⇒ 拿它判断「用户切了开关之后是什么状态」必然出错。
    --   这次用户明确报告「开想没词、关想才有官方词，开关是反的」，
    --   而水印里 smart_assoc / prediction 永远同值（117 次只有 3 种组合，
    --   S80 段内甚至只有 (true,true) 与 (false,false)）
    --   ⇒ 强烈指向 **App 把这两个开关绑定同开同关**。
    --   但水印是加载时刻的快照，**证不了「用户切完之后」的状态**。
    --   这一行按真实按键时刻打印，日志里就能直接看到：
    --     · 用户切到「开想」后，smart_assoc 到底是 true 还是 false
    --     · prediction 是否被联动
    --     · 引擎认为的 enabled() 与开关的对应关系
    _probe_tick = (_probe_tick or 0) + 1
    if PROBE_ON and (_probe_tick % 6 == 1) then
        local sa = ctx_get_option_safe(env, "smart_assoc")
        local pd = ctx_get_option_safe(env, "prediction")
        local af = ctx_get_option_safe(env, "assoc_fixed")
        local kcx = -1
        pcall(function() kcx = key_event.keycode end)
        -- ★ S95 探针文案同步改名：
        --   smart_assoc：智能联想/官方联想 ⇒ **方案联想 / 应用联想**
        --     （用户 S95 原话：「prediction 是应用补丁的联想总开关，
        --       我们的 smart_assoc 是方案自己带的 ⇒ 方案联想 = 我们的，
        --       应用联想 = 应用补丁那份的。」）
        --   prediction ：**总联想关 / 总联想开**（S95 恢复成可切的总闸，
        --     用户原话：「如果要删除 prediction 只会让方案使用者多一道
        --     流程开启智能联想，所以我们要恢复 prediction 的开关功能，
        --     这样部署后就直接可用智能联想。」）
        --     ⚠ S101 改名：原「关联想 / 开联想」⇒「总联想关 / 总联想开」。
        --       语义未变（仍是可切总闸），只是名字；探针文案必须同步，
        --       否则日志里打印的档位与 UI 对不上（本项目最忌讳的一种错）。
        --   ★ 这行是核对「前置条件是否成立」的第一道闸：先看 sa/pd 显示的档位，
        --     再看下面的产出，顺序反了会整轮白跑（老教训，见 MEMORY.md）。
        probe(string.format(
            "SWAP#%03d sa=%s⇒显示[%s] pd=%s⇒显示[%s] af=%s enabled=%s mobile=%s kc=%s",
            _probe_tick, tostring(sa), (sa == "true" and "方案联想" or "应用联想"),
            tostring(pd), (pd == "true" and "总联想开" or "总联想关"),
            tostring(af), tostring(enabled(ctx)), tostring(is_mobile()), tostring(kcx)))
    end

    -- ★★★ S91：联想段状态改为「现场判定」+ 联想段下滑数字直接上屏 ★★★
    --
    -- 【这一段为什么必须放在 P.func 的最前面（not enabled 早退之前）】
    --   ① 联想段状态必须对下游两个读者可见，而本函数是唯一的写入点：
    --      processors 链顺序是
    --        smart_assoc*P → Submit_text → super_tips → super_sequence*P → pair_punct
    --      ⇒ 必须在 super_sequence / pair_punct 之前算好。
    --   ② 关想（enabled=false）时官方 predictor 照样建空段、照样有联想候选栏，
    --      下滑数字同样应该是「上屏数字」而不是「顶候选」
    --      ⇒ 必须在 `if not enabled(ctx) then return 2 end` 之前。
    --
    -- 【★★★ 为什么必须从「锁存标志」改成「现场判定」—— 这就是本轮的真根因 ★★★】
    --   S90 的 `_G.__touchwb_assoc_seg` 是**锁存**的：置位靠 mark_assoc_seg(true)，
    --   清除靠 clear_assoc。而 clear_assoc 的**全部**调用点都在本文件
    --   1444/1445（空格）、2189（回车）、2206（退格）、2212（Esc）、
    --   2220（数字）、2232（其它键）——
    --   而这六处**全部位于第 2131 行 `if not is_ph_input(...) then return 2 end` 之后**。
    --   S80 起 predictor 空段路的输入码**永远不是占位符** ⇒ is_ph_input 恒 false
    --   ⇒ `not is_ph_input` 恒 true ⇒ 2137 行无条件 return 2
    --   ⇒ 后面那一整段（含 clear_assoc、含「数字直接 commit_text」）全是**死代码**。
    --   ⇒ 标志一旦置上就再也清不掉 ⇒ super_sequence 永远读到 true
    --   ⇒ 正常打字时的下滑数字也被 `return kNoop` 放行 ⇒ 一路落到 selector
    --   ⇒ selector 的语义是「选中第 N 个候选」⇒ **顶候选上屏**。
    --   这就是「情况 1（正常输入编码）调序也坏了」的确切机制。
    --   ⇒ 治法不是「再补几个清除点」（那是打补丁，漏一个就再静默回归一次），
    --     而是**不再依赖锁存**：每次按键开头按真实状态重算。
    --   判据：输入码为空（predictor 空段的唯一特征，S60 起成立）且候选栏亮着。
    --     · 情况 1（正常输入编码）：输入码非空 ⇒ 恒 false
    --       （注意这一条只看输入码，**不依赖 has_menu**，最稳）
    --     · 情况 2（上屏后的联想候选）：输入码为空且有候选 ⇒ true
    --   ★ 顺带把「联想段按数字该由谁 commit」也补在这里 ——
    --     以前指望下游处理，其实那个 commit 就在上面那段死代码里（2220 行）。
    local _live_in = ctx.input or ""
    local _live_menu = false
    pcall(function() _live_menu = ctx:has_menu() end)
    local _live_assoc = (_live_in == "") and _live_menu
    mark_assoc_seg(_live_assoc)

    if PROBE_ON and (_probe_tick % 6 == 1) then
        probe(string.format(
            "S91 联想段现场判定 in=%q menu=%s ⇒ 标志=%s",
            _live_in, tostring(_live_menu), tostring(_live_assoc)))
    end

    -- 情况 2：联想候选栏上按数字 = 用户想输入这个数字，**不是**选第 N 个候选。
    --   必须在这里自己 commit：放行（kNoop）会让键一路落到 selector，
    --   而 selector 的语义就是「选中第 N 个候选」⇒ 联想词被顶上屏。
    if _live_assoc and is_mobile() then
        local _kd = -1
        pcall(function() _kd = key_event.keycode end)
        local _dig = nil
        if _kd ~= nil and _kd >= 0x30 and _kd <= 0x39 then
            _dig = string.char(_kd)
        end
        if not _dig then
            local _rp = ""
            pcall(function() _rp = tostring(key_event:repr()) end)
            _dig = _rp:match("^KP_([0-9])$") or _rp:match("^([0-9])$")
        end
        if _dig then
            pcall(function() ctx:clear() end)
            mark_assoc_seg(false)
            pcall(function() env.engine:commit_text(_dig) end)
            if PROBE_ON then
                probe(string.format("S91 联想段数字直上屏 dig=%s（不顶候选）", tostring(_dig)))
            end
            return 1
        end
    end

    --   现象：打完编码按退格逐个删除，删到最后一个编码时出现一个 `›`，再按退格
    --   也删不掉、候选栏一直挂着。
    --   成因：need_push 是模块级变量，只在「settle_commit 置 true → 紧随其后的
    --   update_cb 且 input=='' 时消费」才算正常配对。可一旦那一次 update 时输入码
    --   还非空（比如用户上屏后**立刻开始打下一个词**，或者上一次上屏是靠下一个
    --   按键的 settle_if_new 路径 A 补结算的），need_push 就**留在 true 上跨了
    --   按键周期**。之后用户把新编码一个个删空 ⇒ update_cb 看到
    --   `need_push and input==''` ⇒ 把占位符推出来 ⇒ `›` 凭空冒出来删不掉。
    --   ⇒ 治法：need_push 只在**同一个按键周期内**有效。每次按键进来先作废。
    --     （正常路径不受影响：置位与消费都在同一次 update 回调内完成。）

    -- ★ 属性自愈：每一次按键都先把「联想标记」校订到与真实状态一致 ★
    --   清掉，而联想段有很多**不会走 clear_assoc 的消失路径** —— 最典型的就是用户
    --   接着打下一个词的**字母**（字母属于 keep key，原代码特意不清联想，于是占位符
    --   留在输入码里、标记也还挂着 "1"）。
    --   残留之后有两个恶果：
    --     ① Submit_text 看见标记 ⇒ 空格被豁免 ⇒ **空格上不了屏**
    --        （用户描述："第五码筛选后空格不能上屏"、"不足 4 码偶尔空格不能上屏"
    --          —— 之所以是"偶尔"，正是取决于前面有没有出现过联想）
    --     ② 本模块看见标记 ⇒ 误判"还在联想态" ⇒ 退格被 return 1 吞掉
    --        （用户描述："按退格无作用"）
    --   ⇒ 唯一的权威判据只有「输入码是不是联想占位符」，这里就用它来校正。
    -- ★ S64：新路（predictor 空段）下输入码**永远**不是占位符（没有 ›），
    --   这句会每个按键都执行、把共享标记清掉 ⇒ Submit_text / pair_punct /
    --   super_sequence 三处都读它，会连带影响它们的行为。
    --   而新路下我们本来就不推占位符、也不靠标记分流 ⇒ 直接跳过。
    -- ★ S80：这段门控**整体删除**。
    --   S79 时是 `if not use_pred_segment() and not is_ph_input(...)`，
    --   S80 起 use_pred_segment 恒 true ⇒ 该条件恒假 ⇒ 这段永不执行。
    --   理由依然成立（S64 实证）：空段路输入码永远不是占位符，
    --   共享标记不该被每个按键都清掉（Submit_text / pair_punct /
    --   super_sequence 三处都读它）。
    --   ⇒ 保留一个恒假的分支只会让人以为这里还有档位可切。
    --
    --   ★ 注意：**T.func 的判据不依赖这个标记**，
    --     它用 `_assoc_ready`（模块私有，reset_chain 故意不清）—— 见 T.func。

    -- ★★★ S82：`_hooked` 必须**按会话**判定，不能是模块级一次性。
    --
    -- 【为什么 —— 第二个让「开关像反了」的隐藏 bug】
    --   `_hooked` 是模块级 local，**一旦被某次 P.func 置 true 就再也不会重连**。
    --   而 librime 每次切换方案 / App 重连都会**新建context**，
    --   新context 的 `update_notifier` 是一条**全新的信号连接**，
    --   我们却因为 `_hooked==true` 而跳过 connect
    --   ⇒ **新会话里 settle_if_new 永远不会被调用**
    --   ⇒ 不学习 ⇒ toks=0 ⇒ 没有联想。
    --   真机日志里 `smart_assoc=true` 的会话 `SETTLE=0`、一次 `UP` 都没有，
    --   与此完全吻合（那次会话恰好排在一次已连过的会话之后）。
    --
    -- 【治法】改成「按 (ctx, engine) 身份记忆」，同一会话只连一次，
    --   换会话重新连。这样既避免重复 connect（重复会把同一次上屏结算两遍），
    --   又不会因为跨会话而漏连。
    local hook_key = tostring(ctx) .. "|" .. tostring(env.engine)
    if _hooked_key ~= hook_key then
        _hooked_key = hook_key
        _hooked = true
        pcall(function()
            ctx.update_notifier:connect(function(c)
                pcall(function()
                    local s = env.engine and env.engine.schema and env.engine.schema.schema_id
                    -- 先结算上屏（可能置 need_push），再处理占位符
                    if enabled(c) then settle_if_new(c, s) end
                    update_cb(c, s)
                end)
            end)
        end)
    end

    -- ★★★ S82：`capture_pending` 必须提到**所有 return 2 之前**。
    --
    -- 【为什么 —— 这是「开关是反的」的真正原因，真机日志铁证】
    --   原结构（P.func 内，自上而下）：
    --       1884if not enabled(ctx) then ... return 2 end   ← 开关「关」走这里
    --       1926  if not is_ph_input(ctx.input) then return 2 end  ← 开关「开」+空段走这里
    --       1940  capture_pending(ctx, repr, kc)← ★ 永远到不了！
    --   空段路（S80 起 predictor 建段）下 `is_ph_input` **恒为 false**，
    --   ⇒ 开关**开着**的时候每个按键都在 1926 行 return 2，
    --     而 capture_pending（记「按下会上屏什么」）在它**后面** ⇒ 一次都不执行。
    --   ⇒ 结算的两条路径同时断掉：
    --       路径 A 依赖 commit_history 滞后一个按键（实测），
    --       路径 B 依赖 _pend_text（capture_pending 的产物）—— 也断了
    --   ⇒ 不学习 ⇒ state(sid).toks 恒为 0 ⇒ **没有我们的联想**。
    --
    --   而开关**关**的时候走 1884 提前return，反而**不会**在这里断 ——
    --   所以现象看起来就是「开了没用、关了才有」，也就是用户说的「开关是反的」。
    --   ★ 实测会话级统计（真机 S80 段）完全对上：
    --       sa=true  的会话：P行=0   SETTLE=0
    --       sa=false 的会话：P行=112 SETTLE=13
    --     ⇒ 不是开关定义反了，是**开关开着时我们的按键流程根本没启动**。
    --     （沙箱 SWAP 探针也印证映射本身是对的：sa=true⇒显示[开想] enabled=true）
    --
    -- 【为什么提到这里安全】
    --   capture_pending 只做一件事：把「这次按下即将上屏的文本」记进 _pend_text。
    --   它是**纯读取 + 记录**，不吞键、不改输入码、不推占位符，
    --   所以在任何 return 之前执行都不改变按键行为。
    --   ⚠ 原本它上面有 `local repr = tostring(key_event:repr())`，
    --     提前后要一并把 repr/kc 的取值搬过来。
    local repr_s, kc_s = "", -1
    pcall(function() repr_s = tostring(key_event:repr()) end)
    pcall(function() kc_s = key_event.keycode end)
    capture_pending(ctx, repr_s, kc_s)

    -- ★ 不开（或 PC 端被平台门控挡掉）时：不学习、不推占位符，直接放行。
    --   顺手清掉可能残留的联想段（比如用户在菜单里刚把开关切到「关想」）。
    if not enabled(ctx) then
        -- ★★★ S116（2026-10-11）：PC 端「退格删字后打单字带一个我字」修复。
        --   PC 端 enabled()=false（is_mobile()=false 门控），我们的联想完全不工作，
        --   但 predictor 组件（processors 第一位）独立建空段、predict_translator
        --   产出官方联想候选（首词常是「我」）。上屏英文/退格后该空段候选残留，
        --   用户打下一个编码字母时被顶出上屏 ⇒ 「先正常上屏候选，后面跟个我字」。
        --   判据：输入码为空（predictor 空段）+ 按下编码字母键（a-z/A-Z）。
        --   PC 端不需要任何联想，空段候选在这里就是要清的对象，无需 _assoc_ready。
        --   ⚠ 在按键处理路径里 ctx:clear() 才有效（update 回调内是 no-op，见 S83）。
        local _pckc = -1
        pcall(function() _pckc = key_event.keycode end)
        local _pcshift = false
        pcall(function() _pcshift = key_event:shift() end)
        -- 只认「无 Shift 的小写编码字母」（大写是 ascii 上屏，不该清）
        if (ctx.input or "") == "" and (_pckc >= 0x61 and _pckc <= 0x7A) and not _pcshift then
            clear_assoc(ctx)
            if PROBE_ON then
                probe("S116 PC 空段打小写编码清残留 kc=" .. tostring(_pckc))
            end
        end
        return 2
    end

    -- ===================================================================
    -- ★★★ S79 恢复 S64「predictor 空段 ⇒ 按键流完整放行」的极简路径
    -- -------------------------------------------------------------------
    -- 【为什么必须放行】铁证（S64 真机取证，22:08 vs 20:0x 对照）：
    --   | 时时          | smart_assoc | Predictor::OnContextUpdate | 联想 |
    --   | 20:0x S59 成功 |     0       |**251 次**                 | 有   |
    --   | 22:08 S64 失败 |     1       |   **3 次**                 | 无   |
    --   唯一差异就是 `smart_assoc` 是否开启。机制：
    --     smart_assoc=0 ⇒ P.func 在 `if not enabled(ctx) then return 2 end`
    --                     直接放行 ⇒ 按键流完整交给 predictor ⇒ 它建出空段
    --     smart_assoc=1 ⇒ 下面这一大段按键拦截会**抢在 context 更新之前动手**
    --                     （capture_pending 会清空状态）
    --                     ⇒ predictor 拿不到完整按键流 ⇒ 饿死
    --   S75 更正过一个重要误判：当时以为「本方案 processors 里根本没有 predictor，
    --   让路也没关系」——**那是错的**。predictor 由四个 *.custom.yaml 用
    --   `patch: {engine/processors/@before 0: predictor}` 注入，**确实排第一位**。
    --   铁证：App 日志里 `predictor.cc:62 Predictor::OnContextUpdate` 出现 382 次。
    --
    -- 【S74 删掉它的两条理由，逐条回应】
    --   1. 「predictor 空段路已废弃」⇒ **S79 已恢复这条路，此理由失效。**
    --   2. 「放行会绕过 S73 刚修好的空格自管逻辑」⇒ **在空段档下不成立**：
    --      S73 那套逻辑全部挂在 `is_ph_input(ctx.input)` 上（还有 _sp_armed），
    --      而空段档的输入码**永远是空的**、我们从不推占位符
    --      ⇒ `is_ph_input` 恒false ⇒ 那套逻辑在空段档下本来就是惰性的，
    --        放行不损失任何东西。
    --      ★ 而且这正是我们要的：空格必须原样交给 App，
    --        只有 App 拿到这个键才可能谈得上「长按 0.51 秒起语音」。
    --        若我们在这里吞掉空格，长按语音就又没了。
    --   ⇒ 两条理由都不成立，恢复。
    --
    -- 【S80：这里已是唯一路径】
    --   S79 时外面套着 `if use_pred_segment() then`，还有「占位符档」走下面的老逻辑。
    --   S80 起use_pred_segment 恒 true ⇒ 下面那段老逻辑**永远不会执行**。
    --   ★ 保留它是因为它还兜着别的场景（`is_ph_input` 为真时，
    --     例如用户手动打了 `›`）；但「占位符档」这个概念已经没有了。
    --   条件改成直接判 `not is_ph_input(ctx.input)`，语义更准确：
    --     没有占位符在输入码里 ⇒ 放行；否则走老逻辑。
if true then  -- 占位符路已废弃(S80)：输入码永不含 ›，原 not is_ph_input 判据恒为真
        local kc0 = -1
        pcall(function() kc0 = key_event.keycode end)

        -- ★★★★★ S117（替换 S116）：临时大写 / 大写锁定 = 打断联想，提前清 predictor 空段
        -- -------------------------------------------------------------------
        -- 【真根因（真机探针坐实）】上屏汉字后 predictor 建空段挂联想候选（「国」→「际」）。
        --   临时大写 / CapsLock 上屏英文这条路径**没有清 predictor 空段**——探针：
        --   「P 空段放行 kc=71（大写G）in=」「S91 现场判定 menu=true」⇒ 空段候选还挂着。
        --   而左滑/右滑上屏字母走「候选→回车确认」的正常路径、正常清了空段，所以不出 bug。
        -- 【为什么不是「打编码时清」（S116 的错，用户一眼看穿）】
        --   打编码时清时机太晚，且判据 _assoc_ready 在「上屏中文后正常打新词」也成立 ⇒
        --   每个词第一个字母都 clear_assoc ⇒ commit_text("") 反复触发 update ⇒ 编码被打断
        --   （用户报「只能打单个编码字」）。方向应是「针对上屏大写字母」而非「打编码」。
        -- 【正确时机】在「按 Shift_L/R / Caps_Lock / 大写字母」这一刻就清：
        --   探针证实这些键都传到 P.func（input 为空），此刻 predictor 空段候选还挂着，
        --   clear_assoc 最精准，也不误伤正常联想（正常联想靠点数字键，不按这些）。
        --   keycode（本引擎大写字母 keycode 就是大写码，非靠 modifier）：
        --   Shift_L=0xFFE1(65505) Shift_R=0xFFE2(65506) Caps_Lock=0xFFE5(65509)
        --   大写字母 = 0x41-0x5A
        local _kc_upper = (kc0 >= 0x41 and kc0 <= 0x5A)
        local _kc_shiftkey = (kc0 == 0xFFE1 or kc0 == 0xFFE2 or kc0 == 0xFFE5)
        if (_kc_upper or _kc_shiftkey) and _assoc_ready then
            clear_assoc(ctx)
            if PROBE_ON then
                probe("S117 大写/Shift 清联想 kc=" .. tostring(kc0))
            end
        end

        -- ★★★★★ S95 重修 B4：联想态按退格 = **只清候选栏，不删正文**
        -- -------------------------------------------------------------------
        -- 【★ 为什么 S94 的判据不管用—— 这是本条唯一真正的原因】
        --   S94 判据是 `rawget(_G, ASSOC_SEG_FLAG)`。它由
        --     `mark_assoc_seg(_live_assoc)` 写入，而 `_live_assoc =
        --      (input == "") and _live_menu`，`_live_menu = ctx:has_menu()`。
        --   ⇒ **整个标志的成立与否 ultimately 取决于 `has_menu()`**。
        --   而 S94 真机日志（87 万行）给出决定性数据：
        --       menu=true305 次 / menu=false 85 次
        --       退格时刻的配对统计（取退格行前最近一条 S91 判定）：
        --         in=""    标志=false   61 次   ← 联想态退格，判据失效
        --         in=""    标志=true     3 次
        --       最后一次退格落在 21:32:47，而 S94 测试窗口是 21:48
        --       ⇒ 用户测 B4 时按的那几下退格，
        --          在日志里连P.func 都没进（`S94 B4` 探针零次命中）。
        --   ⇒ 结论：`has_menu()` 在 predictor 空段态下几乎恒为 false，
        --     于是 `ASSOC_SEG_FLAG` 在真正的联想态里也是 false，
        --     B4 拦截一次都执行不到⇒ 退格被 2254 行`return 2` 放行
        --     ⇒ 前端删正文 ⇒ **用户实测「未实现」**。
        --   ⚠ 这已经是同一个坑的第4 次踩中。文件里 983~992 行
        --     早就把前三次记下来了（① `_ph_mode` ②跨文件共享标志
        --     ③ `pending_cands`），每次的共同错误都是
        --     **去读一个「看起来能表示联想态」的外部量**。
        --     我 S94 又读了第四个（`has_menu`）。
        --
        -- 【★ S95 判据：`(ctx.input or "") == "" and _assoc_ready`】
        --   两个条件缺一不可，各挡一类回归（沙箱 tools/sandbox_s95_bs.py
        --   六场景 × 六判据 = 36 格全量对照，5/5 断言通过）：
        --   ① `input == ""` —— predictor 空段的唯一特征（S60 起成立）。
        --      它挡住「正常输入编码时按退格要删编码」：
        --      实测 `un` / `unt` 时 `_assoc_ready` **也是 true**
        --      （它是「结算跑过」的时机标记，不是「当前有候选」的标记），
        --      所以只判 ready 会把正常退格一起吞掉 ⇒ 「编码删不掉」。
        --   ② `_assoc_ready` —— 由 settle_commit 置位、clear_assoc 清掉，
        --      正是 `in_predicting()` 读的量（993 行），
        --      也是 `READY=1` 探针打印的那个值（真机 cands=9 首=测试）。
        --      它挡住「刚上屏、还没建段（候选栏本来就空）」：
        --      那时 `input` 同样是空，若只判 ① 会吞掉退格
        --      ⇒ 造成「按退格没反应」的回归。
        --
        -- 【两级递进 —— 正是用户要的行为】
        --   第一次退格：in=="" 且 ready=true ⇒ 吞掉 + clear_assoc
        --     ⇒ 候选栏消失，正文一个字都不删
        --   第二次退格：clear_assoc 已把 `_assoc_ready` 清成 false
        --     ⇒ 条件②不成立 ⇒ 走 2254 正常 `return 2` 放行
        --     ⇒ 前端逐字删正文 ✅
        --
        -- ★★★★★ S97 回退（2026-10-05，用户指示：恢复 S94/S93 退格行为）
        --   S95/S96 的 B4 拦截在真机上仍不可用，已整体撤除。
        --   真机 S96 日志铁证（BUILD_S96，22:15~22:39）：
        --     · 22:15:13~19 连吞 11 次、22:22:43~54 连吞 5 次
        --       ⇒ clear_assoc 把 ready 清成 false 后，下一次退格时
        --         探针仍打印 ready=true（补算门已挡 EAGER/REGAIN，
        --         「S96 补算已抑制」打出 14 次）⇒ **还有第三条把
        --         _assoc_ready 置真的路径没找到** ⇒ 永远删不了字。
        --     · 22:38:06/12 两次序列是「吞 1 次后放行」⇒ 行为不一致。
        --   回退后：联想态按退格与 S94/S93 真机行为一致 ——
        --     不经任何拦截，直接走下方 `return 2` 放行给前端处理。
        --   `_assoc_user_cleared` 持久标记同步撤除（它是 B4 的配套，
        --   留着只会改变「清联想后是否补算」的旧行为）。
        --   ⚠ 若日后重修：必须先查清上面那条未知的 ready 置真路径，
        --     否则同样的连吞还会复现。
        if PROBE_ON then
            probe("P 空段放行 kc=" .. tostring(kc0) .. " in=" .. tostring(ctx.input))
        end
        return 2
    end

    local repr = ""
    pcall(function() repr = key_event:repr() end)

    -- ⓪ 处理这个键**之前**先记下「按下就会上屏什么」。
    --    commit_history 要等下一个按键才刷新（实测），所以只能提前抓。
    -- ★ S82：这一段已提到 P.func 开头（所有 return 2 之前）——
    --   原来放在这里的调用在空段路上永远执行不到，导致不学习、toks=0、无联想。
    --   这里保留一次**幂等重复**是安全的：capture_pending 每次都重新赋值 _pend_text，
    --   同样的输入重复记一遍结果相同。
    local kc = -1
    pcall(function() kc = key_event.keycode end)
    capture_pending(ctx, repr, kc)
    dbg("[key] repr=%q kc=%s in=%q pend=%s", repr, tostring(kc),
        ctx.input or "", tostring(_pend_text))

    -- ⓪ ★★ 空格必须在联想分支**之外**单独接（2026-10-02 v5；S118 清理保留）
    --   联想态下用户按空格要在此单独接住：清空联想 / 收起档 / 放行空格档。
    --   判据是 _sp_armed —— 即「上一次按下时仍在联想态、在等本次松开」。
    --   （旧注释曾写「is_ph_input 不成立、走不进 ① 分支」；① 分支已于 S118 删除，
    --    此处逻辑改为只认 _sp_armed，与占位符无关。）
    if is_space(repr, kc) then
        if _sp_armed then  -- 上一次按下时仍在联想态、在等本次松开
            local r = handle_assoc_space(ctx, env, key_event)
            dbg("[br] space -> %s", tostring(r))
            -- 1 = 吞掉（收起档）；0 = 拒绝；2 = 放行（空格档，交给 punctuator）
            if r ~= 2 then return r end
        end
    else
        _sp_armed = false        -- 按了别的键 ⇒ 这一组空格配对作废
    end

    -- ①（S118 清理已删除）原「联想状态下的按键处理」整段被删：
    --   它整体套在 `if is_ph_input(ctx.input) then ... end` 里；而 predictor 空段路的
    --   输入码永不含占位符 ⇒ is_ph_input 恒 false ⇒ 该段永远不执行，是死代码。
    --   其下的回车 / 退格 / Esc / 数字 / 其它键处理已不再需要（空段靠引擎原生处理）。

    -- 补记：部分前端（/ commit 后不触发 update）只能在下次按键时结算
    if enabled(ctx) then pcall(settle_if_new, ctx, sid) end

    -- ★★★★★ S90 探针：把「本轮进P.func 前是不是联想段」记下来
    --   供 pair_punct 的豁免效果核对（本函数在 pair_punct 之前跑，
    --   且它自己会 clear_assoc 把标志清掉 ⇒ 后者看不到进函数时的状态）。
    --   _was_assoc_seg / _punct_exempt 由 smart_assoc 读，不参与任何控制逻辑。
    if PROBE_ON then
        probe(string.format(
            "S90 进P.func was_seg=%s 标志=%s punct_exempt=%d in=%q",
            tostring(_was_assoc_seg), tostring(_G.__touchwb_assoc_seg),
            tonumber(_G.__touchwb_punct_exempt) or 0, tostring(ctx.input)))
    end
    return 2
end

-- -------------------------------------------------------------------
-- T：在 predictor 空段上吐联想候选
-- -------------------------------------------------------------------
local T = {}

function T.init(env)
    local sid = env and env.engine and env.engine.schema and env.engine.schema.schema_id
    if sid then _sid = sid end
    get_db(sid)
end

function T.fini(env) end

function T.func(input, seg, env)
    if input == nil then return end
    -- S60 取证：predictor 空段上本函数到底收到什么 input / 数据与时机如何。
    --   ★ 必须走 probe 而不是 dbg —— dbg 受 DEBUG_LOG=false 门控，真机静默。
    if PROBE_ON then
        probe(string.format("T.func in=%q pend=%s ready=%s seg=[%d,%d]",
            tostring(input), tostring(pending_cands ~= nil),
            tostring(_assoc_ready), seg.start, seg._end))
    end
    -- ★★★ S65 判定（第四次尝试，前三次的教训见 in_predicting 的注释）：
    --   · 输入码为空  = predictor 空段的特征（打码时 input 必非空）
    --   · _assoc_ready = 时机标记（settle_commit 置位，活得够久）
    --   · pending_cands = 数据本身；它可能已被 reset_chain 清掉，
    --     但**不代表这一轮不该显示联想**（predictor 还没建段），
    --     所以它只做「有没有东西可吐」的检查，不做「该不该吐」的判据。
    -- ★ S79：**恢复 is_pred_seg 分支**（S74 曾删掉）。
    --   删掉的理由是「S65 探针里 is_pred 永远为 false」——但 S61 之后已经查明
    --   那是**判据本身的问题**（四次修判定），不是这条分支的问题。
    --   现在判据换成 `_assoc_ready`（本模块私有、reset_chain 故意不清它）。
    -- ★ 空段判据要同时要求：① 空段档开着 ② 输入码为空 ③ 时机标记成立。
    -- ★★ S80 探针改进：**把「该不该吐」与「有没有数据」分开印**。
    --   S79 期间 `is_pred=true` 一次都没出现，一度以为失败；
    --   实际那些 `is_pred=false` 全都发生在「输入码非空」的时刻
    --   （打码中input="u"/"un"/"unta"，本来就该跳过），
    --   探针把「正常跳过」和「异常跳过」印在同一行 ⇒ 严重误导判读。
    --   现在分两行印：先说该不该吐，再说吐没吐。
    local want_pred = (use_pred_segment() and input == "")
    local is_pred_seg = (want_pred and in_predicting())

    -- ★★★★★ S85 修复：开关提到**所有副作用之前**（这是「开想/关想没区别」的真凶）
    -- ------------------------------------------------------------------------
    -- 【S84 之后你反馈的】
    --   「开想/关想是一样的效果，都有官方联想；
    --     语音开/语音关则一直是有联想和无联想的实际开关。
    --     依旧没有我们的智能联想。」
    --
    -- 【真凶：关卡顺序倒了。真机日志逐行对得上】
    --   S84 把「按快照建候选」整块放在了 `if want_pred then` 里，
    --   而那个 if 在 T.func 的**第 4 行**；开关校验 `if not enabled(ctx) then return end`
    --   在**第 84 行** —— 开关在候选建好、pending_cands 写完、
    --   _assoc_ready 置位**之后**才被检查。
    --   ⇒ 关想时：`enabled()=false` 只拦住了最后那一下 yield，
    --     可是前面的副作用**一件都没跳过**。
    --   日志铁证（17:38:02~17:38:11，SWAP#031 明确 sa=false）：
    --       S84空段命中 cands=6 首=听  × 8   ← 关想状态下照样在建候选
    --       YCNT yielded=6                × 0   ← yield 被正确拦住了
    --   ⇒ 候选确实没吐出去，但状态已被污染：
    --     · pending_cands 被填满 → P.func 的「空段档收到真字」一路放行
    --     · _assoc_ready 被置位   → 下一轮 in_predicting() 仍为真
    --     · predictor 段被我们的候选标记影响 → 官方词的呈现也变了
    --   这就是「两个开关效果一样」的机制。
    --
    -- 【修法】把开关校验提到 T.func 的最前面，在want_pred 之前。
    --   关想 ⇒ 一个字节都不改状态，直接放行给官方 predictor。
    --   这样「关想」才真的等于「我们完全不干预」（与开关注释里写的一致）。
    do
        local _e_ctx = nil
        pcall(function() _e_ctx = env.engine.context end)
        if _e_ctx and not enabled(_e_ctx) then
            _ctx = _e_ctx
            if PROBE_ON then
                probe("S85 开关关闭 ⇒ 直接放行（不做任何副作用）")
            end
            -- S88：原先这里还有一句清长按标志的调用，随标志一起撤销。
            -- ★ S90：关想必须把「联想段」标志清掉。
            --   漏这一步的后果：用户关掉智能联想后，标志仍残留在 _G 上，
            --   pair_punct 会一直以为处于联想段 ⇒ 打码时按标点也只出标点、
            --   永远选不了候选，比现在更糟。
            --   （这正是 S88 删标志时漏掉的第二个职责点，与长按语音无关。）
            _assoc_ready = false
            mark_assoc_seg(false)
            -- ★★★ 保留这条教训（S85 踩过的坑，与长按无关）：
            --   这里**不能**写 `for cand in input:iter()`。
            --   沙箱实测每轮翻译都报：
            --       LuaTranslation::Next error(2):
            --       smart_assoc.lua:2297: attempt to call a nil value (method 'iter')
            --   原因：`input:iter()` 是 **F.func（过滤器）**的写法。
            --   在 T.func（翻译器）里 input 是**输入码字符串**，"ni" 这种值
            --   压根没有 iter 方法 ⇒ 整个 T.func 每轮都异常中断。
            --   而 S85 恰好把这段放在 T.func 最前面 ⇒ 关想状态下
            --   我们的翻译器**整个挂掉**，官方预测词也出不来。
            --
            --   正确做法：关想时我们**一个候选都不产出**，直接 return。
            --   这与 S85 的原意（「我们完全不干预」）一致，而且安全 ——
            --   官方预测词由 processors 里的 predictor 组件 +
            --   translators 里的 predict_translator 产出，
            --   我们的 translator 在它们之后，不产出不影响它们。
            return
        end
    end

    -- ★★★★★ S83核心修复（第五次改判定，前四次全错的根因见下）
    --
    -- 【为什么前四次都错】S60/S65/S79/S80 全部把「该不该在空段上吐词」
    --   押在 `_assoc_ready`（时机标记）上：
    --       is_pred_seg = want_pred and in_predicting()   -- in_predicting() 就是读 _assoc_ready
    --   而 _assoc_ready 只由 settle_commit 置位。真机日志把时序记得死死的：
    --       [16:24:22] T.func in="" pend=false ready=false seg=[0,0] mode=ph  ← 空段先到
    --       [16:24:22] T.func 空段待补算 toks=0 命中=false
    --       [16:24:22] T.func SKIP 输入码="" 想要空段=true 时机=false 已有数据=false
    --       [16:24:22] SETTLE cands=9 首=更新        ← 词在这儿才第一次被算出来
    --   ⇒ **空段必然早于结算**（predictor 在上屏那一刻就建段，结算在update 回调里）。
    --     所以在空段那一轮，_assoc_ready 恒为 false ⇒ is_pred_seg 恒为 false
    --     ⇒ 每次都在这里 return，**我们的词一次也吐不出去**。
    --   补充证据：真机 `空段待补算 toks=0 命中=false` 出现 **190 次**，
    --   而 `EAGER`（update_cb 里那条同义分支）出现 **0 次**。
    --
    -- 【S83 的判据】空段上要不要吐词，**只看有没有可联想的历史**：
    --       is_pred_seg = want_pred and state(_sid).toks 非空
    --   为什么这样就够：
    --     · input=="" +空段档开着 = 此刻确实是联想时刻（predictor 只在上屏后建空段）
    --     · toks 非空         = 这一句已经上屏过词，有上下文可联想
    --   两个条件都是**当下可判定**的事实，不依赖任何异步标记。
    --   ★ 与 _assoc_ready 的区别：前者是「数据在不在」，后者是「结算跑没跑过」。
    --     我们要的恰恰是数据在不在 —— 结算晚一点完全不影响我们能不能算出来。
    --
    -- 【build_candidates 在这里调用为什么安全】
    --   它是纯函数：只读 state(sid)（toks/chars），只查 db，只读固定词库文件。
    --   不碰 ctx、不写 pending_cands 之外的任何引擎状态 ⇒ 幂等、可重入。
    --   而且这是它**唯一**能真正派上用场的时机：结算后的补救路线已被
    --   沙箱证伪（refresh / 空commit / push+pop / commit(空格) / clear 五个全YCNT=0）。
    if want_pred then
        -- ⚠ 用模块级 `_sid`（T.init 赋值），不是形参 —— 写成局部会拿到 nil。
        local s_ok, s_ = pcall(state, _sid)
        local ntok = (s_ok and s_ ~= nil and s_.toks ~= nil) and #s_.toks or 0
        -- ★★★★★ S84 核心：上下文来源二选一，**不再问恒为 0 的 toks**
        --   ① 优先 _last_ctx（本模块自己维护的跨轮快照，settle_commit 写入）
        --   ② toks 非空时也认（兼容 toks 恰好有值的场合，比如沙箱手动构造）
        --
        -- 【为什么不能用 toks 当主判据——前五轮的共同死因】
        --   实测：空段轮次里 toks **恒为 0**
        --       真机 `空段待补算 toks=0 命中=false` 190 次，命中=true 0 次
        --       沙箱 `S83空段 toks=0 命中=false`     37 次，命中=true 0 次
        --   而 S83 的判据恰恰是「空段时只看 toks 非空」⇒ 命中率恒为 0。
        --   架构上必然如此：predictor 在上屏那一刻建空段，
        --   唯一写 toks 的 settle_commit 跑在 update 回调里、**必然晚于**它。
        --
        -- 【为什么不能用 commit_history 代替（已实测排除）】
        --   沙箱 37 次空段轮次里 `commit_history.size=0 back=nil`
        --   —— 全部发生在任何上屏之前。它和 toks 一样受制于同一条时序。
        local ctx_snap = _last_ctx
        local src = "snap"
        if (not ctx_snap) and ntok > 0 then
            local ok2, c2 = pcall(context_of, _sid)
            if ok2 and c2 and c2 ~= "" then ctx_snap, src = c2, "toks" end
        end
        if PROBE_ON then
            probe(string.format("T.func S84空段 toks=%d快照=%s 来源=%s",
                ntok, tostring(ctx_snap), src))
        end
        if ctx_snap and ctx_snap ~= "" then
            -- ★ 用**指定上下文**建候选（不是 build_candidates，它只认 state）。
            --   查历史 + 查固定词库，都只吃这个字符串 ⇒ 不依赖 state 的任何字段。
            local list, used = {}, {}
            local hist = query(_sid, ctx_snap, 1)
            local fx = fixed_candidates(ctx_snap, used)
            -- 顺序：历史在前（用户真打过的接续），固定词库在后（冷启动兜底）
            if hist then
                for _, w in ipairs(hist) do
                    if #list >= MAX_CANDIDATES then break end
                    if not used[w] then used[w] = true; list[#list + 1] = w end
                end
            end
            if fx then
                for _, w in ipairs(fx) do
                    if #list >= MAX_CANDIDATES then break end
                    if not used[w] then used[w] = true; list[#list + 1] = w end
                end
            end
            if #list > 0 then
                pending_cands = list
                _last_offered = list
                _assoc_ready = true
                -- ★ S90：同步置「联想段」标志（与 _assoc_ready 严格成对）
                mark_assoc_seg(true)
                is_pred_seg = true
                if PROBE_ON then
                    probe(string.format("T.func S84空段命中 cands=%d 首=%s 来源=%s",
                        #list, tostring(list[1]), src))
                end
            elseif PROBE_ON then
                probe("T.func S84 有上下文但库里查不到（历史0 固定0）")
            end
        elseif PROBE_ON then
            probe("T.func S84 空段但无上下文（本句还没结算过）")
        end
    end
    if PROBE_ON then
        if not is_pred_seg then
            local d_ok, d_ = pcall(state, _sid)
            local ntok = (d_ok and d_ and d_.toks) and #d_.toks or -1
            probe(string.format("T.func SKIP 输入码=%q 想要空段=%s toks=%s 快照=%s 已有数据=%s",
                input, tostring(want_pred),
                tostring(ntok > 0) .. "(" .. tostring(ntok) .. ")",
                tostring(_last_ctx),
                tostring(pending_cands ~= nil)))
        end
    end
    if not is_pred_seg then
        return
    end
    local ctx = env.engine.context
    _ctx = ctx                       -- 给 fixed_on() 读开关用
    if not enabled(ctx) then return end
    if not pending_cands then
        if PROBE_ON then probe("T.func no pending_cands（时机到了但数据已清）") end
        -- ★ 数据没了但时机还在 ⇒ 这一轮已经没有可展示的内容，
        --   把时机一并清掉，避免 predictor 段里挂出 predictor 自己的候选
        --   （S64 用户看到的「随机联想」就是它）。
        _assoc_ready = false
        -- ★ S90：同步清「联想段」标志（与 _assoc_ready 严格成对）
        mark_assoc_seg(false)
        return
    end

    -- ★ 候选类型：predictor 段上必须用 "predict"，否则 App 点候选时
    --   会去找 table 处理器而报「未找到处理器: table」（S59 日志实测）。
    --   空段模式下我们完全替换掉 predictor 的候选，所以类型统一为 predict。
    -- ★★ S83：加一条 YCNT 探针 —— **yield 出去几个**，直接回答
    --   「我们的候选到底有没有送到引擎手里」。
    --   前三轮之所以查不清，就是因为只印了「算出来了几个」（SETTLE cands=N），
    --   却没有一行印「交出去了几个」—— 于是「算得出」被误当成「送得走」。
    --   判读新规则：日志里出现 YCNT>0 才算真的显示；只有 SETTLE 没有 YCNT
    --   ⇒ 还是老问题（词算出来了没人取）。
    local _yc = 0
    for _, w in ipairs(pending_cands) do
        yield(Candidate("predict", seg.start, seg._end, w, ""))
        _yc = _yc + 1
    end
    if PROBE_ON then
        probe(string.format("YCNT yielded=%d 首=%s", _yc,
            tostring(pending_cands[1])))
    end
end

-- -------------------------------------------------------------------
-- F：只处理命令，其余原样放过
-- -------------------------------------------------------------------
local F = {}

function F.init(env) end
function F.fini(env) end

-- ===================================================================
-- 联想库导出 / 导入（/lxdc /lxdr，2026-10-23 新增）
-- -------------------------------------------------------------------
-- 【解决什么问题】两台设备（PC + 手机）各自养各自的「词脑」；换机 / 重装 /
--   清数据后历史联想从零开始。导出成 txt ⇒ txt 即同步载体（dufs / 微信 /
--   U 盘，通道不限），另一台设备导入合并。
--
-- 【蓝本与差异】蓝本 super_sequence.lua 的 /txdc /txdr（调序库导入导出）。
--   蓝本 /txdr 按「时间戳新者覆盖」合并——调序库一条记录一个键，覆盖语义清晰；
--   联想库是 (上下文,后续) 多条记录共享前缀，两台设备会各自累加同一个键的
--   count ⇒ 覆盖会丢另一台的学习量，相加会因重复导入膨胀。
--   ⇒ 本模块用 **max 合并**（count / timestamp 逐字段取大）：
--     幂等（同文件导 N 次无副作用）+ 无损（不丢任一侧学习量）+ 零额外状态。
--
-- 【txt 格式】每行：上下文 \t 后续 \t 次数 \t 时间戳
--   （不含 \003as| 内部前缀，导入时拼回；UTF-8 带 BOM，与人看的 sequence 备份同风格）
--   文件头 4 行 #/schema_id、#/user_id、#/version、#/entries 供校验与溯源。
--
-- 【导出保护】备份存在且当前库的 count 总和 <= 备份的 count 总和 ⇒ 拒绝导出。
--   防 /lxqk 清库后误 /lxdc 把空库导出、覆盖掉几天养出来的好备份。
--   count 总和比条目数更语义化：清库时条目和 count 一起归零，总和直接反映学习量。
-- ===================================================================
local function assoc_export_path(sid)
    if not sid then return nil end
    local base = ""
    pcall(function()
        if rime_api and rime_api.get_user_data_dir then
            base = rime_api.get_user_data_dir() or ""
        end
    end)
    if base == "" then return "lua/assoc_" .. sid .. ".txt" end
    if not base:match("[/\\]$") then base = base .. "/" end
    return base .. "lua/assoc_" .. sid .. ".txt"
end

-- 备份 txt 的 count 总和（导出保护判据；文件不存在返回 0）
local function txt_count_sum(path)
    if not path then return 0 end
    local file = io.open(path, "rb")
    if not file then return 0 end
    local content = file:read("*a")
    file:close()
    if content:sub(1, 3) == "\xef\xbb\xbf" then content = content:sub(4) end
    local sum = 0
    for line in content:gmatch("[^\r\n]+") do
        if line:sub(1, 1) ~= "#" then
            local c = line:match("\t(%d+)\t%d+$")
            if c then sum = sum + tonumber(c) end
        end
    end
    return sum
end

-- 导出：返回 (条数, err)。err = "protected" 表示被保护条件拒绝
local function export_assoc(db, sid)
    if not sid then return nil, "no_sid" end
    if not db or not db:loaded() then return nil, "no_db" end
    local path = assoc_export_path(sid)
    if not path then return nil, "no_path" end

    local acc = db:query(ASSOC_PREFIX)
    if not acc then return nil, "no_query" end
    local lines, n, sum = {}, 0, 0
    for k, v in acc:iter() do
        if k:sub(1, #ASSOC_PREFIX) == ASSOC_PREFIX then
            local body = k:sub(#ASSOC_PREFIX + 1)
            local ctx, cont = body:match("^(.-)" .. SEP .. "(.*)$")
            local c, t = tostring(v):match("^(%d+)" .. SEP .. "(%d+)$")
            if ctx and cont and c and t then
                lines[#lines + 1] = string.format("%s\t%s\t%s\t%s", ctx, cont, c, t)
                n = n + 1
                sum = sum + tonumber(c)
            end
        end
    end
    acc = nil
    if n == 0 then return 0, nil end

    -- 导出保护：备份存在且当前库学习量不超过它 ⇒ 拒绝覆盖
    local tsum = txt_count_sum(path)
    if tsum > 0 and sum <= tsum then return nil, "protected" end

    local file = io.open(path, "wb")
    if not file then return nil, "no_file" end
    file:write("\xef\xbb\xbf")
    file:write(string.format("#/schema_id\t%s\n", tostring(sid)))
    file:write(string.format("#/user_id\t%s\n",
                os.getenv("USERNAME") or os.getenv("USER") or "unknown1"))
    file:write("#/version\t1\n")
    file:write(string.format("#/entries\t%d\n", n))
    for _, l in ipairs(lines) do
        file:write(l)
        file:write("\n")
    end
    file:close()
    return n, nil
end

-- 导入：返回 (ok, imported, skipped, err)
--   imported = 实际写入/提升的条数；skipped = 格式损坏跳过的行数
-- ★ 注意：这是「前向声明 local import_assoc」（见 P.init 前）的赋值点。
--   不要改回 local function，否则 P.init 里的引用仍是 nil。
import_assoc = function(db, sid)
    if not sid then return false, 0, 0, "no_sid" end
    if not db or not db:loaded() then return false, 0, 0, "no_db" end
    local path = assoc_export_path(sid)
    local file = path and io.open(path, "rb")
    if not file then return false, 0, 0, "no_file" end
    local content = file:read("*a")
    file:close()
    if content:sub(1, 3) == "\xef\xbb\xbf" then content = content:sub(4) end

    -- schema 校验：文件头的 schema_id 必须与当前方案一致（没有头也拒绝，
    -- 确保只接受 /lxdc 导出的本方案备份，防手写文件误灌）
    local head_ok = false
    for line in content:gmatch("[^\r\n]+") do
        local s = line:match("^#/schema_id\t(.+)$")
        if s then head_ok = (s == tostring(sid)) break end
    end
    if not head_ok then return false, 0, 0, "schema_mismatch" end

    local imported, skipped = 0, 0
    for line in content:gmatch("[^\r\n]+") do
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local ctx, cont, c, t = line:match("^([^\t]+)\t([^\t]+)\t(%d+)\t(%d+)$")
            if ctx and cont and ctx ~= "" and cont ~= "" then
                c, t = tonumber(c), tonumber(t)
                local k = ASSOC_PREFIX .. ctx .. SEP .. cont
                local old = db:fetch(k)
                if old then
                    -- max 合并：逐字段取大 ⇒ 幂等且不丢任一侧的学习量
                    local oc, ot = tostring(old):match("^(%d+)" .. SEP .. "(%d+)$")
                    oc, ot = tonumber(oc) or 0, tonumber(ot) or 0
                    local nc, nt = math.max(c, oc), math.max(t, ot)
                    if nc ~= oc or nt ~= ot then
                        db:update(k, nc .. SEP .. nt)
                        imported = imported + 1
                    end
                else
                    db:update(k, c .. SEP .. t)
                    imported = imported + 1
                end
            else
                skipped = skipped + 1
            end
        end
    end
    return true, imported, skipped, nil
end

function F.func(input, env)
    local ctx = env.engine.context
    _ctx = ctx                       -- 给 fixed_on() 读开关用
    local sid = env.engine and env.engine.schema and env.engine.schema.schema_id
    if not ctx then
        for cand in input:iter() do yield(cand) end
        return
    end
    local inp = ""
    pcall(function() inp = ctx.input or "" end)

    if inp == "/lxqk" then
        local db = get_db(sid)
        local n = 0
        if db then
            local keys = {}
            local acc = db:query(ASSOC_PREFIX)
            if acc then
                for k, _ in acc:iter() do keys[#keys + 1] = k end
                acc = nil
            end
            for _, k in ipairs(keys) do db:erase(k) end
            n = #keys
        end
        reset_sentence(state(sid))
        reset_chain()
        _stat.learns, _stat.writes, _stat.hits, _stat.queries = 0, 0, 0, 0
        _stat.last_key, _stat.last_cands, _stat.last_ctx = nil, nil, nil
        yield(Candidate("assoc_cmd", 0, #inp,
                        string.format("※ 用户历史联想已清空（%d 条记录）", n), ""))
        return
    end

    -- ★ J-2 联想清理：只删**过期**条目（超过 EXPIRY_DAYS 天没再被用过），
    --   不是清空。想整个库重来请用 /lxqk。过期条目靠衰减已经排不上号了，
    --   留着只是占库；清掉能让 /lxzt 里的条数回到真实「还记得」的规模。
    if inp == "/lxql" then
        local db = get_db(sid)
        local n, total = 0, 0
        if db then
            local now = os.time()
            local dead = {}
            local acc = db:query(ASSOC_PREFIX)
            if acc then
                for k, v in acc:iter() do
                    total = total + 1
                    local c, t = tostring(v):match("^(%d+)" .. SEP .. "(%d+)$")
                    if is_expired(tonumber(t) or 0, now) then dead[#dead + 1] = k end
                end
                acc = nil
            end
            for _, k in ipairs(dead) do db:erase(k) end
            n = #dead
        end
        yield(Candidate("assoc_cmd", 0, #inp,
                        string.format("※ 已清理过期联想 %d 条（库中共 %d 条，%d 天未用视为过期）",
                                      n, total, EXPIRY_DAYS), ""))
        return
    end

    if inp == "/lxdj" then
        -- 手动断句：这句话到此为止，下一个上屏的词另起一句。
        -- 用途：没打标点就接着写下一句时，防止「句末词 → 下一句首词」被学进库。
        break_sentence(state(sid))
        reset_chain()
        yield(Candidate("assoc_cmd", 0, #inp, "※ 已断句（下一个词另起一句）", ""))
        return
    end

    if inp == "/lxzt" then
        local db = get_db(sid)
        local n = 0
        if db then
            local acc = db:query(ASSOC_PREFIX)
            if acc then
                for _ in acc:iter() do n = n + 1 end
                acc = nil
            end
        end
        local fx
        if _fixed then
            fx = string.format("已加载%d首字", _stat.fix_n or 0)
        else
            fx = "未加载"
        end
        local fxnow = fixed_candidates(context_of(sid), {})
        yield(Candidate("assoc_cmd", 0, #inp,
                        string.format("※ 历史联想%s 记录%d条 固定词库%s 上下文[%s] 命中码[%s] 候选[%s] 固定[%s] 学%d 查%d 中%d %s",
                                      enabled(ctx) and "开" or "关", n, fx,
                                      tostring(context_of(sid)),
                                      tostring(_stat.last_key),
                                      tostring(_stat.last_cands),
                                      fxnow and table.concat(fxnow, " ") or "",
                                      _stat.learns, _stat.queries, _stat.hits,
                                      _stat.err and ("异常=" .. tostring(_stat.err)) or ""), ""))
        -- ★ S101b-2：常用字白名单自检（fail-open 时必须有痕迹，否则静默失效）
        local cm
        if not ASSOC_COMMON_ONLY then
            cm = "常用字表[已关闭]"
        elseif _common then
            cm = string.format("常用字表[%d字 拦%d]", _common_n, _stat.common_blocked or 0)
        else
            cm = "常用字表[未加载⇒不拦]"
        end
        yield(Candidate("assoc_cmd", 0, inp, "※ " .. cm, ""))
        return
    end

    -- 联想库导出（/lxdc）：当前方案的历史联想记录 → assoc_<schema_id>.txt
    if inp == "/lxdc" then
        local db = get_db(sid)
        if not db or not db:loaded() then
            yield(Candidate("assoc_cmd", 0, #inp, "※ 导出失败：数据库连接失败", ""))
            return
        end
        local n, err = export_assoc(db, sid)
        if err == "protected" then
            yield(Candidate("assoc_cmd", 0, #inp,
                            "※ 导出失败：已有有效备份且当前库不优于它，请先 /lxdr 恢复", ""))
        elseif err then
            yield(Candidate("assoc_cmd", 0, #inp,
                            "※ 导出失败：未知错误（" .. tostring(err) .. "）", ""))
        elseif n and n > 0 then
            yield(Candidate("assoc_cmd", 0, #inp,
                            string.format("※ 成功导出 %d 条联想记录 → assoc_%s.txt",
                                          n, tostring(sid)), ""))
        else
            yield(Candidate("assoc_cmd", 0, #inp, "※ 导出失败：当前库无联想数据", ""))
        end
        return
    end

    -- 联想库导入（/lxdr）：assoc_<schema_id>.txt → 合并进当前库（max 合并，幂等）
    if inp == "/lxdr" then
        local db = get_db(sid)
        if not db or not db:loaded() then
            yield(Candidate("assoc_cmd", 0, #inp, "※ 导入失败：数据库连接失败", ""))
            return
        end
        local ok, imported, skipped, err = import_assoc(db, sid)
        if err == "schema_mismatch" then
            yield(Candidate("assoc_cmd", 0, #inp,
                            "※ 导入失败：备份的 schema 与当前方案不符", ""))
        elseif err == "no_file" then
            yield(Candidate("assoc_cmd", 0, #inp,
                            "※ 导入失败：备份文件不存在（assoc_" .. tostring(sid) .. ".txt）", ""))
        elseif err then
            yield(Candidate("assoc_cmd", 0, #inp,
                            "※ 导入失败：未知错误（" .. tostring(err) .. "）", ""))
        elseif imported > 0 then
            yield(Candidate("assoc_cmd", 0, #inp,
                            string.format("※ 成功导入 %d 条（跳过 %d 坏行）", imported, skipped), ""))
        else
            yield(Candidate("assoc_cmd", 0, #inp,
                            "※ 导入完成：无新记录（备份均不优于当前库）", ""))
        end
        return
    end

    -- ===================================================================
    -- ★★★ S71：删掉 S68/S69 的「filter 层替换候选」实验代码
    -- -------------------------------------------------------------------
    -- 为什么整段删除，而不是修好：
    --   这段的前提是「assoc_mode 有一档是 predictor 空段 **+** 我们的候选」
    --   （S60~S68 的中间态）。S70 改成二元基线后这个组合**不存在了**：
    --     · 「我们的联想」= use_our_candidates=true ⇒ 走 › 占位符自建段，
    --       根本不进 predictor 空段，这里 naturally 不该插手；
    --     · 「官方+语音」= use_pred_segment=true ⇒ 按设计就该显示
    --       **predictor 自己的官方预测**（这正是这一档存在的意义：
    --       用官方的联想换取长按语音），如果在这里把候选替换成我们的词，
    --       等于又回到「占位符占着输入区」的老问题，语音照样唤不起来。
    --   ⇒ 两档都不该执行这段，留着只会让人误以为还有第三种组合。
    --
    --   历史结论仍保留在案：S60~S68 九轮证明「在 predictor 空段上让我们的
    --   候选顶掉官方候选」这条路走不通（顶掉了、长按也还是唤不起语音，
    --   属于白折腾），不必再试。

    -- ★★★★★ S89：把我们的 predict 候选提到候选栏最前面
    -- -------------------------------------------------------------------
    -- 【S88 真机日志已确证的唯一剩余问题】
    --   [21:08:37] MENU 过滤后放行=19 其中predict=9
    --               前三=prediction:人 | prediction:什么 | prediction:了
    --   App 侧：getCandidateList end resultCount=19
    --   用户实见：仪、的、版、你、结果、题、中、招聘、工程、系统（10 个，全官方）
    --   ⇒ 19 = 官方 prediction 10 + 我们的 predict 9。**我们的候选已产出、已过 F.func**，
    --     只是排在官方之后，而候选栏可见位约 10 个，被官方占满 ⇒ 用户看不到我们的词。
    --
    -- 【为什么官方候选排在前面】
    --   custom.yaml 里 `engine/translators/@before 0: predict_translator`
    --   把官方 translator 插到 translators[0]；而我们的
    --   `lua_translator@*smart_assoc*T` 在 schema 里本也是 [0]，被它挤到 [1]。
    --   Rime 按 translators 列表顺序 yield ⇒ 官方先进菜单。
    --
    -- 【为什么不在这里改 translator 顺序，而选择在 F.func 里重排】
    --   processors 侧的 `engine/processors/@before 0: predictor` **必须留首位**
    --   ——它是唯一能在上屏后建出「输入码为空」段的组件（S75 铁证：
    --   App 日志 `Predictor::OnContextUpdate` 出现 382 次），也是长按空格
    --   能唤起语音的地基。translators 侧挪动虽不动 processor，但 predict.db
    --   依赖 translators[0] 的位置语义（custom.yaml 头部注释明确写了
    --   「@before 0 的位置有语义」），改动风险不可控。
    --   而 F.func 已在**候选链末端**，我们在这里重排：
    --     · 不碰任何 processor / translator 注册 ⇒ 空段照常建立、长按语音零风险
    --     · 不动 `predictor:` / `grammar:` / `switches:` ⇒ 官方联想质量参数不变
    --     · 我们的候选本来就是这批 19 个里唯一「属于用户历史」的一组，
    --       排前面在语义上也更对：用户想要的是「我打过的词」优先。
    --
    -- 【实现要点】
    --   · 必须**物化**候选后再重排（filter 的 input 是单向协程，遍历完就废）；
    --     本项目 super_sequence.lua 的调序器早就在用 `table.insert(candidates, cand)`，
    --     同一个成熟写法。
    --   · 只在「本轮真有我们的 predict 候选」时才物化重排。
    --     没有我们的候选时走原来的直通路径，**普通打码候选的排序绝不受影响**
    --     （super_sequence 按 quality 的调序结果原样透传）。
    --   · 官方候选之间的相对顺序保持不变（只是整组后移），
    --     所以「关想」状态下看到的候选列表与现在完全一致。

    -- ★ 物化一次遍历，分类存放
    --   ⚠ filter 的 input 是**单向协程**，input:iter() 只能安全遍历一次。
    --     （S89 沙箱实测：在同一次 F.func 里第二次 input:iter() 得到 n=0。）
    --     所以这里**绝不能**先探测再遍历，必须一趟收集完再决定怎么 yield。
    -- ★ S89 重排（干净态）：只做「我们 predict 候选整组提前、官方候选整组后移」，
    --   不做任何过滤/丢弃。方案B 系列已撤销（见 2026-10-13 日志）。
    local _ours, _others, _mp, _mo = {}, {}, 0, 0
    for cand in input:iter() do
        local ct = nil
        pcall(function() ct = cand.type end)
        if ct == "predict" then
            _mp = _mp + 1
            _ours[#_ours + 1] = cand
        else
            _mo = _mo + 1
            _others[#_others + 1] = cand
        end
    end

    if _mp == 0 then
        -- 没有我们的候选 ⇒ 原样直通，**普通打码候选的排序一个字节都不改变**
        for _, c in ipairs(_others) do yield(c) end
        if PROBE_ON then
            local _f3 = {}
            for i, c in ipairs(_others) do
                if i > 3 then break end
                local ct, cx = "?", "?"
                pcall(function() ct = c.type end)
                pcall(function() cx = c.text end)
                _f3[#_f3 + 1] = tostring(ct) .. ":" .. tostring(cx)
            end
            probe(string.format(
                "MENU 直通=%d 其中predict=0 前三=%s",
                _mo, table.concat(_f3, " | ")))
        end
        return
    end

    -- ★ 有我们的候选 ⇒ predict 组整组提到最前，官方组整体后移
    for _, c in ipairs(_ours) do yield(c) end
    for _, c in ipairs(_others) do yield(c) end

    if PROBE_ON then
        local _f3 = {}
        for i, c in ipairs(_ours) do
            if i > 3 then break end
            local cx = "?"
            pcall(function() cx = c.text end)
            _f3[#_f3 + 1] = "predict:" .. tostring(cx)
        end
        probe(string.format(
            "S89 已提权 放行=%d 其中predict=%d 官方=%d 新前三=%s",
            _mp + _mo, _mp, _mo, table.concat(_f3, " | ")))
    end
    return
end

return { P = P, T = T, F = F }
