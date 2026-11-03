-- drop_sentence.lua - 丢弃整句切分候选（type=sentence）
--
-- 背景（2026-11-01，脱离 script_translator）：
--   wubi_prefix 组件（table_translator，enable_sentence:true）为「第 5 码拼音首字母筛选」
--   提供 partial-span 候选（码是输入的前缀，type=table）。但 librime 的 MakeSentence
--   在产出 partial-span 的同时，还会产出 type=sentence 的「整句切分」候选：
--     tane  → 和世有（切 t/an/e 三个单字码）
--     pinyin→ 宵憱  （把拼音串当五笔码切 pi/nyin）
--     `xihuan → 纱柴油机（反引号段也切 xi/huan）
--   这些 sentence 候选是把输入按「码」乱切的产物，是候选栏乱词的根源。
--
--   sentence 候选对第 5 码筛选毫无用处：wubi_pinyin_filter 的 5 码分支只认
--   partial-span 的 table 候选（orig_end 1~4）与 reverse_lookup，sentence 本就会被丢。
--   但 ≤4 码分支里 sentence 吃满整串（orig_end == 输入长度）会漏网，故在此统一丢弃。
--
-- 已知代价（table_translator 的 poet 硬限制，已与用户确认）：
--   第 5 码是非五笔码（如 z）时，MakeSentence 的 poet 覆盖失败会连 partial-span 一起
--   丢弃 ⇒ khlgz→中/足/盅、14键 fffff→封 这类「第 5 码非五笔码的筛选」失效。
--   这是脱离 script_translator 的权衡。

local function filter(input, env)
  for cand in input:iter() do
    if cand.type ~= "sentence" then
      yield(cand)
    end
  end
end

return { func = filter }
