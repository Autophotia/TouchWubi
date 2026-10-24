# -*- coding: utf-8 -*-
""" /lxdc /lxdr 静态验证：语法检查 + 核心 pattern / 合并语义单测。
运行：用 managed venv python 执行本脚本。
只读 smart_assoc.lua / help_cmd.lua，不修改任何方案文件。
"""
import os
import tempfile

from lupa import LuaRuntime

BASE = r"D:\AutophotiaIME\dev\space\schemas\TouchWB"
SMART = os.path.join(BASE, "lua", "smart_assoc.lua")
HELP = os.path.join(BASE, "lua", "help_cmd.lua")

lua = LuaRuntime()

print("=" * 70)
print("[1] 语法编译检查")
for path in (SMART, HELP):
    src = open(path, "r", encoding="utf-8").read()
    try:
        lua.compile(src)
        print("  PASS  %s  (%d 行)" % (os.path.basename(path), src.count("\n") + 1))
    except Exception as e:
        print("  FAIL  %s  -> %s" % (os.path.basename(path), e))

# ---- 提取 smart_assoc.lua 中的 4 个函数块（第 2785~2909 行） ----
lines = open(SMART, "r", encoding="utf-8").read().split("\n")
block = "\n".join(lines[2784:2909])  # 0-indexed：第 2785 行 "local function assoc_export_path" 起

tmpdir = tempfile.mkdtemp(prefix="lxdc_verify_")
os.makedirs(os.path.join(tmpdir, "lua"), exist_ok=True)
tmpdir_fwd = tmpdir.replace("\\", "/")

# 头部：常量 + 全局 rime_api + mock db + 辅助写文件
head = rf'''
local ASSOC_PREFIX = "\003as|"
local SEP = "\001"
rime_api = {{ get_user_data_dir = function() return "{tmpdir_fwd}" end }}

local function make_db(store)
  return {{
    loaded = function() return true end,
    fetch = function(_, k) return store[k] end,
    update = function(_, k, v) store[k] = v end,
    query = function(_, prefix)
      local keys = {{}}
      for k in pairs(store) do
        if string.sub(k, 1, #prefix) == prefix then keys[#keys + 1] = k end
      end
      table.sort(keys)
      local i = 0
      return {{ iter = function()
        return function()
          i = i + 1
          local k = keys[i]
          if k then return k, store[k] end
        end
      end }}
    end
  }}
end

local function write_txt(path, content)
  local f = io.open(path, "wb")
  f:write(content)
  f:close()
end

local function read_txt(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local c = f:read("*a")
  f:close()
  return c
end
'''

# 尾部：测试 + 返回结果
tail = r'''
results = {}
local function report(name, cond, detail)
  results[#results + 1] = (cond and "PASS" or "FAIL") .. " | " .. name
      .. (detail and (" | " .. detail) or "")
end

local sid = "ly_wubi_14"
local path = assoc_export_path(sid)

-- 构造 3 条记录：你好→世界(5,100) / 你好→朋友(3,200) / 今天→天气(2,300)
local store = {}
local db = make_db(store)
store[ASSOC_PREFIX .. "你好" .. SEP .. "世界"] = "5" .. SEP .. "100"
store[ASSOC_PREFIX .. "你好" .. SEP .. "朋友"] = "3" .. SEP .. "200"
store[ASSOC_PREFIX .. "今天" .. SEP .. "天气"] = "2" .. SEP .. "300"

-- T1 导出 3 条
local n, err = export_assoc(db, sid)
report("T1 导出3条", n == 3 and err == nil, "n=" .. tostring(n) .. " err=" .. tostring(err))

-- T2 导出文件头 + 数据行
local c = read_txt(path) or ""
if c:sub(1, 3) == "\xef\xbb\xbf" then c = c:sub(4) end
local fl = {}
for l in c:gmatch("[^\r\n]+") do fl[#fl + 1] = l end
report("T2 文件头4行", #fl >= 4
    and fl[1] == "#/schema_id\t" .. sid
    and fl[4]:match("^#/entries\t3$") ~= nil,
    "L1=" .. tostring(fl[1]) .. " L4=" .. tostring(fl[4]))
report("T2 数据行=3 且格式正确", #fl == 7 and fl[5]:match("^[^\t]+\t[^\t]+\t%d+\t%d+$") ~= nil,
    "行数=" .. #fl .. " D1=" .. tostring(fl[5]))

-- T3 二次导出被保护（sum <= tsum）
local n2, err2 = export_assoc(db, sid)
report("T3 二次导出被保护", n2 == nil and err2 == "protected", "err=" .. tostring(err2))

-- T4 学习量增长后可导出
store[ASSOC_PREFIX .. "你好" .. SEP .. "世界"] = "100" .. SEP .. "100"
local n3, err3 = export_assoc(db, sid)
report("T4 学习量增长后可导出", n3 == 3 and err3 == nil, "n=" .. tostring(n3) .. " err=" .. tostring(err3))

-- T5 空库导出：n==0 提前返回，不写文件 ⇒ 备份不丢（保护目标达成，语义是"无数据"）
local db2 = make_db({})
local n4, err4 = export_assoc(db2, sid)
local bak = read_txt(path) or ""
local bak_intact = bak:match("#/entries\t3") ~= nil
report("T5 空库导出不覆盖备份", n4 == 0 and err4 == nil and bak_intact,
    "n=" .. tostring(n4) .. " err=" .. tostring(err4) .. " 备份完好=" .. tostring(bak_intact))

-- 恢复干净的 3 条导出文件供导入测试
write_txt(path, "\xef\xbb\xbf#/schema_id\t" .. sid
    .. "\n#/user_id\ttest\n#/version\t1\n#/entries\t3\n"
    .. "你好\t世界\t5\t100\n你好\t朋友\t3\t200\n今天\t天气\t2\t300\n")

-- T6 导入 3 条到空库 + 幂等
local db3 = make_db({})
local ok, imp, skip, e = import_assoc(db3, sid)
report("T6 导入3条", ok and imp == 3 and skip == 0 and e == nil,
    string.format("ok=%s imp=%d skip=%d e=%s", tostring(ok), imp, skip, tostring(e)))
local ok2, imp2 = import_assoc(db3, sid)
report("T6 二次导入幂等(无新记录)", ok2 and imp2 == 0, "imp=" .. tostring(imp2))

-- T7 max 合并：库已有 你好→世界 = 5/100，txt 里 = 3/200 → 应得 5/200
write_txt(path, "\xef\xbb\xbf#/schema_id\t" .. sid
    .. "\n#/user_id\ttest\n#/version\t1\n#/entries\t1\n你好\t世界\t3\t200\n")
local db4 = make_db({})
db4:update(ASSOC_PREFIX .. "你好" .. SEP .. "世界", "5" .. SEP .. "100")
import_assoc(db4, sid)
report("T7 max合并(count取大,ts取大)",
    db4:fetch(ASSOC_PREFIX .. "你好" .. SEP .. "世界") == "5" .. SEP .. "200",
    tostring(db4:fetch(ASSOC_PREFIX .. "你好" .. SEP .. "世界")))

-- T8 坏行跳过
write_txt(path, "\xef\xbb\xbf#/schema_id\t" .. sid
    .. "\n#/user_id\ttest\n#/version\t1\n#/entries\t1\n"
    .. "正常\t条目\t7\t700\n这是坏行没有制表符\n")
local db5 = make_db({})
local ok5, imp5, skip5 = import_assoc(db5, sid)
report("T8 坏行跳过", ok5 and imp5 == 1 and skip5 == 1,
    string.format("imp=%d skip=%d", imp5, skip5))

-- T9 schema 不符拒绝
write_txt(path, "\xef\xbb\xbf#/schema_id\tother_schema\n#/entries\t0\n")
local db6 = make_db({})
local ok6, imp6, skip6, e6 = import_assoc(db6, sid)
report("T9 schema不符拒绝", ok6 == false and imp6 == 0 and e6 == "schema_mismatch",
    "e=" .. tostring(e6))

-- T10 无文件
local db7 = make_db({})
local ok7, imp7, skip7, e7 = import_assoc(db7, "ly_wubi")  -- 对应 txt 不存在
report("T10 备份文件不存在", ok7 == false and e7 == "no_file", "e=" .. tostring(e7))
'''

test_lua = head + "\n" + block + "\n" + tail

print("=" * 70)
print("[2] 核心 pattern / 合并语义单测")
lua.execute(test_lua)
results = lua.globals().results
npass = 0
nfail = 0
for i in range(1, len(results) + 1):
    line = results[i]
    print("  " + line)
    if line.startswith("PASS"):
        npass += 1
    else:
        nfail += 1
print("-" * 70)
print("  结果：PASS=%d  FAIL=%d" % (npass, nfail))
print("  临时目录：%s" % tmpdir)

if nfail > 0:
    raise SystemExit(1)
