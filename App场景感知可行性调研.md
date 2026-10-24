# App 场景感知可行性调研报告

> TouchWB 五笔方案 · 创意 B 前置调研 ｜ 2026-10-24 ｜ 状态：可行性已判明

## 一、结论摘要

**「App 场景感知」技术上仅 PC 端（小狼毫）可行，手机端（同文/鸿蒙）当前不可行。** 对本人「日常聊天打字」的单一场景而言，实用价值有限——与初始判断一致。

| 平台 | 是否支持 | 依据 |
|---|---|---|
| 小狼毫（Windows） | ✅ 支持 | 检测前台 exe 名，app_options 生效（issue #405 用户实证「Windows 上有效」） |
| 鼠须管（macOS） | ✅ 支持 | 检测 bundle id（官方文档） |
| **同文 Trime（Android）** | ❌ **不支持** | issue #405：配置 `net.nhiroki.bluelineconsole` 的 ascii_mode，Android 11 上无效 |
| 超越（鸿蒙） | ❓ 无法评估 | 商用非开源；鸿蒙 IME 权限限制大概率同 Android |

## 二、机制原理（app_options 如何工作）

librime 原生提供 `app_options` 配置节点，但**「前台 App 检测」是前端职责，librime 自身不检测**。完整链路：

```
前端检测前台 App（exe 名 / bundle id / 包名）
  → 前端把 App 名传给 librime
  → librime 在 config 里查 app_options/<App名>，命中则把配置应用为 context option
  → Lua 通过 context:get_option(flag) 读到场景标志，动态调整行为
```

配置示例（小狼毫 weasel.custom.yaml）：

```yaml
patch:
  app_options/wechat.exe:
    wechatFlg: true        # 自定义 flag，Lua 可 get_option("wechatFlg") 读到
  app_options/conhost.exe:
    ascii_mode: true       # 内置 option，控制中英文状态
```

可配置项：`ascii_mode`（中英文状态）、`schema`（切换方案）、任意自定义 flag（供 Lua 联动）。

## 三、关键障碍（手机端不可行的根因）

1. **同文未实现 app 检测传递**：issue #405（2021 年至今）实证——用户在同文里配了 app_options 的 ascii_mode，Android 上无效，而 Windows 上有效。说明同文没有把前台 App 包名传进 librime 的 app_options 机制。
2. **Android 隐私限制**：Android 11（API 30）起，`EditorInfo.packageName`（IME 获取当前输入目标 App 包名）访问受限——仅系统 App / 默认输入法等可信场景可读，普通第三方 IME 拿到的是 null。这是 Google 收紧隐私后 IME 的普遍约束，同文即便想做也受限。
3. **鸿蒙（超越）同源风险**：商用非开源无法验证，但鸿蒙 IME 的跨应用信息隔离逻辑大概率与 Android 一致。

## 四、Lua 侧感知方式（若前端支持则此路径成立）

前端设置 app_options 的自定义 flag 后，Lua 侧无需新 API，直接用现有 `context:get_option()` 读取：

```lua
local is_wechat = env.engine.context:get_option("wechatFlg")
if is_wechat then
    -- 微信场景：调整联想策略 / 候选偏好
end
```

此路径在 PC 端（小狼毫）已验证可行（CSDN 实战文章「app_options 与 Lua 脚本联动」）。

## 五、对 TouchWB 的价值评估

| 维度 | 判断 |
|---|---|
| 本人使用场景 | 日常聊天为主，几乎无「聊天 vs 代码 vs 终端」的多场景切换需求 |
| 主用平台 | 手机（同文/超越），恰是不支持的平台 |
| 五笔本身特点 | 五笔是「形码」，不存在「代码场景切英文」这类强需求（那是拼音/双拼用户的核心痛点） |
| 潜在用途 | 若有「不同 App 用不同联想库/候选偏好」的需求，PC 端可低成本实现 |

**综合：本人价值有限，且主用平台（手机）不支持。符合用户「意义不大」的预判。**

## 六、建议

1. **主方案：搁置，不投入开发**。手机端前端不支持 + Android/鸿蒙权限限制，短期无解；且本人无对应场景。
2. **若未来 PC 端有需求**：可零成本试小狼毫 app_options（纯 YAML 配置 + 可选 Lua 读 flag），不改方案本体、不改前端，半天可验证。
3. **记录为「已知边界」**：写入 BASELINE 台账，标注「前端能力依赖 + Android 权限限制」，避免未来重复调研。

---

### 附：证据来源

- librime `app_options` 机制：Rime 定制指南（docs.nopdan.com）、CSDN 实战文章、squirrel/weasel 官方文档
- 同文不支持：osfans/trime **issue #405**「ascii_mode 无效？」（2021-05 开，Android 11 上 app_options 不生效，Windows 有效）
- Android 限制：EditorInfo.packageName 自 API 30 起访问受限（IME 隐私约束）
- 前端汇总：osfans/trime wiki「Rime 前端汇总」
