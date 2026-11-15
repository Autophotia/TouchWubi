import io, sys

path = sys.argv[1]  # 26key theme.yaml

raw = io.open(path, encoding="utf-8").read()
# 归一换行，避免 CRLF 污染
text = raw.replace("\r\n", "\n").replace("\r", "\n")

# 1) 4 个半角下滑 pair：恢复 {function_rime_clear}（清候选 + 光标居中）
pairs = [
    ('down_halfbracket: { label: "(", text: "(){Left}" }',
     'down_halfbracket: { label: "(", text: "{function_rime_clear}(){Left}" }   # 半角括号对（H 下滑）：清候选直接上屏 + 光标居中'),
    ('down_halfquotationmark: { label: "\\"\\"", text: "\\"\\"{Left}" }   # 英文双引号一对 "" + 光标居中',
     'down_halfquotationmark: { label: "\\"\\"", text: "{function_rime_clear}\\"\\"{Left}" }   # 英文双引号一对 "" + 光标居中（清候选直接上屏）'),
    ('down_halfsemiquotationmark: { label: "\'\'", text: "\'\'{Left}" }   # 英文单引号一对 \'\' + 光标居中',
     'down_halfsemiquotationmark: { label: "\'\'", text: "{function_rime_clear}\'\'{Left}" }   # 英文单引号一对 \'\' + 光标居中（清候选直接上屏）'),
    ('down_angledbracket: { label: "<>", text: "<>{Left}" }   # 英文尖括号一对 <> + 光标居中（H 下滑）',
     'down_angledbracket: { label: "<>", text: "{function_rime_clear}<>{Left}" }   # 英文尖括号一对 <> + 光标居中（清候选直接上屏，H 下滑）'),
]

# 2) 4 个本地定义的半角独立标点：commit: -> text:{function_rime_clear}X（清候选直接上屏）
local_commit = [
    ('commit_bjgth: { label: "!", commit: "!" }',
     'commit_bjgth: { label: "!", text: "{function_rime_clear}!" }   # 半角叹号：清候选直接上屏'),
    ('commit_percent: { label: "%", commit: "%" }',
     'commit_percent: { label: "%", text: "{function_rime_clear}%" }   # 半角百分号：清候选直接上屏'),
    ('commit_halfcolon: { label: ":", commit: ":" }',
     'commit_halfcolon: { label: ":", text: "{function_rime_clear}:" }   # 半角冒号：清候选直接上屏'),
    ('commit_halfsemicolon: { label: ";", commit: ";" }',
     'commit_halfsemicolon: { label: ";", text: "{function_rime_clear};" }   # 半角分号：清候选直接上屏'),
]

for old, new in pairs + local_commit:
    if old not in text:
        print("WARN not found:", repr(old))
    text = text.replace(old, new)

# 3) 3 个预设定义的半角独立标点：在本地动作块插入覆盖定义（覆盖预设 commit_*）
override_block = (
    "\n"
    "  # —— 半角独立标点（覆盖预设 commit_*，统一改为「清候选直接上屏」）——\n"
    '  commit_halfunderline: { label: "_", text: "{function_rime_clear}_" }      # 半角下划线：清候选直接上屏\n'
    '  commit_half_tilde: { label: "~", text: "{function_rime_clear}~" }         # 半角波浪号：清候选直接上屏\n'
    '  commit_half_questionmark: { label: "?", text: "{function_rime_clear}?" }   # 半角问号：清候选直接上屏\n'
)
marker = 'commit_halfsemicolon: { label: ";", text: "{function_rime_clear};" }   # 半角分号：清候选直接上屏'
if marker in text and override_block.strip() not in text:
    text = text.replace(marker, marker + override_block, 1)
else:
    print("WARN override block not inserted (marker found:", marker in text, ")")

io.open(path, "w", encoding="utf-8", newline="\n").write(text)
print("done:", path)
