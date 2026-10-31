# TouchWB / 流萤 · 项目基线（BASELINE）

> **基线版本**：v2.3（README 口径 2026-10-24）
> **基线日期**：2026-10-21（2026-10-24 修订过时口径）
> **基线范围**：`D:\AutophotiaIME` 全库，975 个文件（不含 `.workbuddy` 与 `.git`，2026-10-24 实测）
> **用途**：后续所有功能拓展、优化、Bug 修复均以此文件为对照基准；每次变更在此追加「变更记录」，保证任何时候都能回答"当前版本和基线差了什么"。

---

## 一、基线事实表

| 项 | 基线值 |
|---|---|
| 项目 | TouchWB 五笔输入法方案（Rime 内核） |
| 上游 | 空山明月底包 → Shawx（TouchWubi）→ **Autophotia（流萤）**当前维护 |
| 仓库 | https://github.com/Autophotia/TouchWubi |
| README 版本 / 日期 | v2.3 / 2026-10-24 |
| info.yaml version | **"2.0" ⛔ 禁止修改**（输入法识别用；2026-10-25 事故：曾改 2.3 致导入后输入法不认，已回退）/ update_time 2026-10-24 |
| 默认方案 | `ly_wubi_14`（拇指五笔 14 键，项目默认口径；space.custom.yaml 当前实测为 `ly_wubi`，见 B-12） |
| 默认主题 | `14key_wubi`（移动端）/ PC 用系统主题 |
| 默认触感 | `bouncy`（旧基线为 `system`） |
| Rime / 小狼毫 | 1.13.1 / 0.17.4 |
| 目标平台 | 鸿蒙（实测主用）、同文 / 仓 / 超越输入法、PC 小狼毫 |

### 规模基线

| 资产 | 基线值 | 对比旧基线（2026-10-20 首次分析） |
|---|---|---|
| Lua 代码 | **12,899 行**（15 个模块） | 9,678 行，+33% |
| `lua/lib/` | 2,053 行（5 个库） | 1,317 行 |
| schema 配置 | **1,935 行**（7 个） | 1,597 行 |
| 主题（TouchWB） | 2 套 + public | 不变 |
| space 通用主题 | **29 套** | 32 套（-14key_wubi、-t26_microsoft、+quick） |
| space 补丁 | 30 个（含 `_speech_*`） | +support_t14/support_t18 新建 |
| 词库 | 五笔 3.1M / 扩展 / 拼音 4.6M / 字根拆分 1.9M | 删去了「自显字根备份版」 |
| 智能联想库 | `assoc_fixed.txt` **12,510 首字** / 278KB；`assoc_common.txt` 8,000 常用字 | 新增（基线无） |
| 预测语言库 | `predict.db` 7.5MB | 新增 |
| 自定义短语 | `custom_phrase.db` + `.txt` | 新增 |
| 输入法表情 | Emoji 3972 条 + 颜文字 1296 条 | tools/ 新增维护链 |

---

## 二、架构基线（不改动的前提）

### 2.1 目录地图

```
D:\AutophotiaIME\
├── dev/                  ★ 工作目录 = git 仓库根（.git 在此；161 文件/26M）
│   ├── space/             主体工程（从手机同步，252M；仅部分入 git）
│   │   ├── space.yaml             默认入口（rime_ice_26 / bim-pinyin）
│   │   ├── space.custom.yaml      ★ 实际生效配置（当前实测 ly_wubi/26key_wubi，见 B-12）
│   │   ├── schemas/  TouchWB(★优化对象) bim-pinyin bim-wubi
│   │   ├── patches/   补丁集（76 文件，已入 git）
│   │   ├── themes/   29 套通用主题 + public
│   │   ├── haptics/ sounds/ speeches/ textflow/ tools/ emoticons/ fonts/ plugins/ …
│   │   └── log/      app + keyboard + dufs 三类运行日志
│   ├── docs/              ★ 项目文档（BASELINE.md / 项目指令_v14.md 现行 + v13/v7 留档 + 4 份设计调研文档，8 文件，已入 git）
│   ├── tools/             工具脚本（pack-release.sh / 验证脚本，4 个 .sh/.py，已入 git）
│   ├── legacy-remote-b2faab1-backup.zip   旧远端备份（兜底）
│   └── App场景感知可行性调研.md / 简码越级检查报告.md / 联想增强方案.md
├── patches/             早期补丁归档（补丁 zip + 独立补丁 + _backup + 字体包，不进 git）
├── releases/            打包输出（TouchWB_S<序号>_<日期>.zip）
├── wps/                 无关脚本
├── 码表处理/             码表工具（WubiLex/mbEditer/字频表）
└── xiangqi/             象棋（无关）
```

### 2.2 四套方案（继承关系）

```
ly_wubi（26键纯五笔，473行）      ──┬── ly_wubi_14（14键纯五笔，313行）★当前默认
ly_wubi_pinyin（26键混输，509行） ──┴── ly_wubi_pinyin_14（14键混输，389行）
```

### 2.3 Lingua franca：引擎挂载顺序（**改动即回归**）

处理器（14 键基线）：
`predictor → calc_symbol_processor → smart_assoc*P → Submit_text → super_tips → super_sequence*P → pair_punct → punctuator → recognizer → key_binder → speller → selector → navigator → express_editor`

过滤器（固定顺序，不可换）：
`new_spelling → super_sequence*S → super_sequence*F → smart_assoc*F → wubi_pinyin_filter → simplifier → es_conversion → uniquifier`

翻译器（固定顺序）：
`predict_translator → smart_assoc*T → schedule → help_cmd → punct_translator → table_translator → user_coined → fixed → mkst → script_translator@wubi_prefix → reverse_lookup → calculator → email_suffix → input_statistics`

### 2.4 Lua 模块基线（14 个 + lib 5 库）

行数按 2026-10-27 实测（`wc -l`），与旧表有出入的以实测为准。

| 模块 | 行数 | 职责 | 挂载 |
|---|---|---|---|
| smart_assoc | 3186 | 智能联想（历史记忆+逐级联想+衰减淘汰） | 四方案 |
| super_sequence | 2140 | 手工调频/自动调频/自动排序 | 四方案 |
| input_statistics | 1017 | 输入统计（/tj /ks /js） | 四方案 |
| wubi_pinyin_filter | 1028 | 14键双键模糊+第五码拼音筛选+分层预测 | 四方案 |
| new_spelling | 899 | 字根拆分/拼音/编码注解 | 四方案 |
| Submit_text | 895 | 造词/快捷上屏/编码查询 | 四方案 |
| calculator | 667 | 计算器+大/小写金额 | 四方案 |
| pair_punct | 599 | 智能对标点 | 26键 |
| schedule | 521 | 日程农历（/jt /jq /rq …） | 四方案 |
| super_tips | 369 | 超级提示 | 四方案 |
| calc_symbol_processor | 217 | 计算器符号处理器（算式按键接管） | 14键 |
| email_suffix_translator | 90 | 邮箱后缀补全 | 四方案 |
| user_coined_cmd | 606 | 自造词管理命令：列表/删序号(2位)/撤销/清空 + 从备份导入 | 四方案（2026-10-27 新增） |
| help_cmd | 55 | `/h` 命令帮助 | 四方案 |
| lib/（basic bit log lunar userdb） | 2053 | 基础库（农历 1666 行在内） | 依赖 |

> ⚠ 深度耦合：`wubi_pinyin_filter` 与 `Submit_text` 依赖 `new_spelling` 的注释格式；`user_coined_cmd` 依赖 `Submit_text` 暴露的 `get_userphrase_path()` 与 `UserCoined_InvalidateCache()` 钩子（2026-10-27 为删词新增）；单独带走任何 .lua 均不可用（README 9.5 节）。

### 2.5 数据文件与平台差异

- **用户数据（LevelDB）**：`lua/sequence_<方案>`（调频）、`lua/assoc_<方案>`（联想）、`lua/tips`、`easy_en`、`assoc_easy_en`、`rime_ice.userdb`
- **造词/短语明文（运行时自动生成，不进 git 不进包）**：`user_coined_ext.txt`（`Submit_text.lua` 首次造词时自动创建）、`custom_phrase.txt`
- **平台差异**：主题（theme.yaml）仅移动端；schema/lua/词典两端共用；联想默认仅移动端（`assoc_pc`：仅移动/双端）
- **部署链路**：PC 改 `dev/space` → 打包 → 手机 dufs(局域网 WebDAV, 192.168.124.x) 拉取热更新（真机为鸿蒙）
- **部署三件事（缺一即"没生效"）**：① 覆盖文件并重新部署 ② **切换一次方案**（Lua 与缓存重建）③ 改过主题则删 `themes/<t>/build/` 再切方案（build 在就不重编译）

---

## 三、开关基线（16 个，均可在方案菜单切换）

显根/隐根、显码/隐码、显拼/隐拼、词组隐声/显声、关配/开配、关提/开提、扩展/常用字符集、隐表/显表、简体/繁体、半角/全角、中文/英文标点、**开频/关频（自动调频）**、**开想/关想（总联想）**、**带词库/纯历史**、**仅移动/双端**、**收起/空格（联想态空格 v5）**

---

## 四、命令基线（46 条，以 `lua/help_cmd.lua` GROUPS 为准，`/h` 可查）

| 组 | 命令 |
|---|---|
| 日期时间 | `/rq /sj /xq /dt` |
| 农历节气 | `/jt /jq /gz /nl` |
| 输入统计 | `/tj /qk /ks /js /tc` |
| 智能联想 | `/lxqk /lxql /lxzt /lxdj /lxdc /lxdr` |
| 候选调序 | `/txqk /txzq /txzj /txdc /txdr /txtj` |
| 自造词 | `/zctj /zcscNN /zccx /zcqk /zcdr` |
| 符号面板 | `/tg /dz /xh /bd` |
| 数字序号 | `/1 /2 /3 … /10`（含大写） |
| 帮助 | `/h /help` |

> 命名规则：`tx`=调序 `lx`=联想 `zc`=自造词，后两位取功能拼音首字母（`qk`=清空 `ql`=清理 `dc`=导出 `dr`=导入 `zt`=状态 `dj`=断句 `zj`=自检 `zq`=自清 `tj`=统计 `sc`=删除 `cx`=撤销）。**自造词 `/zcdr`＝从备份导入，与 `/lxdr`（联想导入）、`/txdr`（调序导入）同族**。
>
> ★ 自造词的「备份」不单设命令，与 `/zctj` 合用：有备份时摘要显示「有备份：共 N 条」。备份保险是**合并去重**——`/zcqk` 清空前把当前库并进备份（`user_coined_cmd.lua` 的 `backup_lines`），只追加备份里没有的词，备份永远是「历史所有造词的并集」、只增不减。数字不在 `speller.alphabet` 里，`/zcscNN` 的序号靠 `user_coined_cmd*P` 在 `/zcsc` 前缀下 `push_input` 接管；依赖两份主方案的 `coin_cmd: "^/zc[a-z]+[0-9]+$"` pattern。
>
> ★ `/zcsc` 序号**固定 2 位**（`01`~`99`）：`/zcsc` 输入即显示列表（与 `/zctj` 同款倒序，序号 2 位补零），`/zcsc0` 中间态保持列表，输满 2 位（`/zcsc01`）才删除。定长是为消除「输完即删」模型下变长序号的定界歧义（输 `1` 会被当成删第 1 条，永远没机会输 `12`）；`/zcsc00` 提示「序号从 01 开始」，越界提示「没有第 NN 条」。
>
> **新增/删除命令必须同步改 `lua/help_cmd.lua` 的 GROUPS 表**，否则 `/h` 帮助会漏。
>
> ⚠ `/zcscNN` 的 NN 要用户现打数字：因 `speller.alphabet` 不含数字，由 `user_coined_cmd*P` 在 `/zcsc` 前缀下用 `push_input` 接管数字键（与 `calc_symbol_processor` 接管算式符号同一套路），且只在前 2 位内接管、满 2 位即不再接管（防止 3 位）。若真机上数字被 App 层截走，兜底办法是把 `0-9` 加进 alphabet —— 但要评估 PC 端「数字选候选」的冲突，不优先。
>
> 2026-10-23 起的改名/增删：`/date`→`/nl`；新增 `/xh /bd`（符号面板）；移除 `/py`（自检）、`/lxgc`（联想衰减）、`/txql`（调序清理）；联想与调序各补 `/qk /ql /dc /dr` 全套。

---

## 五、已知问题台账（基线时点未关闭，按优先级）

| ID | 级别 | 问题 | 证据 | 建议 |
|---|---|---|---|---|
| B-01 | P1 | 「候选词动作执行失败: 未找到处理器: table」10 月累计 **1454 次**，10-17~10-20 持续复现 | keyboard error 日志 | 核对候选 collection/table 处理器名；本基线最大噪声源 |
| B-02 | P1 | `rime_tx_clear_stroke_filter: RefreshNonConfirmedComposition exception` 与 B-01 同时刻成对出现 | 同上 | 与 B-01 可能同根因；修复 B-01 后复验 |
| B-03 | P2 | `getForward failed: Error: the parameters check fails. length should no less than 0!` ×264 | keyboard 日志 | 空输入转发参数校验 |
| B-04 | P2 | `Failed to getEditorAttributeSync {"code":12800003}` ×68 | keyboard 日志 | 疑与 App 编辑器状态有关，需确认是否输入法侧可修复 |
| B-05 | P3 | `Panel is null ... FLOATING_PANEL`、`Failed to start vibration 14600101`、`to keyboard _schema_dir_board fail` 各数次 | keyboard 日志 | 低优先，汇总观察 |
| B-06 | P3 | LevelDB `LOCK ... Resource temporarily unavailable` 在 10-19 app 日志再度出现（8-29 亦有过） | app 日志 | 多实例/热重载抢锁；确认是否已随新部署消失 |
| B-07 | 文档 | README 声称存在但实际缺失：`key_bindings.yaml`、`default.custom.yaml`、`weasel.custom.yaml`、`ly_wubi_ly_pinyin(_14).schema.yaml`、`修改说明.txt` | 目录核对 | 以实际为准改 README 第七节 |
| B-08 | 文档 | 实际新增但 README 未记录：`custom_phrase.db/txt`、`predict.db`、`ly_pinyin_14.schema.yaml`、`help_cmd.lua`、`assoc_common.txt`、`installation.yaml`、各 `*.userdb` | 目录核对 | 同上 |
| B-09 | 文档 | ✅已解决：联想词库三处口径已统一为实测 **12,510 首字 / 12,510 条 / 278KB**（原 README 正文 4430字/42809条/253KB、表格 v3 4325字/28661条/135.5KB 均已修正） | 文件实测 | 已补规范：词库维护须登记实际统计 |
| B-10 | 代码 | 死代码：`input_stats_ly_wubi_14.lua`(994行) 与 `input_stats_ly_wubi_pinyin_14.lua`(461行) 及两个 `.bak` **无任何 schema 挂载**（统计实际走 `input_statistics.lua`） | 全库 grep | 确认可删，杜绝"改一处漏两处" |
| B-11 | 流程 | 测试资产未随库分发：README 引用的 `本次修改-回归测试清单.md`、`tools/sandbox_s100_predictdb.py` 均不在本副本 | 全库查找 | 回归测试清单应作为受控文件纳入（建议 `dev/tests/`） |
| B-12 | 版本 | ✅已解决：README v2.3 / 2026-10-24 与 BASELINE 一致；space.custom.yaml 当前 `schema_id=ly_wubi`/`26key_wubi` 为用户临时切换，非固定口径。**info.yaml version 保持 `"2.0"` 不参与同步**——见 B-14 | 文件比对 | 发版 checklist：README、space.custom.yaml、BASELINE 三处同步 |
| B-14 | 版本 | ⛔ **`info.yaml` 的 `version: "2.0"` 禁止修改**（2026-10-25 事故）：该字段供输入法识别方案，10-24 误改为 2.3 导致方案导入输入法后不认，用户已手动回退 `"2.0"` | 用户反馈 + 文件实测 | 版本演进只记 README / BASELINE / space.custom.yaml；info.yaml 仅可改 `update_time` |
| B-13 | 资产 | `14key_wubi/build/` 存在（含编译产物），`26key_wubi/` 无 build——两侧不一致；旧字体（新建文件夹 14 个 ttf）未纳入 fonts | 目录比对 | 明确 build 目录管理策略；字体确认是否还需要 |

---

## 六、后续拓展/优化的操作规则（基线之上）

1. **每次改动前**：先在本文件对应章节更新"预期变更"，改完在第八节追加记录（日期/改动/影响面/回归结论）。
2. **回归最小集**（改 lua/schema/词典必跑）：
   - 四方案 × 基本输入（简码/全码/词组/自造词/反查）
   - 14 键双键模糊 + 第五码筛选（打满 5 码）；候选分层（1码3/2码6/3码5）
   - 联想链：学习→断句→逐级→`/lxzt` 自检；衰减（`/lxgc`）
   - 调频：自动（连续两次才生效 `/txzj` 验证）+ 手动（数字键/Ctrl+J）
   - 计算器：`=` 模式、退格、算式错误（=1+abc）、小于 1、大写金额
   - 16 个开关 × 开/关组合抽查
   - 标点主链：有候选跟随上屏 / 无候选候选菜单 / 上滑下滑 / 手机端屏蔽 `;` `'`
   - PC 端专属：`;` `'` 二选三选、Ctrl 调频、Emacs 键
3. **部署三件事**：覆盖+重新部署 → 切一次方案 → 改过主题删 `themes/<t>/build/`。
4. **新功能默认只动移动端**：主题层改动不影响 PC；改 schema/lua 必须同时评估两端。
5. **发版同步**：README、space.custom.yaml、本基线，**三处**版本口径一致。⛔ **不含 `info.yaml` 的 `version`**（输入法识别用，固定 `"2.0"`，改则导入后不认，见 B-14）；info.yaml 只同步 `update_time`。
6. **日志例行检查**：每次部署后看 `log/keyboard` 与 `log/app` 的 error，新错误须入台账。

---

## 七、变更记录

| 日期 | 变更 | 影响面 | 回归结论 |
|---|---|---|---|
| 2026-10-21 | 建立基线（v2.3 对照） | 无代码改动 | 发现问题 B-01~B-13，待排期 |
| 2026-10-21 | **仓库重构**：git 根从 `D:\AutophotiaIME` 移入 `dev/space/schemas/TouchWB`，只追踪方案本体 79 文件 / 19M；根目录 merge 污染 19 文件已备份至 `dev/legacy-remote-b2faab1-backup.zip` 并清理；旧 `.git` 归档为 `.git-legacy-old` | 仅版本控制，无代码改动 | 新仓库首提交 `89d7af3`；待 force push |
| 2026-10-21 | 新增 `dev/tools/pack-release.sh` 打包脚本，产出首个发布包（8.3M） | 无代码改动 | 序号/日期/排除规则验证通过 |
| 2026-10-21 | **打包规则重定制**：以 `releases/TouchWB_S117_2026-10-16.zip` 为唯一基线——zip 内带 `TouchWB/` 根目录、`build/default.yaml` 仅含 schema_list 四项、排除 user.yaml/userdb/死代码 sequence 与 input_stats/themes public/任何层级 build/ | 无代码改动 | 新包与参考包**逐文件一致（62/62）** |
| 2026-10-21 | **包名规则修正**：`TouchWB-<序号>-<日期>.zip` → **`TouchWB_S<序号>_<YYYY-MM-DD>.zip`**（README 2026-10-08 条目早有此规则，S 编号为构建序号，117→118） | 无代码改动 | 产出 `releases/TouchWB_S118_2026-10-21.zip` |
| 2026-10-21 | git 推送完成：设备码授权 + 代理（127.0.0.1:7890）force push，远端 main = `89d7af3`，GitHub 上 79 个纯方案文件，旧版 `b2faab1` 已覆盖 | 仅版本控制 | 令牌已删、未落盘 |
| 2026-10-21 | **本文档上传资料库**（方案B，用户选定）：`TouchWB-BASELINE-v2.3-20261021.md` → 空间 `mIrqzsLc4wuPA4XyDa9Wrg`，供另一台设备（beyondIME）获取 | 文档分发 | 上传后 library_search 验证可检索 |
| 2026-10-21 | **README 口径修正（9 处）+ 仓库卫生**：删除声称存在但不存在的 default.custom.yaml/key_bindings.yaml/weasel.custom.yaml；schema 错名 ly_wubi_ly_pinyin*→ly_wubi_pinyin*（4处）；联想库三处口径统一为实测 12510 首字/12510 条/278KB；predict.db 从"不要打包"移入"必需"（S117/S118 实际均含）；目录树/附录补记 installation.yaml/custom_phrase.txt/predict.db/ly_pinyin_14/help_cmd.lua/assoc_common.txt；user.yaml 与 lua/input_stats_ly_*.lua 移出 git 追踪+gitignore（运行时状态，每次手机同步产生假变更；磁盘文件保留） | 文档 + 版本控制，无功能代码改动 | 提交 `6b0dc1d` 已推送；README 与实际文件 grep 双向验证通过 |
| 2026-10-21 | **真机日志复审 + B-01 根因实锤**：`未找到处理器: table` 9465 次 = 同文 App 对每个 table 候选上屏后执行 actionType=候选类型的后置命令、未注册处理器即报错，**文本总是先插入成功**（22/22）⇒ 定性为 App 端固有噪声，功能无损，从"待修 Bug"降级"已知噪声"；"打字慢"实锤在极点86笔画筛选路径（1261ms），TouchWB 引擎最慢 88ms；**schedule.lua 误判纠正**：generate_candidates 实定义于 `lua/lib/lunar.lua:1584`（全局函数，随包分发），用户实测 /rq /xq /dt /tj 全部命令成功 | 无代码改动 | 命令实测通过（最慢按键 79ms）；静态分析误判已以实测证据推翻并记入记忆 |
| 2026-10-22~24 | **字典越级清理**：删 413 条越级条目（6 条 tf 伪二码：千/午/壬/竺/竿/秆 + 407 条权重 482785 批量伪二简），主词库 148222→147815 条；「行 tf」权重手动上调至 4097390 | 词典 | 越级简码全清、全码完好，排序回归通过 |
| 2026-10-24 | **README 第 12 节输入统计口径修正**（997/1023 行）：只统计按编码上屏，排除点联想/复制/语音；头部更新日志补 2026-10-24 段；opencc 目录树修正 | 文档 | 口径与实际一致 |
| 2026-10-24 | **info.yaml 版本同步**：2.0→2.3、update_time 2026-10-24，与 README v2.3 一致（B-12 关闭） | 版本 | ⚠ **此改动为错误操作，已于 10-25 回退**，见下条 B-14 |
| 2026-10-24 | **git 根上移至 dev/space**（fast-forward，`fbbe016`），TouchWB 文件迁移到 schemas/TouchWB/ | 版本控制 | 历史延续，未 force push |
| 2026-10-24 | **patches 补丁集纳入版本管理**（`51c9b5b`）：dev/space/patches 76 文件入 git；独立补丁 zip 备份至 patches/_backup_20261023/ | 版本控制 | 追踪 154 文件/26M |
| 2026-10-24 | **git 根二次上移至 `dev/`**（`968a0d5`，fast-forward）：`dev/docs`（3）+ `dev/tools` 脚本（4）+ dev 顶层计划文档（3）纳入追踪 | 版本控制 | 追踪 151→**161 文件/26M**；docs 恢复随 git 上云 |
| 2026-10-24 | **方案一（古诗文联想脚本）放弃**：assoc_common.txt 字频表错位无法识别难拆字，产出 10301 条但 71% 虚词污染；删除 chinese-poetry 语料（466M） | 决策 | 联想功能维持现状，语料已清 |
| 2026-10-24 | **BASELINE 过时口径修订**：2.1 目录图 / 四节命令表（以 help_cmd.lua GROUPS 为准）/ 八节代理 7890→socks5h:1080 / 打包 62→61 / git 79→154 全部按实测更新 | 文档 | 本次修订 |
| 2026-10-25 | **项目文档全部收进 `dev/docs/`**：原 `dev/` 顶层 3 份计划文档（App场景感知调研 / 简码越级检查报告 / 联想增强方案）移入 docs，共 6 份 | 版本控制 | 追踪仍 161 文件，路径变更 |
| 2026-10-25 | **项目指令升级 v14**（误命名的 v8 已作废删除）：基线是 v13（此前只存在于会话产物目录未落盘），补 git 根 `dev/`、docs 6 份、追踪 161/26M、HEAD `d762a15`；新增「根上移既定做法」「历史断层」「换机重建三步」，沿用 v13 的 Skill 配置节与产物上传规则 | 文档 | **v14 为现行**，v13/v7 留档 |
| 2026-10-25 | **版本纪律事故**：v8~v13 由 10-24 会话产出但只落在 `C:\Users\xoaii\WorkBuddy\2026-10-23-14-08-15\`，未写进 `dev/docs/`，导致后续按磁盘 v7 臆断版本号。已写入 v14 第 8 节第 7 条 | 流程 | 新增版本须先全盘检索确认 |
| 2026-10-27 | **自造词删词 + 备份导入**：新增 `lua/user_coined_cmd.lua`（571 行，P/T/F 三件式），五命令 `/zctj` 统计（摘要含备份条数）+倒序列表、`/zcscN` 按序号删、`/zccx` 撤销末条、`/zcqk` 清空（自动备份，合并去重）、`/zcdr` 从备份合并导入（只补缺，与 `/lxdr`/`/txdr` 同族）。Submit_text.lua 补 `UserCoined_InvalidateCache` 钩子；4 份 schema 挂载 + 2 份主方案加 `coin_cmd` recognizer pattern | 新功能 | 命令 41→46 条；沙盒 16 用例全通过；**待真机验证数字键接管与 /zcdr 恢复** |
| 2026-10-27 | **备份设计（同上功能，口径定案）**：备份不单设命令，与 `/zctj` 合用显示「有备份：共 N 条」；单份 `.bak`；备份文件首行写 `# 备份时间：…`（Lua 无 lstat 取不到文件时间）；`/zcdr` 恢复按正序写回，保持「末行=最新」的序号语义 | 设计调整 | 覆盖同日较早的 7 条 `zcbf` 族方案 |
| 2026-10-27 | **删词序号固定 2 位**：`/zcsc` 改为输入即显示词条列表（带 2 位序号 `01`~`99`），输满 2 位才删；弃变长 `/zcscN`——「输完即删」模型下变长序号有定界歧义（输 `1` 即被当删第 1 条，无机会输 `12`）。P 数字接管限 2 位上限；`/zcsc00` 提示「序号从 01 开始」；`/zctj` 列表序号同步 2 位补零。模块 571→606 行 | 交互调整 | 沙盒 22 用例全通过 |
| 2026-10-25 | **info.yaml version 回退（B-14）**：10-24 把 `version: "2.0"` 改成 2.3，导致方案导入输入法后**不被识别**；用户已手动改回 `"2.0"`（update_time 保留 2026-10-24）。该字段供输入法识别，禁止修改 | 事故回退 | 版本演进只记 README / BASELINE / space.custom.yaml；已写进 v14 铁律第 6 条 |
| 2026-10-29 | **自动连词造词功能上线（路线 A，默认关）**：新增 `lua/auto_coined.lua`（声笔式自动连词造词），连续上屏相邻 2~5 字自动组临时词（`user_coined_auto.txt`，格式 `词条<Tab>编码<Tab>temp:N`），整码精确匹配才浮现候选（带 ☯），召回上屏一次即转正入 `user_coined_ext.txt`。开关 `auto_coined`（默认关）。**真机 6 轮复测修复**：① 上屏文本改 `commit_history`（二/三级简码「二=fg」不再错造「地」）；② 词组边界 4s→20s（首字尤其生僻字入链）；③ processor 顺序 `auto_coined` 前移到 `Submit_text` 前 + 空格即时入链（末字停手入链）；④ temp 行显示修复（`is_temp_file` 区分）与转正去重修复（只查手动库 `not e.temp`）；⑤ 纯汉字判定正则重写（`gsub` 剥字，多字词不误判非中文）；⑥ 懒加载全量单字字典（消除造词后按键卡顿）。README v2.3→v2.4、更新日期 2026-10-29；info.yaml `update_time` 2026-10-29（`version` 禁改不动）；打包脚本 pack-release.sh 排除 `user_coined_auto.txt`、文件数 61→62 | 新功能 + Bug 修复 | 真机验收通过（造词/转正/末字入链/简码不错字/无卡顿），DEBUG_LOG 已关回 false |
| 2026-10-29 | **英文打字兼容性（已知限制，非方案问题）**：中文键盘切英文后，非原生输入框（H5/Flutter/RN 自绘）只能输 1 个字母、后一个顶掉前一个；官方方案同样复现，开发者确认「非原生输入框不支持系统特性」。根因是 IME `setComposingText` 预编辑组合区机制在非原生输入框不受支持。属平台/引擎层兼容性范畴，方案侧无法干预，记录为已知限制 | 无代码改动 | 维持用户与开发者判断 |
| 2026-10-30 | **自动连词造词三处修复（v2.5）**：① **不再重复造主词典已有词**——`Submit_text.lua` 全量字典懒加载里同一遍扫描多登记一份「多字词集合」并暴露 `auto_coined_in_main_dict`，`auto_coined.lua` 的 `build_phrases` 造临时词前先查它，主词典（ly_wubi.dict.yaml）已收录的「数据/最好/造词/编辑」等不再生成临时词（字典加载失败自动退化为照旧造词，绝不漏造）；② **点击候选栏上屏也参与造词**——`auto_coined.lua` 接入 `update_notifier`（点候选栏 = `Context::Select`，不产生按键事件），点选上屏当场结算入链，空格/数字/点选/快捷键四种上屏方式全覆盖，与 `super_sequence.lua` 的 auto_freq 同款机制，共用 `_last_size/_last_back` 天然去重不重复结算；③ **注释头粘行修复**——`UserCoined_AppendManual` 转正写入由后缀换行改前导换行，与手动 `fileappendtext` 逐字节一致，文件头三行后自然空出第四行，`/zcqk` 等整文件重写后不再粘行。顺带修复 `for in f:lines()` 循环变量赋值（Lua 5.4+ for-in 变量只读），`Submit_text.lua`/`auto_coined.lua` 共 3 处转一道。README v2.4→v2.5、更新日期 2026-10-30；info.yaml `update_time` 2026-10-30（`version` 禁改不动）；新增 `tools/sandbox_auto_coined_test.py` 专项沙盒测试 | Bug 修复 + 新能力 | 沙盒全通过（主词典判定 9 例 / 前导换行 2 例 / 点选入链 + 去重 + 不重复结算）；主词典去重待真机验证 |
| 2026-10-30 | **自动/手动造词第二轮修复（v2.6）**：① **临时词补齐跨界子词**——`auto_coined.lua` 的 `on_commit` 把提交文本按字拆分入 `_hist`（旧实现整词作最小单元，逐词上屏时被主词典过滤的词无法拆字与相邻字组合，缺「词功能/造词功/自动造词功」等字级窗口），`build_phrases` 起点固定 1（旧公式 `max(1,n-4)` 在 `_hist` 满 6 字时跳过头字、丢 5 字窗口）；② **手动造词支持点击候选栏上屏**——`Submit_text.lua` 新增 `coin_hook_notifier` 接 `update_notifier`，模块级 upvalue 预登记手动造词状态，点候选栏上屏后结算保存，空格路径与 notifier 路径互斥去重；③ **两个 txt 注释头一致**——`auto_coined.lua` 的 `write_rows` 头三行后补第四行空行，与手动词库一致。README v2.5→v2.6；新增 `tools/sandbox_coined_v23_test.py` | Bug 修复 | 沙盒全通过（字级窗口 11 例 / 空行 / 点选保存 + 不重复保存）；既有两个沙盒测试回归通过 |
| 2026-10-31 | **手动造词改用魔然式「翻页选字」（v2.7）**：① **修复点选候选栏上屏造词失效（根因实锤）**——旧「`编码`编码」由 `mkst` 翻译器 `enable_sentence: true` 合成整句 sentence 候选，手机前端 bimkit 点它走 `InsertTextCommand` 直接插文本、绕开 Rime 引擎 `Context::Select`/`update_notifier`（真机日志 `InsertTextCommand 插入文本` + `未找到处理器: sentence`），点选上屏永远保存不了；关闭 4 套 schema（ly_wubi/ly_wubi_14/ly_wubi_pinyin/ly_wubi_pinyin_14）的 `enable_sentence`，改由 `user_coined_translator` 用 `compose_coin` 把反引号编码串合成**普通候选**（quality 950 默认 + 700 翻页备选），点选/空格统一走 `Context::Select → update_notifier → coin_hook_notifier` 转正；② **魔然式翻页选字**——`Submit_text.lua` 懒加载字典时顺带构建两个编码索引 `char_dict_codes`（编码→单字重码，上限 `CODE_CAP=12`）+ `char_dict_phrase_codes`（编码→多字词），新增 `lookup_code_chars`（精确码优先、前缀补全兜底、按权重降序，部分码绕开不会打的字）、`lookup_code_word`、`compose_coin`（合成默认词 + 单点替换摊平翻页备选，去重）；③ **词码优先**——4 码既是多字词码又是生僻单字全码时取词（`rtfc`=手动 优先于 㪏），兼容老用法「`rtfc`tfyn」；删除旧 `handle_manual_coin` 空格直拼码上屏路径，统一走普通候选。README v2.6→v2.7、更新日期 2026-10-31；info.yaml `update_time` 2026-10-31（`version` 禁改不动）；新增 `tools/sandbox_coin_compose_test.py`（8 用例） | Bug 修复 + 新能力 | 沙盒 8 用例全通过（精确码/前缀补全/组合+翻页选字/整词码/重码替换/部分码/查不到编码/提交转正+去重）；`sandbox_auto_coined_test`/`sandbox_coin_cmd_test`/`sandbox_coined_v23_test`/`sandbox_coined_test` 四套旧测试回归全通过；**待真机验证翻页选字与点选造词** |
| 2026-10-31 | **手动造词改回徐码式「逐字翻页选字」（v2.8，推翻 v2.7）**：真机验证 v2.7 全面失败——① 一造词就卡（`compose_coin` 每键扫 `char_dict_codes` 索引）；② 造词不成功（真机日志 `[COIN:ntf] skip: size=X != pend+1=Y` 反复出现，`size == pend+1` 绝对差值被每键 update_notifier 漂移 + `commit_history:back()` 滞后一拍打穿）；③ 点非第一候选直接上屏整词、中断造词（一次性合成无逐字锁定）；④ 只能两组编码 / 第三位无候选（手动 `gmatch("[a-y]+")` 分段与五笔 1~4 位不定长编码不兼容）。**修复**：恢复 4 套 schema（ly_wubi/ly_wubi_14/ly_wubi_pinyin/ly_wubi_pinyin_14）`mkst.enable_sentence: true`，由 `table_translator@mkst` 原生吐徐码式「逐字翻页选字」sentence 候选；删除 `compose_coin`/`lookup_code_chars`/`lookup_code_word` 及 `char_dict_codes`/`char_dict_phrase_codes`/`CODE_CAP` 索引（`build_dicts` 回到只构建 dict+phrases，首次 513ms→462ms 回基线，消除卡顿）；`coin_hook_notifier` 改用 super_sequence 定稿三判据（size 变 / back 文本变 / 输入码非空变空+闩锁）结算保存；删除作废的 `tools/sandbox_coin_compose_test.py`。README v2.7→v2.8、更新日期 2026-10-31；info.yaml `update_time` 维持 2026-10-31（`version` 禁改不动） | Bug 修复（方案方向回退+重设计） | 4 套旧沙盒测试（`sandbox_coined_test`/`sandbox_auto_coined_test`/`sandbox_coin_cmd_test`/`sandbox_coined_v23_test`）回归全通过；`Submit_text.lua` 语法通过；**待真机验证逐字翻页选字 / 保存 / 无卡顿 / 三组以上编码** |
| 2026-10-31 | **手动造词「逐字翻页选字」改「逐字上屏 + 累积保存」（v2.9，推翻 v2.8 的逐字部分）**：真机复测 v2.8 的逐字选字仍不可用——bimkit（鸿蒙前端）点候选栏 = 一次性上屏整个预编辑串（`InsertTextCommand`），徐码原版「输入 `rs'ea'poz'zb` 后依次选字」依赖的**多段组合 + 段间导航**在 bimkit 上做不出：① `enable_completion` 关闭时 `` `rt `` 只精确命中「手」一个字、无重码可翻；② 点非首候选直接上屏整词、中断造词；③ 无法锁定前一段继续下一段。**修复（顺势适配 bimkit「点候选=整段上屏」）**：① 4 套 schema `mkst.enable_completion: false→true`，反引号编码出**单字重码**（绕开不会打的字的核心）；② `Submit_text.lua` 新增逐字缓冲 `_coin_buf`/`_coin_code_buf`，notifier 区分「单字上屏（逐字累积）」vs「整词上屏（直接保存，`utf8.len>1`）」；③ 空格 + 无候选时把缓冲合并成整词落盘（`fileappendtext`，字典优先取标准码、降级用累积的反引号编码段）；④ 输入非反引号内容 ⇒ 放弃缓冲。整词路径（v2.8 已可用）保持不变。README v2.8→v2.9、更新日期 2026-10-31；info.yaml `update_time` 维持 2026-10-31（`version` 禁改不动）；新增 `tools/sandbox_coin_v29_test.py`（4 用例：逐字累积 / 空格保存 / 放弃 / 整词） | 交互重设计（适配 bimkit 前端） | 5 套沙盒测试（含新增 v29）全通过；4 套 schema YAML 合法；**待真机验证逐字翻页选字 + 空格保存 + 整词路径不回归** |
| 2026-10-31 | **手动造词结束键「空格」改「再次长按Z」（v2.10）**：真机复测 v2.9 的「空格结束」不可用——逐字选完字后候选栏有**智能联想**（`lua_translator@*smart_assoc*T` 在空段吐联想候选），按空格会上屏联想候选、而非触发「造词结束」，缓冲永远无法合并落盘（「搬运/大概/个性」三个逐字词都没合成新词）。**修复**：① `Submit_text.lua` 结束键改「再次长按Z」——因单次长按Z 与「开始下一个字」的长按Z 无法区分（都是「反引号后跟编码」），故用**连续两次反引号 `` `` ``** 唯一表示结束（单次长按Z + 紧跟编码 = 下一个字，连续两次长按Z = 结束并保存）；② 新增 `is_backtick_key`（`key:repr()`=grave/`/quoteleft/backquote 或键码 0x60，忽略抬起事件）+ `_coin_prev_backtick` 状态；③ 删除「空格 + 无菜单」结束分支，改「缓冲非空 + 连续两次反引号」保存并 `context:clear()` 清残留。整词路径（空格/点选）不受影响。README v2.9→v2.10、更新日期 2026-10-31；info.yaml `update_time` 维持 2026-10-31（`version` 禁改不动）；测试 `tools/sandbox_coin_v29_test.py` → `tools/sandbox_coin_v210_test.py`（4 用例：逐字累积 / 双反引号结束 / 放弃 / 整词） | Bug 修复（结束键改键） | 5 套沙盒测试（含 v210）全通过；`Submit_text.lua` 语法通过；**待真机验证双反引号结束 + 逐字翻页选字 + 整词路径不回归** |
| 2026-10-31 | **手动造词结束键改回「空格」+ 修单字进不了缓冲（v2.11）**：真机复测 v2.10 两点失败——① 「连按两次长按Z」第二次按 Z 无反应（反引号是**文本注入**、不产生按键事件，`key.keycode` 拿不到 0x60，结束分支永不触发）；② 「单字无法进入造词，仅两字及以上可参与」——根因是 notifier 的「输入码非空变空」判据③在 bimkit 点选上屏时会在「清空 composition 但尚未 commit」那一拍就误触发：此刻 `commit_history:back()` 还是上一条旧文本，既误结算、又提前消费掉 `_coin_pending_input`，等真正 commit 单字时 pending 已空，单字永远进不了缓冲。**修复**：① 结束键改回空格——实测「按空格 = 上屏一个空格」（并非上屏联想），在 `commit_text_processor` 加「空格键 + 缓冲非空 ⇒ 合并保存并吞空格」独立分支；② `coin_hook_notifier` 判据改回 auto_coined 的 `size 变 / back 文本变` 双判据，废弃 super_sequence 的「输入码变空」判据③，并加「back() 未就绪（nil）时不消费 pending、等下一拍」——单字上屏可靠累积进缓冲；③ 删除 `is_backtick_key`/`_coin_prev_backtick`/`_coin_prev_code`/`_coin_empty_latched` 及「连续两次反引号」结束逻辑。README v2.10→v2.11、更新日期 2026-10-31；info.yaml `update_time` 维持 2026-10-31（`version` 禁改不动）；测试 `tools/sandbox_coin_v210_test.py` → `tools/sandbox_coin_v211_test.py`（4 用例，新增模拟 bimkit「先清空 composition、再 commit」两步时序） | Bug 修复（结束键回退 + 单字累积修复） | 5 套沙盒测试（含 v211）全通过；`sandbox_coined_v23_test` 补「稳定基线」mock 后回归通过；4 套 schema YAML 合法；**待真机验证空格结束 + 单字逐字累积 + 整词路径不回归** |
| 2026-10-31 | **手动造词「单字/词组一律累积」+ 结束键改「长按Z再按空格」（v2.12）**：真机复测（之/田/回到家/吃饱）定位 v2.11 两个真正根因——① **「整词直接保存」分支误清空单字缓冲**：notifier 里 `n > 1` 时直接落盘并 `_coin_buf = {}`，导致已累积的单字「之田」被后续词组「回到家」的保存静默 wipe 掉，单字看似「没参与造词」、词组独立成词、无法组合（真机日志 `buf+1 [之]`→`buf+1 [田]`→`OK整词 [回到家]` 后缓冲被清空）；② **空格结束与联想候选上屏争抢**：逐字选完字后候选栏有联想，按空格会上屏联想而非触发结束。**修复**：① notifier 删掉 `n > 1`「整词直接保存」分支及其 `_coin_buf = {}` 清空，单字（n==1）与词组（n>1）一律 `_coin_buf[#+1] = bt` 累积，最后由结束键统一合并成整词落盘——「之+田+回到家+吃饱」合成「之田回到家吃饱」一个词；② 结束键改「长按Z（`）再按空格」——输入区为纯反引号 `` ` `` + 空格 = 保存（`input_text:match("^`+$")`），与「空格上屏联想/编码候选」天然不冲突（联想时 input 空、编码时 input 含字母），放在 `has_menu` 分支之前优先判定，保存后 `context:clear()` 清残留并吞空格；③ 加诊断日志 `[COIN:end] space buf=N input=[...] 未匹配^`+$`。README v2.11→v2.12、更新日期 2026-10-31；info.yaml `update_time` 维持 2026-10-31（`version` 禁改不动）；测试 `tools/sandbox_coin_v211_test.py` → `tools/sandbox_coin_v212_test.py`（5 用例：单字累积 / 词组累积 / 非纯反引号空格不结束 / 长按Z空格保存 / 放弃）；`sandbox_coined_v23_test.py` 同步「整词直存→累积+结束」断言 | Bug 修复（累积逻辑统一 + 结束键改键） | 5 套沙盒测试（含 v212）全通过；`Submit_text.lua` 语法/配平通过、行尾 LF 无假红；**待真机验证「之/田/回到家/吃饱」合成一词 + 长按Z再按空格保存** |
| 2026-10-31 | **移除原手动造词「一次性整词保存」行为（v2.13）**：真机验收 v2.12 成功——单字/词组最终组合成新词（日志 `buf+1 [之]`→`[之喝]`→`[之喝加紧]`→`[之喝加紧瞧不起]` + `[COIN:end] OK` 落盘 `user_coined_ext.txt`），同时确认「原手动造词行为」已失效。分析结论：**无必要保留，正式移除**。原行为 = ① 早期「词条`编码」→ 空格直接落盘；② 「编码`编码 → 选候选 → 空格确认」一次性整词直接保存——两者代码在 v2.7~v2.12 已删净（`handle_manual_coin`/`compose_coin`/notifier `n>1` 整词直存分支），真机已无法触发，仅剩 `Submit_text.lua` 文件头注释残留旧描述。**为何不留**：新逻辑（逐字/词组累积 + 长按Z再按空格）是原行为的**功能超集**（旧「一次性整词」= 新逻辑「累积单个词组 + 结束」的特例），且 v2.11 已证明双路径并存会互相干扰（整词直存清空累积缓冲），保留只会重新引入风险。**清理**：更新 `Submit_text.lua` 文件头第 14/38 行过时注释；`user_coined_translator`（自造词即时查询）/`UserCoined_AppendManual`（自动临时词转正）/`splitinput`（降级编码）三者非旧行为、继续保留。README v2.12→v2.13、更新日期 2026-10-31；info.yaml `update_time` 维持 2026-10-31（`version` 禁改不动） | 代码清理（移除失效旧行为） | 5 套沙盒测试全通过（含 v212）；`Submit_text.lua` 语法通过；**双造词真机验收通过（手动逐字累积合成新词 + 自动造词无新问题）** |
| 2026-10-31 | **手动造词反引号段支持拼音筛字 + 自动造词确认支持拼音/五码筛选上屏（v2.14）**：回应「造词只能纯五笔、拼音无法参与」诉求。核心机制澄清：**造词编码一律由 `generate_standard_code`（字典「字→码」反查）生成，与上屏方式无关**——只要字上屏进缓冲/入链，就能反查出标准五笔码。**手动造词拼音筛字**：混输方案（ly_wubi_pinyin / ly_wubi_pinyin_14）新增 `table_translator@mkst_pinyin`（挂 ly_pinyin 词典，`prefix:"`"`、`tag:mkst`，与五笔 `mkst` 共用同一反引号段，`initial_quality:400` 低于五笔 450），长按Z 后既能输五笔码（`` `rt `` 选「手」）也能输拼音（`` `shou `` 直接命中「手」），「不会打的字」从「输前几码翻页」升级为「输拼音直接命中」；`wubi_pinyin_filter` 反引号分支对拼音候选的 `matches_prefix` 天然放行（拼音码逐位匹配输入串），无需改；保存码仍反查五笔码（`` `shou `` 选「手」→ 存「手动 rtfc」，非拼音串）。**自动造词**：`auto_coined` 上屏检测（`get_commit_text`/`commit_history`）与编码生成（字→码反查）均不看输入方式，拼音打字上屏、五笔+第五码拼音筛选上屏的字都能入链造临时词（此前被误判为「只能五笔」）。README v2.13→v2.14、更新日期 2026-10-31；info.yaml `update_time` 维持 2026-10-31（`version` 禁改不动）；新增 `tools/sandbox_coin_pinyin_test.py`（3 用例：编码反查 / 自动造词拼音上屏 / 手动造词反引号段拼音筛字） | 新能力（拼音参与造词） | 6 套沙盒测试全通过（含新增 pinyin）；4 套 schema YAML 合法；**待真机验证反引号段输拼音出候选 + 拼音上屏造词** |
| 2026-10-31 | **修反引号段第五码被当五笔 + 放宽断链阈值 + 缓解临时词转正撞码（v2.15）**：真机复测 v2.14 三点——① **手动造词第五码被当五笔而非拼音**：`wubi_pinyin_filter.lua` 反引号分支在 `pure_code_len==5` 分支之前就 `return`，第 5 码拼音筛选逻辑被绕过，5 位全当五笔逐位匹配、候选编码最多 4 位 ⇒ 第 5 位永远匹配不上、候选被误杀；修复：反引号段 `pure_code_len==5` 时走「前 4 码五笔匹配 + 第 5 码拼音首字母筛选」（复用 `matches_prefix(n=4)` + `build_pinyin_filter_set`/`get_pinyin_initials`/`initials_hit`，与普通输入第 5 码语义一致），`` `rtfcs `` = 手动(rtfc) + s 能筛出「手动」。② **「朝廷」被过滤 + 无带朝廷相邻组合**：朝廷/金星/测度/千千静听/接单/造词/效果这些词**本身在主词典**（fjtf/qqjt/imya/ttgk/ruuj/tfyn/uqjs），被「主词典去重」正确过滤（非 bug）；「品饮朝廷」「朝廷金星」等相邻组合没造出来，是因拼音翻候选停顿 25~44s、超 20s 断链阈值被误切断链；修复：`auto_coined.lua` `PHRASE_GAP_SEC` 20s→**120s**。③ **临时词转正难**：临时词编码与主词典高频词撞码（品饮 kkqn vs 咖啡馆 kkqn；金星千 qjtf vs 久旱逢甘雨 qjtf；测度造词 iyty vs 注入/流入 iyty），输入编码召回时主词典词抢占前排、☯ 被顶到后页；修复：临时词 exact_match quality 800→950（与手动词同优先级）。另澄清转正机制：临时词转正**不一定要输五笔码**，用拼音再打一遍同一个词（上屏文本命中 `e.text==text`）同样转正。`auto_coined.lua` `DEBUG_LOG` 临时开 true 抓日志。README v2.14→v2.15、更新日期 2026-10-31；info.yaml `update_time` 维持 2026-10-31（`version` 禁改不动） | Bug 修复（反引号段第 5 码 + 断链阈值 + 撞码缓解） | 6 套沙盒测试回归全通过；`wubi_pinyin_filter.lua`/`Submit_text.lua` 语法配平通过；**待真机验证反引号段第五码拼音筛选 + 120s 断链 + 撞码召回转正** |
| 2026-10-31 | **修反引号段纯反引号吐候选破坏结束键 + 第五码点选残留（v2.16）**：真机复测 v2.15 两点是 `wubi_pinyin_filter.lua` 反引号分支的回归——① **纯反引号（长按Z）冒出「的、一、是、我」破坏结束键**：`pure_code_len==0` 时旧代码 `yield` 全部候选，而 `mkst`（`enable_completion:true`）对空编码吐高频单字 ⇒ 「长按Z再按空格=结束造词」时候选栏非空、按空格上屏第一候选而非触发结束；修复：`pure_code_len==0` 时直接清空候选（无编码字母本无匹配语义），恢复结束信号态。② **反引号段第五码点选残留成「接单d」**：`` `ruujd `` 的候选（接单）五笔匹配只吃掉前 4 码 `` `ruuj ``（span 0..5），第 5 码 `d` 不在候选 span 内 ⇒ 点选后引擎提交「接单」却把 `d` 残留回编码栏；修复：反引号段 `pure_code_len==5` 时把候选 span 拉满到整串输入（含反引号 0..6，`clone_candidate(cand, 0, #input_str, ...)`），第 5 码一并消费、点选正常上屏。③ **临时词召回诊断**：`user_coined_translator` 精确命中临时词时打 `[COIN:recall]` 日志，配合排查「不能用五笔编码转正」。新增 `tools/sandbox_filter_v216_test.py`（3 用例：纯反引号无候选 / 第五码 span 拉满 / 4 码不回归）。README v2.15→v2.16、更新日期 2026-10-31；info.yaml `update_time` 维持 2026-10-31（`version` 禁改不动） | Bug 修复（反引号段结束键 + 第五码 span） | 7 套沙盒测试全通过（含新增 filter_v216）；`wubi_pinyin_filter.lua`/`Submit_text.lua` 语法配平通过；**待真机验证长按Z再按空格结束 + `ruujd 点选不残留 + 撞码召回转正** |
| 2026-10-31 | **修 new_spelling 覆盖 user_coined comment 致自造词召回失败（v2.17）**：filter 链最前端 `new_spelling.lua` 隐根/显根模式用 `get_tricomment` 覆盖 `user_coined` 候选 comment（「编码☯」→「〈pin·yin·ke〉·〈rusk〉」），下游 `wubi_pinyin_filter` 提取编码误取拼音 ⇒ 自造词「写入成功却打不出来」。修复：对 `cand.type=="user_coined"` 早退原样 yield（显根/隐根两处），不覆盖 comment、不占注解名额。新增 `tools/sandbox_newspelling_coin_test.py`（3 用例）+ 反向验证（git show HEAD 恢复旧版失败）。README v2.16→v2.17、更新日期 2026-10-31；info.yaml `update_time` 维持 2026-10-31（`version` 禁改不动） | Bug 修复 | 沙盒 3 用例全通过 + 反向验证通过；6 套回归全通过；**待真机验证手动词/临时词按编码召回** |
| 2026-10-31 | **手动造词拼音/五码筛选不参与造词（v2.18，部署根因非代码 bug）**：反引号段拼音筛字 `table_translator@mkst_pinyin`（挂 ly_pinyin、`prefix:"`"`、`tag:mkst`）是 10-31 加到源 schema 的，但真机加载 build 产物 + S124 包（10-29）不含它，`mkst enable_completion:true`（v2.9）也未部署 ⇒ 逐字翻页选字/第五码筛选缺料、手动造词退回纯五笔。修复：重打包 `TouchWB_S125_2026-10-31.zip`（验证含 mkst_pinyin 段 + enable_completion:true），部署 S125（schema 必须同步）+ 清 build 缓存/切换方案。真机验收：五笔/拼音/五码筛选上屏均能造词并召回。README v2.17→v2.18、更新日期 2026-10-31；info.yaml `update_time` 维持 2026-10-31（`version` 禁改不动） | 部署修复（非代码 bug） | 真机验证通过，造词功能全链路闭环；S125 为当前基线包 |

---

## 八、Git 仓库管理（2026-10-21 重构；2026-10-24 根上移至 `dev/`）

### 目录约定（全库唯一权威口径）

```
D:\AutophotiaIME\
├── dev\                        ← ★ git 仓库根（.git 在此）= 工作目录
│   ├── space\                  ← 手机同步的完整用户目录（勿动结构）
│   │   ├── schemas\TouchWB\    ← 优化对象（方案本体，75 文件）
│   │   ├── patches\            ← 补丁集（76 文件，已入 git）
│   │   ├── space.yaml          ← 默认入口（入 git）
│   │   └── space.custom.yaml   ← 实际生效配置（入 git）
│   ├── docs\                   ← ★ 项目文档（BASELINE.md / 项目指令_v14.md 现行 + v13/v7 留档 + 4 份设计调研文档，8 文件，已入 git）
│   ├── tools\                  ← 工具脚本（4 个 .sh/.py，已入 git）
│   ├── legacy-remote-b2faab1-backup.zip  ← 旧版远端文件备份（已排除 *.zip，不进 git）
│   └── 计划文档（App场景感知调研.md / 简码越级检查报告.md / 联想增强方案.md，已入 git）
├── releases\                   ← 打包输出目录，包名 TouchWB_S<序号>_<日期>.zip
├── patches\                    ← 早期补丁归档（补丁 zip/独立补丁/_backup/字体包，不进 git）
└── wps\ 码表处理\ xiangqi\     ← 其它用途目录，不参与 git，不用管
```

**核心规则**：
- **git 仓库根 = `dev/`**（2026-10-24 二次上移，`968a0d5`）；追踪 **161 文件 / 26M** = `space/schemas/TouchWB`（75）+ `space/patches`（76）+ `space.yaml` + `space.custom.yaml` + `docs`（6）+ `tools` 脚本（4）+ `.gitignore`
- 日常优化只改 `dev/space/schemas/TouchWB`（方案）与 `dev/space/patches`（补丁）；`dev/space` 其余部分是手机运行时资源（themes/fonts/haptics/sounds/textflow 等），由 `.gitignore` 排除，不删不改
- 历史延续方式：`mv space/.git dev/.git` 后重新 add 提交，**fast-forward push，从未 force push**（代价：2026-10-24 之前的 commit 路径相对 `space/`，之后相对 `dev/`，属历史断层，单人项目无影响）
- 发布打包一律输出到 `releases/`，命名 `TouchWB_S<序号>_<日期>.zip`（README 2026-10-08 定名规则，序号为构建序号自动 +1，如 `TouchWB_S118_2026-10-21.zip`）
- 新需求要建目录就在 `AutophotiaIME\` 下单建专用途文件夹，不往根目录散落文件

### 仓库配置

- **远端**：https://github.com/Autophotia/TouchWubi（分支 main）
- **本地身份**：`Autophotia <Autophotia@users.noreply.github.com>`（匿名邮箱）
- **代理**：`http.proxy/https.proxy = socks5h://127.0.0.1:1080`（已写入仓库配置，持久生效）
- **追踪范围**：**161 个文件 / 26M** = `space/schemas/TouchWB`（75 / 18M，方案本体）+ `space/patches`（76 / 7.5M，补丁集）+ `space.yaml` + `space.custom.yaml` + `docs`（6 / 82KB，项目文档）+ `tools` 脚本（4）+ `.gitignore`
- **忽略范围**（`dev/.gitignore`，路径以 git 根 `dev/` 为基准）：忽略 `build/`、`*.bin`、`log/`、`*.userdb`、`*.db-shm/-wal`、`custom_phrase.db`、`*.bak`、`*.tmp`、`*.zip`、`user.yaml`、`installation.yaml`、`**/lua/input_stats_ly_*.lua`、`sequence_*.txt`、`/tools/assoc_fixed_supplement.txt`（生成产物），以及 space 根目录手机运行时资源（`/space/emoticons/ /space/fonts/ /space/haptics/ /space/sounds/ /space/textflow/ /space/themes/ /space/tools/ /space/tutorials/ /space/plugins/ /space/resources/ /space/speeches/ /space/symbols/ /space/pasteboard/`）、`/space/README.md` `/space/LICENSE`、`/space/schemas/bim-pinyin/` `/space/schemas/bim-wubi/`
- ⚠️ gitignore 不支持行尾注释；`core.autocrlf=false` 防 Rime 文件行尾被改写

### 代理实测（九栈，2026-10-24 固化）

| 栈 | 端口 | 结果 |
|---|---|---|
| xray | socks 1080 / http 1081 | ✅（当前仓库用，IPv6 可用） |
| clash | http 7890（+sslVerify=false） | ✅ |
| singbox | 1080 | ✅ |
| hysteria | 1080 | ✅ |
| hysteria2 | 1080 | ✅（IPv6） |
| juicity | 1080 | ✅ |
| mieru | 3080 | ✅（须 ip_2 节点，服务式） |
| shadowquic | 4080 | ✅ |
| naiveproxy | — | ❌（二进制处理连接即崩溃，不可用） |

> 1080 端口六栈共用，同时只能跑一个；验证网络用 `git ls-remote`（勿用 curl）；排障先查进程存活再动配置。完整配方（含节点 IP、AI 自动启动流程、窗口铁律）见 `docs/项目指令_v14.md` 第 5 节。

### 日常更新（每次改完执行一条命令）

```bash
cd /d/AutophotiaIME/dev
git save "fix: 修复 xx 问题"
# 等价于 git add -A && git commit -m "..." && git push（已配 alias）
```

提交信息规范（Conventional Commits）：`feat:` 新功能 / `fix:` 修复 / `docs:` 文档 / `chore:` 杂项 / `refactor:` 重构。

### 发布打包

```bash
bash dev/tools/pack-release.sh
```

规则基线 = `releases/TouchWB_S117_2026-10-16.zip`（2026-10-21 对照固化），产物与参考包结构逐文件一致（**60 个**）：

- **结构**：zip 内含 `TouchWB/` 根目录
- **包含**：README/default/info/weasel/symbols、icons/、opencc/、lua/（21 个）、6+1 schema、4 套词库、themes/14key_wubi、themes/26key_wubi、predict.db
- **排除**：user.yaml、installation.yaml（本机安装配置）、custom_phrase.txt 及 custom_phrase.db*（自造词动态库）、user_coined_ext.txt（运行时自动生成，含其备份 .bak）、*.userdb/、log/、lua/input_stats_*.lua 及 .bak（未挂载死代码）、lua/sequence_*.txt（调序数据存于用户数据目录）、themes/public/**（空间级公共资源，随 app 提供）、任何层级的 build/（编译产物）
- **生成**：build/default.yaml 仅含 schema_list 四项（ly_wubi_pinyin / ly_wubi_pinyin_14 / ly_wubi / ly_wubi_14），与源码中的 build/default.yaml 无关，脚本每次生成
- 脚本内置数量校验：≠60 时告警（曾靠它抓到 themes/14key_wubi/build/ 漏排）

### 推送历史（2026-10-21 首推 → 2026-10-24 根上移）

- 2026-10-21：本地新历史与远端旧 main（网页上传 b2faab1）不相关，force push，远端 = `89d7af3`（79 文件，纯方案本体）
- 2026-10-24 一次上移：git 根 → `dev/space`（fast-forward，`fbbe016`），`patches` 纳入（`51c9b5b`），追踪 154 文件
- 2026-10-24 二次上移：git 根 → `dev/`（`968a0d5`，fast-forward，未 force push），`docs`/`tools`/计划文档纳入；当前 HEAD = `968a0d5`，共 **161 文件 / 26M**
- ⚠️ 历史断层说明：`fbbe016` 之前的 commit 路径相对 `space/`（更早的 `89d7af3` 相对 `schemas/TouchWB/`），之后的相对 `dev/`。`git log -- <path>` 跨断层追文件需用新路径
- 认证方式：GitHub 设备码授权流（沙箱无 GUI，用 CentBrowser 打开 github.com/login/device 完成），令牌仅一次性使用未落盘
- `http.sslVerify=false` 仍写入仓库配置（`http.proxy` 曾走 7890 MITM 时代遗留；当前 `socks5h://1080` 不做 MITM，可保留或日后清理）
