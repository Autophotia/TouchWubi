-- types.lua — librime / librime-lua 类型定义库（TouchWB 版）
-- -----------------------------------------------------------------------------
-- 作用：把 librime-lua 暴露的 C++ 全局（rime_api、Component、Candidate、Segment、
--       UserDb、log、yield …）收进一个 `rime` 命名空间，配好 LuaLS 类型注解，
--       并给出带类型的构造器封装。**纯声明，不改变任何运行时行为**。
--
-- 参照：sbsrf 的 lua/lib.lua（作者 ksqsf 的 wafel 核心库）。
-- 命名：sbsrf 叫 lib.lua，但 TouchWB 已有 lua/lib/ 目录（basic/bit/log/lunar/userdb），
--       为避免 lib.lua 与 lib/ 目录歧义，本文件叫 types.lua，职责完全对应 sbsrf 的 lib.lua。
--
-- 使用方式：local rime = require "types"
--   · rime.api.get_user_data_dir()   —— 替代裸 rime_api
--   · rime.Candidate(type, s, e, t, c) —— 替代裸 Candidate(...)
--   · rime.match(input, pattern)     —— 替代裸 rime_api.regex_match
--
-- 说明：暂时不清楚的类型记为 `unknown`，不清楚的方法记为 `function`。
--       后续对照 librime / librime-lua 源码（src/types.cc）逐步补全。
local rime = {}

---配置节点类型枚举
---@enum ConfigType
rime.config_types = {
    kNull = "kNull",
    kScalar = "kScalar",
    kList = "kList",
    kMap = "kMap",
}

---分词片段类型枚举
---@enum SegmentType
rime.segment_types = {
    kVoid = "kVoid",
    kGuess = "kGuess",
    kSelected = "kSelected",
    kConfirmed = "kConfirmed",
}

---按键处理器返回结果枚举
---@enum ProcessResult
rime.process_results = {
    kRejected = 0,
    kAccepted = 1,
    kNoop = 2,
}

---修饰键掩码枚举
---@enum ModifierMask
rime.modifier_masks = {
    kShift = 0x1,
    kLock = 0x2,
    kControl = 0x4,
    kAlt = 0x8,
}

-- -----------------------------------------------------------------------------
-- 日志
-- -----------------------------------------------------------------------------

---@type fun(string)
---@diagnostic disable-next-line: undefined-field
rime.info = log.info

---@type fun(string)
---@diagnostic disable-next-line: undefined-field
rime.warn = log.warning

---@type fun(string)
---@diagnostic disable-next-line: undefined-field
rime.error = log.error

-- -----------------------------------------------------------------------------
-- Rime 引擎 API
-- -----------------------------------------------------------------------------

---@class RimeAPI
---@field get_rime_version fun(): string
---@field get_shared_data_dir fun(): string
---@field get_user_data_dir fun(): string
---@field get_sync_dir fun(): string
---@field get_distribution_name fun(): string
---@field get_distribution_code_name fun(): string
---@field get_distribution_version fun(): string
---@field get_user_id fun(): string
---@diagnostic disable-next-line: undefined-global, no-unknown
rime.api = rime_api

---@type fun(input: string, pattern: string): boolean
---@diagnostic disable-next-line: undefined-global, no-unknown
rime.match = rime_api.regex_match

---@type fun(input: string, pattern: string, fmt: string): string
---@diagnostic disable-next-line: undefined-global, no-unknown
rime.replace = rime_api.regex_replace

-- -----------------------------------------------------------------------------
-- 类型声明（纯注解，供 LuaLS 补全 / 查错用）
-- -----------------------------------------------------------------------------

---@class Set
---method
---@field empty fun(self: self): boolean
---@field __index function
---@field __add function
---@field __sub function
---@field __mul function
local _Set

---@class Env
---element
---@field engine Engine
---@field name_space string
local _Env

---@class Engine
---element
---@field schema Schema
---@field context Context
---@field active_engine Engine
---method
---@field process_key fun(self: self, key_event: KeyEvent): boolean
---@field compose fun(self: self, ctx: Context)
---@field commit_text fun(self: self, text: string)
---@field apply_schema fun(self: self, schema: Schema)
local _Engine

---@class Context
---element
---@field composition Composition
---@field commit_history CommitHistory
---@field input string
---@field caret_pos integer
---@field commit_notifier Notifier
---@field select_notifier Notifier
---@field update_notifier Notifier
---@field delete_notifier Notifier
---@field option_update_notifier OptionUpdateNotifier
---@field property_notifier PropertyUpdateNotifier
---@field unhandled_key_notifier KeyEventNotifier
---method
---@field commit fun(self: self)
---@field get_commit_text fun(self: self): string
---@field get_script_text fun(self: self): string
---@field get_preedit fun(self: self): Preedit
---@field is_composing fun(self: self): boolean
---@field has_menu fun(self: self): boolean
---@field get_selected_candidate fun(self: self): Candidate
---@field push_input fun(self: self, text: string)
---@field pop_input fun(self: self, num: integer): boolean
---@field delete_input fun(self: self, len: integer): boolean
---@field clear fun(self: self)
---@field select fun(self: self, index: integer): boolean
---@field confirm_current_selection fun(self: self): boolean
---@field delete_current_selection fun(self: self): boolean
---@field confirm_previous_selection fun(self: self): boolean
---@field reopen_previous_selection fun(self: self): boolean
---@field clear_previous_segment fun(self: self): boolean
---@field reopen_previous_segment fun(self: self): boolean
---@field clear_non_confirmed_composition fun(self: self): boolean
---@field refresh_non_confirmed_composition fun(self: self): boolean
---@field set_option fun(self: self, name: string, value: boolean)
---@field get_option fun(self: self, name: string): boolean
---@field set_property fun(self: self, key: string, value: string)
---@field get_property fun(self: self, key: string): string
---@field clear_transient_options fun()
local _Context

---@class CommitHistory
---method
---@field iter fun(self: self): fun(): (number, CommitRecord)|nil

---@class CommitRecord
---element
---@field text string
---@field type string

---@class Preedit
---element
---@field text string
---@field caret_pos integer
---@field sel_start integer
---@field sel_end integer
local _Preedit

---@class Schema
---element
---@field schema_id string
---@field schema_name string
---@field config Config
---@field page_size integer
---@field select_keys string
local _Schema

---@class KeyEvent
---element
---@field keycode integer
---@field modifier integer
---method
---@field shift fun(self: self): boolean
---@field ctrl fun(self: self): boolean
---@field alt fun(self: self): boolean
---@field caps fun(self: self): boolean
---@field super fun(self: self): boolean
---@field release fun(self: self): boolean
---@field repr fun(self: self): string
---@field eq fun(self: self, key: KeyEvent): boolean
---@field lt fun(self: self, key: KeyEvent): boolean
local _KeyEvent

---@class KeySequence
---element
---method
---@field toKeyEvent fun(self: self): KeyEvent[]
local _KeySequence

---@class Composition
---method
---@field empty fun(self: self): boolean
---@field back fun(self: self): Segment
---@field pop_back fun(self: self)
---@field push_back fun(self: self)
---@field has_finished_composition fun(self: self): boolean
---@field get_prompt fun(self: self): string
---@field toSegmentation fun(self: self): Segmentation
local _Composition

---@class Notifier
---method
---@field connect fun(self: self, f: fun(ctx: Context), group: integer|nil): Connection
local _Notifier

---@class OptionUpdateNotifier: Notifier
---method
---@field connect fun(self: self, f: fun(ctx: Context, name: string), group:integer|nil): function[]
local _OptionUpdateNotifier

---@class PropertyUpdateNotifier: Notifier
---method
---@field connect fun(self: self, f: fun(ctx: Context, name: string), group:integer|nil): function[]
local _PropertyUpdateNotifier

---@class KeyEventNotifier: Notifier
---method
---@field connect fun(self: self, f: fun(ctx: Context, key: string), group:integer|nil): function[]
local _KeyEventNotifier

---@class Connection
---method
---@field disconnect fun(self: self)

---@class Segment
---element
---@field status SegmentType
---@field start integer
---@field _start integer
---@field _end integer
---@field length integer
---@field tags Set
---@field menu Menu
---@field selected_index integer
---@field prompt string
---method
---@field clear fun(self: self)
---@field close fun(self: self)
---@field reopen fun(self: self, caret_pos: integer)
---@field has_tag fun(self: self, tag: string): boolean
---@field get_candidate_at fun(self: self, index: integer): Candidate
---@field get_selected_candidate fun(self: self): Candidate
local _Segment

---@class Segmentation
---element
---@field input string
---method
---@field empty fun(self: self): boolean
---@field back fun(self: self): Segment | nil
---@field pop_back fun(self: self): Segment
---@field reset_length fun(self: self, length: integer)
---@field add_segment fun(self: self, seg: Segment)
---@field forward fun(self: self): boolean
---@field trim fun(self: self)
---@field has_finished_segmentation fun(self: self): boolean
---@field get_current_start_position fun(self: self): integer
---@field get_current_end_position fun(self: self): integer
---@field get_current_segment_length fun(self: self): integer
---@field get_confirmed_position fun(self: self): integer
---@field get_segments fun(self: self): Segment[]
---@field get_at fun(self: self, index: integer): Segment
local _Segmentation

---@class Candidate
---element
---@field type string
---@field start integer
---@field _start integer
---@field _end integer
---@field quality number
---@field text string
---@field comment string
---@field preedit string
---method
---@field get_dynamic_type fun(self: self): "Phrase"|"Simple"|"Shadow"|"Uniquified"|"Other"
---@field get_genuine fun(self: self): Candidate
---@field get_genuines fun(self: self): Candidate[]
---@field to_shadow_candidate fun(self: self): ShadowCandidate
---@field to_uniquified_candidate fun(self: self): UniquifiedCandidate
---@field append fun(self: self, cand: Candidate)
local _Candidate

---@class UniquifiedCandidate: Candidate
local _UniquifiedCandidate

---@class ShadowCandidate: Candidate
local _ShadowCandidate

---@class Phrase
---element
---@field language string
---@field start integer
---@field _start integer
---@field _end integer
---@field quality number
---@field text string
---@field comment string
---@field preedit string
---@field weight number
---@field code Code
---@field entry DictEntry
---method
---@field toCandidate fun(self: self): Candidate
local _Phrase

---@class Menu
---method
---@field add_translation fun(self: self, translation: Translation)
---@field prepare fun(self: self, candidate_count: integer): integer
---@field get_candidate_at fun(self: self, i: integer): Candidate|nil
---@field candidate_count fun(self: self): integer
---@field empty fun(self: self): boolean
local _Menu

---@class Translation
---method
---@field iter fun(self: self): fun(): Candidate|nil
local _Translation

---@class Config
---method
---@field load_from_file fun(self: self, filename: string): boolean
---@field save_to_file fun(self: self, filename: string): boolean
---@field is_null fun(self: self, conf_path: string): boolean
---@field is_value fun(self: self, conf_path: string): boolean
---@field is_list fun(self: self, conf_path: string): boolean
---@field is_map fun(self: self, conf_path: string): boolean
---@field get_string fun(self: self, conf_path: string): string
---@field get_bool fun(self: self, conf_path: string): boolean|nil
---@field get_int fun(self: self, conf_path: string): integer|nil
---@field get_double fun(self: self, conf_path: string): number|nil
---@field set_string fun(self: self, conf_path: string, s: string)
---@field set_bool fun(self: self, conf_path: string, b: boolean)
---@field set_int fun(self: self, conf_path: string, i: integer)
---@field set_double fun(self: self, conf_path: string, f: number)
---@field get_item fun(self: self, conf_path: string): ConfigItem|nil
---@field set_item fun(self: self, conf_path: string, item: ConfigItem)
---@field get_value fun(self: self, conf_path: string): ConfigValue|nil
---@field set_value fun(self: self, conf_path: string, value: ConfigValue)
---@field get_list fun(self: self, conf_path: string): ConfigList|nil
---@field set_list fun(self: self, conf_path: string, list: ConfigList)
---@field get_map fun(self: self, conf_path: string): ConfigMap|nil
---@field set_map fun(self: self, conf_path: string, map: ConfigMap)
---@field get_list_size fun(self: self, conf_path: string): integer|nil
local _Config

---@class ConfigItem
---element
---@field type ConfigType
---@field empty boolean
---method
---@field get_value fun(self: self): ConfigValue|nil
---@field get_map fun(self: self): ConfigMap|nil
---@field get_list fun(self: self): ConfigList|nil
local _ConfigItem

---@class ConfigValue
---element
---@field type ConfigType
---@field value string
---@field element ConfigItem
---method
---@field get_string fun(self: self): string
---@field get_bool fun(self: self): boolean|nil
---@field get_int fun(self: self): integer|nil
---@field get_double fun(self: self): number|nil
---@field set_string fun(self: self, s: string)
---@field set_bool fun(self: self, b: boolean)
---@field set_int fun(self: self, i: integer)
---@field set_double fun(self: self, f: number)
local _ConfigValue

---@class ConfigMap
---element
---@field type ConfigType
---@field size integer
---@field element ConfigItem
---method
---@field empty fun(self: self): boolean
---@field has_key fun(self: self, key: string): boolean
---@field keys fun(self: self): string[]
---@field get fun(self: self, key: string): ConfigItem|nil
---@field get_value fun(self: self, key: string): ConfigValue|nil
---@field set fun(self: self, key: string, item: ConfigItem)
---@field clear fun(self: self)
local _ConfigMap

---@class ConfigList
---element
---@field type ConfigType
---@field size integer
---@field element ConfigItem
---method
---@field empty fun(self: self): boolean
---@field get_at fun(self: self, index: integer): ConfigItem|nil
---@field get_value_at fun(self: self, index: integer): ConfigValue|nil
---@field set_at fun(self: self, index: integer, item: ConfigItem)
---@field append fun(self: self, item: ConfigItem): boolean
---@field insert fun(self: self, i: integer, item: ConfigItem): boolean
---@field clear fun(self: self): boolean
---@field resize fun(self: self, size: integer): boolean
local _ConfigList

---@class Switcher
---element
---@field attached_engine Engine
---@field user_config Config
---@field active boolean
---method
---@field select_next_schema fun(self: self)
---@field is_auto_save fun(self: self, option: string): boolean
---@field refresh_menu fun(self: self)
---@field activate fun(self: self)
---@field deactivate fun(self: self)
local _Switcher

---@class Opencc
---method
---@field convert fun(self: self, text: string): string
---@field convert_text fun(self: self, text: string): string
---@field random_convert_text fun(self: self, text: string): string
---@field convert_word fun(self: self, text: string): string[]
local _Opencc

---@class ReverseDb
---method
---@field lookup fun(self: self, key: string): string
local _ReverseDb

---@class ReverseLookup
---method
---@field lookup fun(self: self, key: string): string
---@field lookup_stems fun(self: self, key: string): string
local _ReverseLookup

---@class DictEntry
---element
---@field text string
---@field comment string
---@field preedit string
---@field weight number
---@field commit_count integer
---@field custom_code string
---@field remaining_code_length integer
---@field code Code
---@field tick_diff integer
local _DictEntry

---@class CommitEntry: DictEntry
---method
---@field get fun(self: self): DictEntry[]
local _CommitEntry

---@class Code
---method
---@field push fun(self: self, syllable_id: integer)
---@field print fun(self: self): string
local _Code

---@class Memory
---method
---@field dict_lookup fun(self: self, input: string, predictive: boolean, limit: integer): boolean
---@field user_lookup fun(self: self, input: string, predictive: boolean): boolean
---@field memorize fun(self: self, callback: fun(ce: CommitEntry))
---@field decode fun(self: self, code: Code): { number: string }
---@field iter_dict fun(self: self): fun(): DictEntry|nil
---@field iter_user fun(self: self): fun(): DictEntry|nil
---@field update_userdict fun(self: self, entry: DictEntry, commits: number, prefix: string): boolean
local _Memory

---@class Projection
---method
---@field load fun(self: self, rules: ConfigList)
---@field apply fun(self: self, str: string, ret_org_str: boolean|nil): string
local _Projection

---@class LevelDb
---method
---@field open fun(self: self): boolean
---@field open_read_only fun(self: self): boolean
---@field close fun(self: self): boolean
---@field loaded fun(self: self): boolean
---@field query fun(self: self, prefix: string): DbAccessor
---@field fetch fun(self: self, key: string): string|nil
---@field update fun(self: self, key: string, value: string): boolean
---@field erase fun(self: self, key: string): boolean
local _LevelDb

---@class DbAccessor
---method
---@field reset fun(self: self): boolean
---@field jump fun(self: self, prefix: string): boolean
---@field iter fun(self: self): fun(): (string, string) | nil
local _DbAccessor

---@class UserDb
---element
---@field name string
---@field db_name string
---method
---@field open fun(self: self): boolean
---@field loaded fun(self: self): boolean
---@field close fun(self: self): boolean
---@field query fun(self: self, prefix: string): DbAccessor
---@field fetch fun(self: self, key: string): string|nil
---@field update fun(self: self, key: string, value: string): boolean
---@field erase fun(self: self, key: string): boolean
local _UserDb

---@class Processor
---element
---@field name_space string
---method
---@field process_key_event fun(self: self, key_event: KeyEvent): ProcessResult
local _Processor

---@class Translator
---element
---@field name_space string
---method
---@field query fun(self: self, input: string, segment: Segment): Translation
local _Translator

---@class Filter
---element
---@field name_space string
---method
---@field apply fun(self: self, translation: Translation): Translation
local _Filter

-- -----------------------------------------------------------------------------
-- 构造器封装（带类型提示，也允许个性化封装）
-- 例：原先 `Candidate(type, start, _end, text, comment)`
--     可写成 `rime.Candidate(type, start, _end, text, comment)`
-- -----------------------------------------------------------------------------

---@param engine Engine
---@param namespace string
---@param klass string
---@return Processor
function rime.Processor(engine, namespace, klass)
    ---@diagnostic disable-next-line: undefined-global, no-unknown
    return Component.Processor(engine, namespace, klass)
end

---@param engine Engine
---@param namespace string
---@param klass string
---@return Translator
function rime.Translator(engine, namespace, klass)
    ---@diagnostic disable-next-line: undefined-global, no-unknown
    return Component.Translator(engine, namespace, klass)
end

---@param engine Engine
---@param namespace string
---@param klass string
---@return Filter
function rime.Filter(engine, namespace, klass)
    ---@diagnostic disable-next-line: undefined-global, no-unknown
    return Component.Filter(engine, namespace, klass)
end

---@param values any[]
---@return Set
function rime.Set(values)
    ---@diagnostic disable-next-line: undefined-global, no-unknown
    return Set(values)
end

---@param start_pos integer
---@param end_pos integer
---@return Segment
function rime.Segment(start_pos, end_pos)
    ---@diagnostic disable-next-line: undefined-global, no-unknown
    return Segment(start_pos, end_pos)
end

---@param schema_id string
---@return Schema
function rime.Schema(schema_id)
    ---@diagnostic disable-next-line: undefined-global, no-unknown
    return Schema(schema_id)
end

---@param str string
---@return ConfigValue
function rime.ConfigValue(str)
    ---@diagnostic disable-next-line: undefined-global, no-unknown
    return ConfigValue(str)
end

---@param type string
---@param start integer
---@param _end integer
---@param text string
---@param comment string
---@return Candidate
function rime.Candidate(type, start, _end, text, comment)
    ---@diagnostic disable-next-line: undefined-global, no-unknown
    return Candidate(type, start, _end, text, comment)
end

---@param cand Candidate
---@param type string
---@param text string
---@param comment string
---@param inherit_comment boolean
---@return ShadowCandidate
function rime.ShadowCandidate(cand, type, text, comment, inherit_comment)
    ---@diagnostic disable-next-line: undefined-global, no-unknown
    return ShadowCandidate(cand, type, text, comment, inherit_comment)
end

---@param memory Memory
---@param typ string
---@param start integer
---@param _end integer
---@param entry DictEntry
---@return Phrase
function rime.Phrase(memory, typ, start, _end, entry)
    ---@diagnostic disable-next-line: undefined-global, no-unknown
    return Phrase(memory, typ, start, _end, entry)
end

---@param filename string
---@return Opencc
function rime.Opencc(filename)
    ---@diagnostic disable-next-line: undefined-global, no-unknown
    return Opencc(filename)
end

---@param file_name string
---@return ReverseDb
function rime.ReverseDb(file_name)
    ---@diagnostic disable-next-line: undefined-global, no-unknown
    return ReverseDb(file_name)
end

---@param dict_name string
---@return ReverseLookup
function rime.ReverseLookup(dict_name)
    ---@diagnostic disable-next-line: undefined-global, no-unknown
    return ReverseLookup(dict_name)
end

---@return DictEntry
function rime.DictEntry()
    ---@diagnostic disable-next-line: undefined-global, no-unknown
    return DictEntry()
end

---@return Code
function rime.Code()
    ---@diagnostic disable-next-line: undefined-global, no-unknown
    return Code()
end

---@param engine Engine
---@param schema Schema
---@return Memory
function rime.Memory(engine, schema)
    ---@diagnostic disable-next-line: undefined-global, no-unknown
    return Memory(engine, schema)
end

---@param engine Engine
---@param schema Schema
---@param namespace string|nil
---@return Memory
function rime.Memory1(engine, schema, namespace)
    ---@diagnostic disable-next-line: undefined-global, no-unknown
    return Memory(engine, schema, namespace)
end

---@param engine Engine
---@return Switcher
function rime.Switcher(engine)
    ---@diagnostic disable-next-line: undefined-global, no-unknown
    return Switcher(engine)
end

---@return Projection
function rime.Projection()
    ---@diagnostic disable-next-line: undefined-global, no-unknown
    return Projection()
end

---@param dbname string
---@return LevelDb
function rime.LevelDb(dbname)
    ---@diagnostic disable-next-line: undefined-global, no-unknown
    local ok, ldb = pcall(LevelDb, dbname)
    if not ok then
        local dbpath = rime.api.get_user_data_dir() .. "/" .. dbname .. ".userdb"
        ---@diagnostic disable-next-line: undefined-global, no-unknown
        _, ldb = pcall(LevelDb, dbpath, dbname)
    end
    return ldb
end

---@param db_name string
---@param db_class "userdb" | "plain_userdb" | nil
---@return UserDb
function rime.UserDb(db_name, db_class)
    ---@diagnostic disable-next-line: undefined-global, no-unknown
    return UserDb(db_name, db_class)
end

---@param repr string
---@return KeyEvent
function rime.KeyEvent(repr)
    ---@diagnostic disable-next-line: undefined-global, no-unknown
    return KeyEvent(repr)
end

---@param repr string
---@return KeySequence
function rime.KeySequence(repr)
    ---@diagnostic disable-next-line: undefined-global, no-unknown
    return KeySequence(repr)
end

-- -----------------------------------------------------------------------------
-- 工具函数
-- -----------------------------------------------------------------------------

---格式化 Info 日志
---@param format string|number
function rime.infof(format, ...)
    rime.info(string.format(format, ...))
end

---格式化 Warn 日志
---@param format string|number
function rime.warnf(format, ...)
    rime.warn(string.format(format, ...))
end

---格式化 Error 日志
---@param format string|number
function rime.errorf(format, ...)
    rime.error(string.format(format, ...))
end

---送出候选
---@param cand Candidate
function rime.yield(cand)
    ---@diagnostic disable-next-line: undefined-global, no-unknown
    yield(cand)
end

---@param config Config
---@param key string
---@return string[]
function rime.get_string_list(config, key)
    local list = {}
    local patterns = config:get_list(key)
    if patterns then
        for i = 1, patterns.size do
            local item = patterns:get_value_at(i - 1)
            if item then
                local value = item:get_string()
                if value then
                    table.insert(list, value)
                end
            end
        end
    end
    return list
end

---取出输入中当前正在翻译的一部分
---@param context Context
---@return string|nil
function rime.current(context)
    local segment = context.composition:toSegmentation():back()
    if not segment then
        return nil
    end
    return context.input:sub(segment.start + 1, segment._end)
end

return rime
