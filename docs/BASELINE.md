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
| info.yaml version | 2.3 / update_time 2026-10-24 |
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
│   ├── docs/              ★ 项目文档（BASELINE.md / 项目指令_v7.md / 联想库设计，3 文件，已入 git）
│   ├── tools/             工具脚本（pack-release.sh / 验证脚本，4 个 .sh/.py，已入 git）
│   ├── legacy-remote-b2faab1-backup.zip   旧远端备份（兜底）
│   └── App场景感知可行性调研.md / 简码越级检查报告.md / 联想增强方案.md
├── patchs/              早期补丁归档（补丁 zip + 独立补丁 + _backup + 字体包，不进 git）
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

### 2.4 15 个 Lua 模块基线

| 模块 | 行数 | 职责 | 挂载 |
|---|---|---|---|
| smart_assoc | 2985 | 智能联想（历史记忆+逐级联想+衰减淘汰） | 四方案 |
| super_sequence | 2141 | 手工调频/自动调频/自动排序 | 四方案 |
| input_statistics | 1089 | 输入统计（/tj /ks /js） | 四方案 |
| wubi_pinyin_filter | 1029 | 14键双键模糊+第五码拼音筛选+分层预测 | 四方案 |
| new_spelling | 900 | 字根拆分/拼音/编码注解 | 四方案 |
| Submit_text | 785 | 造词/快捷上屏/编码查询 | 四方案 |
| calculator | 667 | 计算器+大/小写金额 | 四方案 |
| pair_punct | 599 | 智能对标点 | 26键 |
| schedule | 521 | 日程农历（/jt /jq /rq …） | 四方案 |
| super_tips | 369 | 超级提示 | 四方案 |
| calc_symbol_processor | 217 | 计算器符号处理器 | 14键 |
| email_suffix_translator | 91 | 邮箱后缀补全 | 四方案 |
| help_cmd | 51 | `/h` 命令帮助 | 四方案 |
| lib/（basic bit log lunar userdb） | 2053 | 基础库（农历 1666 行在内） | 依赖 |

> ⚠ 深度耦合：`wubi_pinyin_filter` 与 `Submit_text` 依赖 `new_spelling` 的注释格式；单独带走任何 .lua 均不可用（README 9.5 节）。

### 2.5 数据文件与平台差异

- **用户数据（LevelDB）**：`lua/sequence_<方案>`（调频）、`lua/assoc_<方案>`（联想）、`lua/tips`、`easy_en`、`assoc_easy_en`、`rime_ice.userdb`
- **造词/短语明文**：`user_coined_ext.txt`（手机↔PC 共享）、`custom_phrase.txt`
- **平台差异**：主题（theme.yaml）仅移动端；schema/lua/词典两端共用；联想默认仅移动端（`assoc_pc`：仅移动/双端）
- **部署链路**：PC 改 `dev/space` → 打包 → 手机 dufs(局域网 WebDAV, 192.168.124.x) 拉取热更新（真机为鸿蒙）
- **部署三件事（缺一即"没生效"）**：① 覆盖文件并重新部署 ② **切换一次方案**（Lua 与缓存重建）③ 改过主题则删 `themes/<t>/build/` 再切方案（build 在就不重编译）

---

## 三、开关基线（16 个，均可在方案菜单切换）

显根/隐根、显码/隐码、显拼/隐拼、词组隐声/显声、关配/开配、关提/开提、扩展/常用字符集、隐表/显表、简体/繁体、半角/全角、中文/英文标点、**开频/关频（自动调频）**、**开想/关想（总联想）**、**带词库/纯历史**、**仅移动/双端**、**收起/空格（联想态空格 v5）**

---

## 四、命令基线（41 条，以 `lua/help_cmd.lua` GROUPS 为准，`/h` 可查）

| 组 | 命令 |
|---|---|
| 日期时间 | `/rq /sj /xq /dt` |
| 农历节气 | `/jt /jq /gz /nl` |
| 输入统计 | `/tj /qk /ks /js /tc` |
| 智能联想 | `/lxqk /lxql /lxzt /lxdj /lxdc /lxdr` |
| 候选调序 | `/txqk /txzq /txzj /txdc /txdr /txtj` |
| 符号面板 | `/tg /dz /xh /bd` |
| 数字序号 | `/1 /2 /3 … /10`（含大写） |
| 帮助 | `/h /help` |

> 命名规则：`tx`=调序 `lx`=联想，后两位取功能拼音首字母（`qk`=清空 `ql`=清理 `dc`=导出 `dr`=导入 `zt`=状态 `dj`=断句 `zj`=自检 `zq`=自清 `tj`=统计）。**新增/删除命令必须同步改 `lua/help_cmd.lua` 的 GROUPS 表**，否则 `/h` 帮助会漏。
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
| B-12 | 版本 | ✅已解决（2026-10-24）：info.yaml 已同步 `2.3` / 2026-10-24，README v2.3 / 2026-10-24，两者一致；space.custom.yaml 当前 `schema_id=ly_wubi`/`26key_wubi` 为用户临时切换，非固定口径 | 文件比对 | 发版 checklist 已建：README、info.yaml、space.custom 三处同步 |
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
5. **发版同步**：README、info.yaml、space.custom.yaml、本基线，四处版本口径一致。
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
| 2026-10-24 | **info.yaml 版本同步**：2.0→2.3、update_time 2026-10-24，与 README v2.3 一致（B-12 关闭） | 版本 | README/info.yaml/space.custom 三处同步 |
| 2026-10-24 | **git 根上移至 dev/space**（fast-forward，`fbbe016`），TouchWB 文件迁移到 schemas/TouchWB/ | 版本控制 | 历史延续，未 force push |
| 2026-10-24 | **patches 补丁集纳入版本管理**（`51c9b5b`）：dev/space/patches 76 文件入 git；独立补丁 zip 备份至 patchs/_backup_20261023/ | 版本控制 | 追踪 154 文件/26M |
| 2026-10-24 | **git 根二次上移至 `dev/`**（`968a0d5`，fast-forward）：`dev/docs`（3）+ `dev/tools` 脚本（4）+ dev 顶层计划文档（3）纳入追踪 | 版本控制 | 追踪 151→**161 文件/26M**；docs 恢复随 git 上云 |
| 2026-10-24 | **方案一（古诗文联想脚本）放弃**：assoc_common.txt 字频表错位无法识别难拆字，产出 10301 条但 71% 虚词污染；删除 chinese-poetry 语料（466M） | 决策 | 联想功能维持现状，语料已清 |
| 2026-10-24 | **BASELINE 过时口径修订**：2.1 目录图 / 四节命令表（以 help_cmd.lua GROUPS 为准）/ 八节代理 7890→socks5h:1080 / 打包 62→61 / git 79→154 全部按实测更新 | 文档 | 本次修订 |

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
│   ├── docs\                   ← ★ 项目文档（BASELINE.md / 项目指令_v7.md / 联想库设计，3 文件，已入 git）
│   ├── tools\                  ← 工具脚本（4 个 .sh/.py，已入 git）
│   ├── legacy-remote-b2faab1-backup.zip  ← 旧版远端文件备份（已排除 *.zip，不进 git）
│   └── 计划文档（App场景感知调研.md / 简码越级检查报告.md / 联想增强方案.md，已入 git）
├── releases\                   ← 打包输出目录，包名 TouchWB_S<序号>_<日期>.zip
├── patchs\                     ← 早期补丁归档（补丁 zip/独立补丁/_backup/字体包，不进 git）
└── wps\ 码表处理\ xiangqi\     ← 其它用途目录，不参与 git，不用管
```

**核心规则**：
- **git 仓库根 = `dev/`**（2026-10-24 二次上移，`968a0d5`）；追踪 **161 文件 / 26M** = `space/schemas/TouchWB`（75）+ `space/patches`（76）+ `space.yaml` + `space.custom.yaml` + `docs`（3）+ `tools` 脚本（4）+ dev 顶层计划文档（3）+ `.gitignore`
- 日常优化只改 `dev/space/schemas/TouchWB`（方案）与 `dev/space/patches`（补丁）；`dev/space` 其余部分是手机运行时资源（themes/fonts/haptics/sounds/textflow 等），由 `.gitignore` 排除，不删不改
- 历史延续方式：`mv space/.git dev/.git` 后重新 add 提交，**fast-forward push，从未 force push**（代价：2026-10-24 之前的 commit 路径相对 `space/`，之后相对 `dev/`，属历史断层，单人项目无影响）
- 发布打包一律输出到 `releases/`，命名 `TouchWB_S<序号>_<日期>.zip`（README 2026-10-08 定名规则，序号为构建序号自动 +1，如 `TouchWB_S118_2026-10-21.zip`）
- 新需求要建目录就在 `AutophotiaIME\` 下单建专用途文件夹，不往根目录散落文件

### 仓库配置

- **远端**：https://github.com/Autophotia/TouchWubi（分支 main）
- **本地身份**：`Autophotia <Autophotia@users.noreply.github.com>`（匿名邮箱）
- **代理**：`http.proxy/https.proxy = socks5h://127.0.0.1:1080`（已写入仓库配置，持久生效）
- **追踪范围**：**161 个文件 / 26M** = `space/schemas/TouchWB`（75 / 18M，方案本体）+ `space/patches`（76 / 7.5M，补丁集）+ `space.yaml` + `space.custom.yaml` + `docs`（3）+ `tools` 脚本（4）+ dev 顶层计划文档（3）+ `.gitignore`
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

> 1080 端口六栈共用，同时只能跑一个；验证网络用 `git ls-remote`（勿用 curl）；排障先查进程存活再动配置。完整配方（含节点 IP、启动流程、窗口铁律）见 `docs/项目指令_v7.md` 第 5 节。

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

规则基线 = `releases/TouchWB_S117_2026-10-16.zip`（2026-10-21 对照固化），产物与参考包结构逐文件一致（**61 个**）：

- **结构**：zip 内含 `TouchWB/` 根目录
- **包含**：README/default/info/weasel/symbols/user_coined_ext.txt、icons/、opencc/、lua/（21 个）、6+1 schema、4 套词库、themes/14key_wubi、themes/26key_wubi、predict.db
- **排除**：user.yaml、installation.yaml（本机安装配置）、custom_phrase.txt 及 custom_phrase.db*（自造词动态库）、*.userdb/、log/、lua/input_stats_*.lua 及 .bak（未挂载死代码）、lua/sequence_*.txt（调序数据存于用户数据目录）、themes/public/**（空间级公共资源，随 app 提供）、任何层级的 build/（编译产物）
- **生成**：build/default.yaml 仅含 schema_list 四项（ly_wubi_pinyin / ly_wubi_pinyin_14 / ly_wubi / ly_wubi_14），与源码中的 build/default.yaml 无关，脚本每次生成
- 脚本内置数量校验：≠61 时告警（曾靠它抓到 themes/14key_wubi/build/ 漏排）

### 推送历史（2026-10-21 首推 → 2026-10-24 根上移）

- 2026-10-21：本地新历史与远端旧 main（网页上传 b2faab1）不相关，force push，远端 = `89d7af3`（79 文件，纯方案本体）
- 2026-10-24 一次上移：git 根 → `dev/space`（fast-forward，`fbbe016`），`patches` 纳入（`51c9b5b`），追踪 154 文件
- 2026-10-24 二次上移：git 根 → `dev/`（`968a0d5`，fast-forward，未 force push），`docs`/`tools`/计划文档纳入；当前 HEAD = `968a0d5`，共 **161 文件 / 26M**
- ⚠️ 历史断层说明：`fbbe016` 之前的 commit 路径相对 `space/`（更早的 `89d7af3` 相对 `schemas/TouchWB/`），之后的相对 `dev/`。`git log -- <path>` 跨断层追文件需用新路径
- 认证方式：GitHub 设备码授权流（沙箱无 GUI，用 CentBrowser 打开 github.com/login/device 完成），令牌仅一次性使用未落盘
- `http.sslVerify=false` 仍写入仓库配置（`http.proxy` 曾走 7890 MITM 时代遗留；当前 `socks5h://1080` 不做 MITM，可保留或日后清理）
