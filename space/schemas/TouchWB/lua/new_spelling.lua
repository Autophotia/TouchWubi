--[[
    统一拆分模块 - 整合版（自动适配纯五笔 / 五笔拼音混输）
    功能：提供汉字字根拆分、拼音、编码等注解功能
    作者: 空山明月、shawx、Autophotia
    主页: https://github.com/Autophotia/TouchWubi
    日期：2025-10-25
    优化日期: 2026-05-20
    用途: 独立的拆分过滤器模块，根据方案自动切换行为（纯五笔 or 混输）
    版本: 整合版 - 通过 schema 中的 mixed_input 标志自动适配

    【方案配置说明】
    本脚本为过滤器（含 init 初始化），需在 schema.yaml 中添加以下配置：

    engine:
      filters:
        - lua_filter@*new_spelling              # 字根拆分过滤器

    switches:                                    # 添加开关控制
      - name: new_spelling
        reset: 1
        states: [ 隐根, 显根 ]
      - name: new_hide_pinyin
        reset: 0
        states: [ 显拼, 隐拼 ]
      - name: new_hide_code
        reset: 0
        states: [ 显码, 隐码 ]
      - name: new_phrase_pinyin                 # 仅混输方案需要（纯五笔下 is_mixed=false，此键不生效）
        reset: 0
        states: [ 隐声调, 显声调 ]              # 显声调=强制注释只出带调拼音；隐声调=交回三开关自由组合

    engine:                                      # 混输方案需添加
      mixed_input: true                          # 告诉脚本这是混输方案

    lua_reverse_db:                              # 反向数据库配置
      spelling: wb_spelling
      code: wb_spelling

    无需识别器配置，脚本通过 context:get_script_text() 和正则判断输入模式

    【调试日志】
    默认关闭，如需启用：将脚本第47行的 debug_log_enabled 从 false 改为 true
    日志文件输出到：用户数据目录/log/rime_debug.log
]]

-- =================================================================
-- == 配置参数 ==
-- =================================================================

local spelling_keyword = "new_spelling"        -- 字根显示开关
local phrase_pinyin_keyword = "new_phrase_pinyin"  -- 词组拼音开关（仅混输有效）
local debug_log_enabled = false                  -- 调试日志开关（默认关闭）

-- =================================================================
-- == 调试日志函数 ==
-- =================================================================

local function log_debug(msg)
    if not debug_log_enabled then return end
    
    local user_dir = ""
    if rime_api and rime_api.get_user_data_dir then
        user_dir = rime_api.get_user_data_dir()
    elseif env and env.engine and env.engine.context and env.engine.context.get_option then
        local schema_dir = env.engine.schema.schema_dir
        if schema_dir then
            user_dir = schema_dir:match("^(.+[/\\])") or ""
        end
    end
    
    local log_path = user_dir .. "log/rime_debug.log"
    
    local file = io.open(log_path, "a+")
    if file then
        file:write("[" .. os.date("%Y-%m-%d %H:%M:%S") .. "] " .. msg .. "\n")
        file:close()
    end
end

-- =================================================================
-- == 基础工具库 ==
-- =================================================================

local basic = require('lib/basic')
local map = basic.map
local index = basic.index
local utf8chars = basic.utf8chars
local matchstr = basic.matchstr

-- =================================================================
-- == 工具函数 ==
-- =================================================================

-- 判断字符串是否包含汉字（用于快速放行非汉字候选项）
local function has_chinese(str)
    return str:match("[\228-\233][\128-\191][\128-\191]") ~= nil
end

-- 格式化输入字符串（替换特殊字符为可读符号）
local function xform(input)
    if input == "" then return "" end
    input = input:gsub('%[', '〈')
    input = input:gsub('%]', '〉')
    input = input:gsub('※', ' ')
    input = input:gsub('_', ' ')
    input = input:gsub(',', '·')
    return input
end

-- 数据库查询包装函数
local function lookup(db)
    return function (str)
        return db:lookup(str)
    end
end

-- 解析字根拆分结果（移除额外信息）
local function parse_spll(str)
    local s = string.gsub(str, ',.*', '')
    return string.gsub(s, '^%[', '')
end

-- 解析编码结果（提取第二个字段）
local function parse_encode(str)
    local s = string.gsub(str, '%[(.-),(.-),(.-),(.-)%]', '[%2]')
    return string.gsub(s, '^%[', '')
end

-- 字根拆分字符串处理（提取指定位置的部件）
local function subspelling(str, first, last)
    if not first then return str end
    local radicals = {}
    local s = str
    s = s:gsub('{', ' {')
    s = s:gsub('}', '} ')
    for seg in s:gmatch('%S+') do
        if seg:find('^{.+}$') then
            table.insert(radicals, seg)
        else
            for pos, code in utf8.codes(seg) do
                table.insert(radicals, utf8.char(code))
            end
        end
    end
    return table.concat{ table.unpack(radicals, first, last) }
end

-- =================================================================
-- == 核心功能函数 ==
-- =================================================================

-- 词组字根拆分处理（用于"隐声"模式下的词组注释）
local function spell_phrase(s, spll_rvdb)
    local chars = utf8chars(s)
    local rvlk_results

    if #chars == 2 or #chars == 3 then
        rvlk_results = map(chars, lookup(spll_rvdb))
    else
        rvlk_results = map({chars[1], chars[2], chars[3], chars[#chars]}, lookup(spll_rvdb))
    end

    if index(rvlk_results, '') then return '' end

    local spellings = map(rvlk_results, parse_spll)
    local sup = '◇'

    if #chars == 2 then
        return subspelling(spellings[1] .. sup, 2, 2) ..
               subspelling(spellings[1] .. sup, 4, 4) ..
               subspelling(spellings[2] .. sup, 2, 2) ..
               subspelling(spellings[2] .. sup, 4, 4)
    elseif #chars == 3 then
        return subspelling(spellings[1], 2, 2) ..
               subspelling(spellings[2], 2, 2) ..
               subspelling(spellings[3] .. sup, 2, 2) ..
               subspelling(spellings[3] .. sup, 4, 4)
    else
        return subspelling(spellings[1], 2, 2) ..
               subspelling(spellings[2], 2, 2) ..
               subspelling(spellings[3], 2, 2) ..
               subspelling(spellings[4], 2, 2)
    end
end

-- =================================================================
-- == 《现代汉语常用字表》3500 字表 —— 「常用」开关的新判据 ==
-- -----------------------------------------------------------------
-- 数据来源：wb_spelling.dict.yaml 的前 3500 条正文条目。
--   该字典 sort: original，正文按字频降序排列（第 1 条「的」），故这
--   3500 条 = 「按字频降序的前 3500 个 GB2312 汉字」，数量与
--   《现代汉语常用字表》（常用 2500 + 次常用 1000）一致。
--   实测这 3500 字全部落在该字典标注为 GB2312 的 6763 字之内。
--
-- 为什么另立判据：原判据「该字被 wb_spelling 标注为 GB2312」的粒度是
--   整个 GB2312（6763 字 = 一级 3755 + 二级 3008），一级字表的常用字与
--   二级字表的冷字被一视同仁，于是「常用」开关挡不住 圻/髟/斫/嵴/惝
--   这类生僻字（实测 de → 原 有 胡 圾 垢 圻 髟 斫，前 8 位混进 3 个）。
--   本表把判据收紧到字频前 3500，挡掉这类字。
--
-- 生效条件：仅当 GB2312 开关处于「常用」（option 为真）时。
--   · 单字候选：字不在本表内 ⇒ 丢弃
--   · 多字候选：任一字不在本表内 ⇒ 丢弃（沿用原 isgb2312 的逐字判定）
--   · 查不到拼音/字根的非汉字（标点、数字、字母）沿用原逻辑放行
--   · 「〇」由 isgb2312 开头特判放行，不受本表影响
--
-- 回退：把下面的 COMMON_CHARS_STRICT 改为 false，即退回原 GB2312 判据。
--
-- ★★ 2026-09-29 起默认改为 false（退回原 GB2312 判据），原因：
--   两个拇指方案（ly_wubi_14 / ly_wubi_pinyin_14）的 GB2312 开关默认是
--   「常用」，而手机端既没有 Ctrl+Shift+U 那样的切换键、主题里也没有入口
--   ⇒ 手机上等于被永久锁死在「常用」。3500 表又太紧，把一批日常字挡在
--   门外：呗（字频 4163）、菇、藕、韭、蘑、蔷、蔼、闰 等，实测打 km/kmy
--   整字消失（26 键正常）。GB2312 6763 判据可放行这些字。
--   实测三模式对照（ly_wubi_14，10 个常用编码）：
--     现状 3500 表   km 8 条无呗   kmy 5 条无呗   前 10 条非 GB2312 字 0
--     完全不过滤     km 9 条有呗   kmy 7 条有呗唄 前 10 条非 GB2312 字 1
--     GB2312 6763    km 9 条有呗   kmy 6 条有呗   前 10 条非 GB2312 字 0
--   ⇒ 6763 判据既恢复了呗等次常用字，又不会放出繁体字与 CJK 扩展区怪字，
--     是三者的最优解。要重新收紧，把下面的值改回 true 即可。
-- =================================================================
local COMMON_CHARS_STRICT = false

local COMMON_CHARS_3500 = [[
的一是在不了有和人这中大上为个过国我以地他要来们时到生用作就出于会对分成年可同主也发工说子下能动行产而多后方面种学著着得定法民所经十三之进家
等部里都自二如理起力长化现小度实点高还当电加两从去物把本好水制体开业重使天然些量前四那外事它名合因应由其日性社义全样政表机关新平各相间心正与
西形反看明又么内你但利道原没第比命数只线向问意站此或条无公质结解情建月想很变者代已立系军最并提党题气五展象文通总果次员革活程常头位老直入特品
件山见路求管及级少基别设式资知组几手论统接农被边指将料九决先根期计强干战回放她给任运做必流区取门处据南则队图北百光治东保志较领海口七导调即什
造金吃规争思世共六认交受阶色联极美济更打改再增收清切真教场权安万术证身务走带斗角单花目完声热报八白才具至张马每话达转议科器示确许今例集信记积
群步整广风传界华且元离压研究况书拉类节采观越众持叫油速织林段难需非复儿律布际连算深容千近周影断己办须商石青米便感省支何团验半往约太克劳历备列
低委市史响准精习消写候土称技空府亲毛温率院划装存眼快标值族王查江斯素却除号住格参满始般包识专京照车按选火易厂听该红属维县严派局讲呢继首片构女
德死效谈失神望价铁酸底黄随苏引推艺尔官适批英告席举李师势细帮显项状字育层破落怎营远士台企爱言河配围型服朝轻紧武仅另章亚视封密注材案供止木续早
防护判态司固似罪黑充兴某树击致圆液音坚足负害含余夫排费源觉范左够差城春食兵施富均置减故虽曾占送笑试职氧阳汉留跟修巴创助未犯初功抗田坏降古尽互
财溶病叶投策责波令独考右请球让副双检宜杂钱述限简找冲端输倒养敌阿超换州胜帝依坐纪突念客绝升陈略益否罗仍吸苦错承友草夜微优画础协良射曲洋村矿终
轮块环析径哪烈校板云诉既迅刻靠察逐央待母境激渤模控卫久印房停甚皮洲搞息移旧拿若顶短湖括挥侵甲游语冷普银乐医烧刘吗针纸粉散急预扩愿核吧龙误欢孩
盐善雨货讨测丝室混弹乎鲜晚乱沙序缺获读鲁载渐父啊演刚守宁杀谓刑附担贵班稳钢迫答距药假毫兰喜练乙酒盾困买福征阻损介剂穿钟顺飞丰怕祖矛执星谁血背
掌脱希评沉概跑熟伤衣械烟审扬翻秋露慢静免促践脚妈补薄牛句握编庆亮笔居味映斤培松乡诗异孔顾呼香菜威尼抓攻奇倍临掉岁脸剧哥延末销皇永汽景娘伟齐陆
赵雷危胡聚硫束轴套座粮灯课绍杨怀饭赶缩额孙棉鼓宽绿川夺归灭煤宗衡卷盟弱竟镇途厚触措藏玉哈零枪灵险款召遍呀敢恶借歌脑泽染庭唱训堂域植欧宪裂努彻
探沿户振粒频督袁垂纯纳折操暗耐份录卖退遇茶润肉康唯浓胞符雪磁献船忙追伊税私篇盘夏卡盖丁季迎予架阴刀阵瓦野盛氢削伸索旗忽访累燃虑迹亦典晶雄泛谋
托透横屋朱惊奋替痛裁抽楚避硬寨床旁遗弟洗幅毒顿尚塞暴谢宝圈招彩闻胶残遭爷斜警揭鱼释倾潮贯偏摇监购徐付灰园摆殊蒸碎糖词耗赞炮吴愈堆骨凯午桥巨救
荣纷秦订旋割侧纤凡亡杆弦馆恩宋妇吹男版禁繁滑败捕择唐播爸泥跳君湾碳综废庄吨库睛楼麻涉尺剥伙麦坦嘴鸡耳荷赛肥岸谷扎铜街店冬炉姑恢彪惯朗秀勇驻贺
肯舞蒙昌粗抵贸亿俄键您旅登壁乘井闪湿缓洪秘芳汗闭卜毕莫津挂逃磨蛋股黎塔塑贡港腐筑冰净健殖婚奴插辩纺刺啦勒援像仪萨徒弄浪陷汇函休炼舍坡岛猪郭隔
氯忘尖伏浮虚朋授玻睡障辛碱贫岩泪臣疑滚壮梁荡启瑞穷甘箱童淡峰纲牙怪佛脂炸幸截牧售蓝镜震罢锅绕软拥尊豆礼剩擦耕颜泰菌绩勤竹拖尤伍匀锋爆刊姓仿尾
脉违欲筒洞璃墨默邦稍丽珠梅喝币窗氏潜抱森袖喊毁艰挑焦灾泡摩夹枝埃呈咱描池姐寒宫戴赤腰寸敬懂忆洁丹渡跃贝碰凝诸励幕柱奖缘奶智污奔扫隶网饱魏肃轨
虎杜隐兄廷鉴寻袋申隆诚遵票梦哲纱亩猛兼埔珍抢趣厘允博鬼荒铺伦汤恰拔恐弯晓圣颗奏妹忠循沟航柴碍舟寄钻抬郑稀页喷摸炭巧柯贴桌劲腾妻铸锐陶弃赫乏阔
紫牌挤迷闹罚拍码偶祥届邻暂膜乌磷胆撤戏辉讯仁巩碧瓜忍签邓吉储桂递疗宾滴柬绳扰洛腿详虫牲悲呆齿狂柳暖竞链催仲烂醒挖纹哭畜玩籍浅缝怒貌悉乃踏柔享
赏冒圭浆晨彼呵肩爬皆氨纵租尘巡绪瓶帽泉幼稿钠冠弧趋渔役伴辟抚伐凭纠敏霸铝凤羊婆袭祝牢浙锁译糊胸壳胁爹愤涂疆辈迟龄奥逆填寿轧旦恨融署搬秩铅盆鸣
杯灌阀串豪患挺沈掩乳鸟韩贮添扣逼悬岭宇臂烯凉朵侦秒稻番眉驱螺氮丈漫筹琴厅雾陕辽巯绘梯鞋拟孤拜僚辑倡丙仰惜斥扶漏俗苗姆辅拒偿碗锡返狗鸿辞埋芽矩
岗燥崇庙咬赋奉厉桃孟摄阅涌啥妙勾讼橡蚀蜡抛狠熙扭拨蒋框冻亏嫩叙剪曼叛杰劝叔熔饮仔骗撞桑屈棒赖刷估淀吏笼簧扇谱酷衰棚壤苯伪轰侨牵鼻叹骂骤丧旺哩
隙曹疾吐册覆晋扑御搜仗昨舒株嘛欣胀砂腔偷络顽涨甜吊盗杭尸捉毅迈脏狱搭飘炎瘦浸硅跨浇粘雅昆槽漆抑悄蓄锦歪贷烦撒沸闲亭肚掘邀郎浩燕漂惩妥傅牺贪迁
渠丢鸭绒钉滩帐硝耀膨邮贤誉瓷欺丛抹忧陪吾劣惠钾焰徽堡凶摘闷脆姚雕陵董诺泵赴剑腊窝卢锻罐览宴昏溪疯逮裕盈勘缴穆幻锥坑宿泼湘垄饰驶煮刮砍疏旱慌渗
戈汪悟昂桶颇骑佳霍旨芯畅旬摊墙敲蔬痕惨钙尝棱辨箭躺苍莱债吞坝卿挡柏萧颠霉谊妨黏漠辆郊俩彭夕凌宏逻淮饥熊绅霞冶垫蓬冯喂瞧玄岂叠葡哀仙吓棋滨丘佩
寺犹禄驰莲匹徙诬拾枯浑颂驳慰诱勿邰歇阁嘉沫拳饼戚皱掠塘仇锭竭娃冤凸拆曰掀朴摧溜卸堵筛疲栽胎腹驾纬扯颁饿悠祸慧舰姿恋遂卧怨醉廉遣狭菲犁侯羽姻抖
契萄阐盲躲韦谐兆舌佐屏妄肠酵墓恒缸柄敦慎堤逝贼辖魂押栏祟肖茅捷捞艳蜂逢罩档兽辱搅臭蔽铃乔雇挽芬砌拌翠醇弥嫂粹披狼窄柜淋晴拘寂滋鸦誓咸茫凑芝餐
账幽殿盒篡萌挣畏遥颤酬奸厌洒垦赔挨抄缔峡芦倘坯履巾宙劫酿矣闯晃帜捐矮澳愁窃烘昭奈滥戒丑蔡遮肺喀膀夸馏俱澄窑稼仆壶蔑裤渣姜媳爽岌绵纶饶竖椅捧吕
纽拚殷鼠卑涛郁汁闽焊孝颈茂舆唤肌址掏伞鞭缚撑杠鼎谴涤询哨帅宅堪韧拦眠麟碑缠巷趁秧猜欠坛茎晒榜炳挫跌糟攀酯慨携鄂氛霜棍锤沾侍斑豫辊崩萍儒蓉谬惟
浊吵揉蛮瞬叉缆荐哎溉悦朽赠郡踪泄疼剖苹锌耶妃迪孳睁亥弊匠桐嫌岳乾酚穴嫁烤玲捣甫邵潭慕炒浒畴匪撕嚷溢顷聪翁沃谦晰甸歧诊祁咨潘谭礁弓屠酶枢吟喉浴
颖症衬溃崖勉卓琼迭婴沪氟绞挪辣仑庞诞吁醋浦菱耻俘谣篮廊惧蹲盼赐挠陡棵翅峻俺厨翔赢愚拓惑绸杏咽扮蒲绣唉梳逸菊艾铲膏羞葛骄悼庸蒂宰渴肆魔榨蔗秆鹏
灶肤怜捻俊恼滞凹倚祭葬拢慈砸衍嗓凿唇尿衫衔拐脾锯傲萝猎夷贞昙罕厦愉扔邪坊媒脊蕴呖芒烫恳哇蛇诏昼铭镁帕冈胖刨枚寓荫辰贩娓猫笛盯锈贾藤楔衷僵斩扁
谕淑厢甩蚕禽匆捏瞎忌孕荆俭肝钦缅熄屑裸葱垒铀淘摔暑哼勋悔钞垮婶嘱鹿胺捆谅艘梭梨奠玛栅帘哑皂哦烷喇恭扛苛秤屡耿喘愧爪叭逊诈俯椭搏谨拄烃吻绑骚刹
熬胚雀屯拴拱舶裹矢寡栋粤碘栖酱肪薯囊弗惕艇肿汛粱敞冀氓蜜辐钩哗廓贱聘舅滔忉炕瞪狮咳啡葫喻樱龟锰擅灿谎坎卤褐藩毯戊闸渊譬胳斋梢崭扒凄坪泳忿宦枣
狡鹰笨痒傍烹怖匈塌咖莽尉钝粪迄坟胃郝寥嘿兔虹涅拼笋镶嵌秉掺敷煽氰倦聊踩寇哟糕筋刃辫跪穗扼庐梗屿虏沥憾歼烛诵煌釉枕姨劈卵彦砖醛枉肢蹄兜茨贬钊佣
汝淆昔讽侮稠翼椒钳咋傻痼炊庵帆魄咯耽贿鳞丸姬匙盥岐仓翰哄旷爵猴趟瑰诡踢淹沛晕揽桩涵僧鹤裙畔耍灼滇沦汰颊膝懒兑耙蹈吼蕉嗣焉焕汹渥辜癌萎钧陌煞焚
佑嘲聂歉骆屁桔惶衙腻宠盏袍鞲捍锄惹膛馈蛭膊窜娇乞嚼鄙猖绥亟抒筐泣篷拂赃铵镀钓眷兹躯禹咕拣赚瓣躁耸咒箪庚嘻缕稚糙挝扳孢酌隋哒勃腥籽尧暮襄勺乍溅
溴琳澜豹唧苟拇叮咐陛瀑竿拧珊皖韵琐隘靖邢玫撇僻薪噪毙茄蜀煎棕雁彰逗絮淤崔荔矫赌宣邹饷褂杉喧赣躬痴撮懈凳沼檐瞿卒撰睹憎璋韶募栓逾魁岚喃吱鲍袜簇
琪魑蒜疙寅禾鞑佃揪嗯粥肴泻巢宛襟莉鞍裳奕赎鳙郓雯蠢巍侄酮汞挟唆庶瞅硷瞒眯榴奢岔嘘槐坠瑟雹缉虐慷涧丞陋炽烁嚣薛邑謇镰熏钥麓淫剿晤驯斧畸媚剔铬羡
腺宵蜕姊笙墩驴喳蔚闺窥烙涯噢蚊黔橙歹渍魅碌睦囚溯窒栗芜厄搁髓糠伎锣桉楠骡躅镑寞腕狄祺嗅彝娥俞汀惰殳荧犬赦嘎骏酥棺涩孰蝇堕轿泌孜昧迂妖牡缀庇雍
笺妆栩聋涕蝶稽斌耦怯咏磺禀枫伺釜楞蕊眨戋咀敛帖呐娶酰饵嗜谜秃挚锢逞攫楷旭楣藻蘖娱酝虱茵豁跋坤绢乒搓讶绷钮陀戥窖渭瞻竺柿熹谒梆脯崎饺唾赳轩埠呜
丫纫滤哉棘晌臧缎雌诃虾诧靶峭棠戳阜衅硕杖嵩莎奎祯霖鸵霄啸氡氦箩琢唔腈袄吭寝紊簿凰阮愣猾鞠删铧屉磕褪咧鱿碾渎殆淌漓恫搪啼戎驼瑾沧傀磅诀琅翘湛翩
狐侠垢抨婿哺逶讳筷闵谤侣券幢殃苓澈豌噶琦洼洽沁乓朔绚婷羟彤泮硼吆怔儡茸茧椰莸乖窍桦笃呕眺榆裘沂诛谆瘫觅舜踽皿奄岖鳌妓蒴薇炯尹樟渺袱竣邱胥粟镍
嗽疫禺憩鹅啃眶涝钡掂澡阎葵戬骇潺泊鲋绮侈亨徘叩迤槛祈蘸猩飚湃湍廿脖婉靴叽颓臻嗨戌芋恣彬椿绰晾谥羲逛妮嘶硒驿垛惭捂詹褥壑蟹馒蕾蔓荪腮趾滦嗬痹碉
芹恃秽樊殴訾札诅孚蝴匿杲枷厥噔恍廖啤羿汾撼帷佼厕巫碟胧曙辘斟揣踱诽烽娟拈冉祀祠狈蹦濒砧峙谏恕苑笈凋圜筝夭辄饯揩篱嫉壕瑚攘芡尴熠淳痢咚泗榕撬檀
苇冥嬉靡擒苞蚂甄窟蛛娣瘩驮琉暇橱菩嘈禅恝鲤呻龚兢幌牟匣酏卉萱凛忱拷拯哔悍毋砉锉幂虞崽砾垣娴瑛捶肾殡羁蛤獗汲垠迸绊钵飙搂冕蠕肘拙捎饲钨绽觐赂蚁
肱嗡栈忡裔迥朦浚肇萋尬髯弘戮汕倔拭鹃婪墟嗦嘀骥吩簸藉潼膳谚肋阙汶踞圾讥菠疮箕屎璧霎晦颐慑肽翊堰蛙蚜娜炔垃钼刁鸽梧殉憋婢妒窘泾漪筵搀矾柑撩劾嫣
]]

-- 3500 字表的哈希集合（首次调用时构建一次，之后 O(1) 查询）
local common_char_set = nil

-- 返回 true = 在本表内；false = 不在；nil = 未启用收紧
local function is_common_char(char)
    if not COMMON_CHARS_STRICT then return nil end
    if not common_char_set then
        local set = {}
        local chars = utf8chars(COMMON_CHARS_3500)
        for i = 1, #chars do
            if #chars[i] == 3 then   -- 汉字 3 字节，跳过换行符
                set[chars[i]] = true
            end
        end
        common_char_set = set
    end
    return common_char_set[char] == true
end

-- ============================================================================
-- ★ 反查缓存（2026-09-29 S14 卡顿修复）
--
-- 背景：真机日志分析显示「同一会话内按键延迟随使用时长单调上升，reload 后立刻回落」
--      （段内首 20% p50=41ms → 末 20% 55ms；距 reload 0-60s: 31ms → 600s+: 61ms）。
-- 根因：本模块每次按键对每条候选都做 spll_rvdb / code_rvdb 反查（磁盘 / LevelDB 读），
--      唯一的一层缓存却写成 __mode="v" **弱值表** ⇒ Lua 每次 GC 就把缓存整层清掉。
--      会话越久 ⇒ 堆里垃圾越多 ⇒ GC 越频繁 ⇒ 缓存命中率越低 ⇒ 真实反查越多 ⇒ 越慢。
--      这正是「打着打着变卡、关键盘重开又流畅」的正反馈闭环。
-- 修法：① 缓存改成**强引用**；② 容量计数改成 O(1)（老写法每次写缓存都要 pairs 全表
--      遍历，3000 项表 = 每次 3000 次迭代）；③ 给原先**完全没有缓存**的裸
--      spll_rvdb:lookup / code_rvdb:lookup 也套上缓存。
-- ============================================================================
local MAX_CACHE_SIZE = 4000

local function make_cache()
    return { t = {}, n = 0 }
end

-- 取值：命中直接返回；未命中返回 nil（注意 '' 也是有效值，用 nil 区分"没缓存"）
local function cache_get(c, k)
    if not c or k == nil or k == '' then return nil end
    return c.t[k]
end

-- 存值：满了就整层丢弃（一次性摊销，避免 pairs 遍历）
local function cache_put(c, k, v)
    if not c or k == nil or k == '' then return v end
    if c.n >= MAX_CACHE_SIZE then
        c.t, c.n = {}, 0
    end
    if c.t[k] == nil then c.n = c.n + 1 end
    c.t[k] = v
    return v
end

--- 带缓存的拼音反查（原 env.spll_rvdb:lookup）
local spll_cache = make_cache()
local function spll_lookup(db, ch)
    if not db or not ch or ch == '' then return '' end
    local v = cache_get(spll_cache, ch)
    if v ~= nil then return v end
    local ok, raw = pcall(function() return db:lookup(ch) end)
    if not ok or raw == nil then raw = '' end
    return cache_put(spll_cache, ch, raw)
end

--- 带缓存的编码反查（原 env.code_rvdb:lookup）
local code_cache = make_cache()
local function code_lookup(db, text)
    if not db or not text or text == '' then return '' end
    local v = cache_get(code_cache, text)
    if v ~= nil then return v end
    local ok, raw = pcall(function() return db:lookup(text) end)
    if not ok or raw == nil then raw = '' end
    return cache_put(code_cache, text, raw)
end

-- GB2312字符集过滤缓存，避免重复查询反向数据库
-- ★ 强引用 + O(1) 计数（原来是 __mode="v" 弱值表，GC 一跑就整层失效）
local gb2312_cache = make_cache()

-- 单个字符GB2312检查（带缓存）
local function check_char_gb2312(char, spll_rvdb)
    if not char or char == '' then return 1 end
    
    -- 优先从缓存中获取
    local hit = cache_get(gb2312_cache, char)
    if hit ~= nil then return hit end
    
    local spll_raw = spll_lookup(spll_rvdb, char)
    local result = 1  -- 默认通过
    
    if spll_raw and spll_raw ~= '' then
        -- 【收紧】「常用」时先用 3500 字表判定：表外的汉字直接算扩展字。
        -- 非汉字（标点/数字/字母，查不到拼音）不参与收紧，沿用下面的原判据。
        if is_common_char(char) == false then
            result = 0
        else
            local chars = xform(spll_raw:gsub('%[(.-),(.-),(.-),(.-)%]', '[%4]'))
            if chars:find("GB2312") then
                result = 1
            elseif chars:find("GBK") then
                result = 0
            end
        end
    end
    
    -- 缓存结果
    cache_put(gb2312_cache, char, result)
    
    return result
end

-- GB2312字符集过滤
local function isgb2312(cand, env)
    local ctext = cand.text
    if string.find(ctext, "〇") then
        return 1
    end
    if utf8.len(ctext) == 1 then
        return check_char_gb2312(ctext, env.spll_rvdb)
    elseif utf8.len(ctext) > 1 then
        local arr = utf8chars(ctext)
        for i = 1, #arr do
            local result = check_char_gb2312(arr[i], env.spll_rvdb)
            if result == 0 then return 0 end
        end
        return 1
    end
end

-- 获取英文编码（用于 prompt 提示）
local function get_en_code(s, spll_rvdb)
    local chars = utf8chars(s)
    local rvlk_results

    if #chars == 2 or #chars == 3 or #chars == 1 then
        rvlk_results = map(chars, lookup(spll_rvdb))
    else
        rvlk_results = map({chars[1], chars[2], chars[3], chars[#chars]}, lookup(spll_rvdb))
    end

    if index(rvlk_results, '') then return '' end

    local spellings = map(rvlk_results, parse_encode)

    if #chars == 1 then
        return spellings[1]:gsub('[^%a]+','')
    elseif #chars == 2 then
        return spellings[1]:gsub('[^%a]+',''):sub(1,2) ..
               spellings[2]:gsub('[^%a]+',''):sub(1,2)
    elseif #chars == 3 then
        return spellings[1]:gsub('[^%a]+',''):sub(1,1) ..
               spellings[2]:gsub('[^%a]+',''):sub(1,1) ..
               spellings[3]:gsub('[^%a]+',''):sub(1,2)
    else
        return spellings[1]:gsub('[^%a]+',''):sub(1,1) ..
               spellings[2]:gsub('[^%a]+',''):sub(1,1) ..
               spellings[3]:gsub('[^%a]+',''):sub(1,1) ..
               spellings[4]:gsub('[^%a]+',''):sub(1,1)
    end
end

-- 三重注解获取函数（根据方案类型和开关组合生成注释）
local function get_tricomment(cand, env)
    local ctext = cand.text
    local show_spelling = env.engine.context:get_option(spelling_keyword)      -- 显根/隐根
    -- ★ S101b：极性已统一为「true = 显示」（与 new_spelling 一致）。
    --   原名 new_hide_* 保留（schema 里的 name 是 key，改名要动很多处），
    --   但**语义已反转**：true = 显示、false = 隐藏。
    --   ⚠ 原因：状态栏灰/彩由下标决定（0=灰/1=彩），用户要求「隐=灰」；
    --     老语义 true=隐藏 会让「隐」落在下标 1（彩色）⇒ 功能与颜色不可兼得。
    --     反转后二者同时成立。
    local show_pinyin = env.engine.context:get_option("new_hide_pinyin")
    local show_code = env.engine.context:get_option("new_hide_code")
    local show_phrase_pinyin = env.is_mixed and env.engine.context:get_option(phrase_pinyin_keyword) or false  -- 显声/隐声（仅混输有效）

    -- 单字处理
    if utf8.len(ctext) == 1 then
        local spll_raw = spll_lookup(env.spll_rvdb, ctext)
        if spll_raw == '' then return '' end

        local spelling = xform(spll_raw:gsub('%[(.-),(.-),(.-),(.-)%]', '%1')):gsub('^%s*(.-)%s*$', '%1')
        local pinyin = xform(spll_raw:gsub('%[(.-),(.-),(.-),(.-)%]', '%3')):gsub('^%s*(.-)%s*$', '%1')
        local code = xform(spll_raw:gsub('%[(.-),(.-),(.-),(.-)%]', '%2')):gsub('^%s*(.-)%s*$', '%1')

        if env.is_mixed and show_phrase_pinyin then
            return '〈' .. pinyin .. '〉'   -- 混输"显声"模式单字只显拼音
        end

        local parts = {}
        if show_pinyin then table.insert(parts, '〈' .. pinyin .. '〉') end
        if show_spelling then table.insert(parts, '〈' .. spelling .. '〉') end
        if show_code then table.insert(parts, '〈' .. code .. '〉') end
        if #parts > 0 then return table.concat(parts, '·') else return '' end
    -- 词组处理
    else
        local chars = utf8chars(ctext)
        local parts = {}

        -- 逐字查询拼音
        local pinyins = {}
        local has_valid_pinyin = false
        for i = 1, #chars do
            local char_raw = spll_lookup(env.spll_rvdb, chars[i])
            if char_raw ~= '' then
                local char_pinyin = xform(char_raw:gsub('%[(.-),(.-),(.-),(.-)%]', '%3')):gsub('^%s*(.-)%s*$', '%1')
                table.insert(pinyins, char_pinyin)
                has_valid_pinyin = true
            end
        end
        local pinyin_str = has_valid_pinyin and table.concat(pinyins, '·') or ''

        -- 混输显声模式：只显示拼音
        if env.is_mixed and show_phrase_pinyin then
            if pinyin_str ~= '' then
                return '〈' .. pinyin_str .. '〉'
            end
            return ''
        end

        -- 纯五笔或混输隐声模式：根据开关组合显示，顺序：拼音 → 字根 → 编码
        if show_pinyin and pinyin_str ~= '' then
            table.insert(parts, '〈' .. pinyin_str .. '〉')
        end
        if show_spelling then
            local phrase_spelling = spell_phrase(ctext, env.spll_rvdb)
            if phrase_spelling ~= '' then
                phrase_spelling = phrase_spelling:gsub('{(.-)}', '<%1>')
                table.insert(parts, '〈' .. phrase_spelling .. '〉')
            end
        end
        if show_code then
            local phrase_code = get_en_code(ctext, env.spll_rvdb)
            if phrase_code ~= '' then
                table.insert(parts, '〈' .. phrase_code .. '〉')
            end
        end

        if #parts > 0 then
            return table.concat(parts, '·')
        end
    end

    return ''
end

-- 检查是否通过GB2312字符集过滤
local function pass_gb2312_filter(cand, env)
    return isgb2312(cand, env) == 1 and env.engine.context:get_option("GB2312") or not env.engine.context:get_option("GB2312")
end

-- =================================================================
-- == 配置读取函数（用于获取水平样式配置）==
-- =================================================================

local function formatDir(path, filename)
    if path:find("\\") then
        return path .. "\\" .. filename
    elseif path:find("/") then
        return path .. "/" .. filename
    else
        return path .. "\\" .. filename
    end
end

local function get_item(filepath, item)
    local file = io.open(filepath, "rb")
    if file then
        local isexist = nil
        for line in file:lines() do
            if line:find(item) and not line:find("(%#)") then
                isexist = line:gsub('(.-):%s*(.-)', '%2')
            end
        end
        file:close()
        return isexist
    end
end

local function get_horizontal_style(filename, item)
    local shared_data_dir = rime_api.get_shared_data_dir()
    local user_data_dir = rime_api.get_user_data_dir()

    local flag = get_item(formatDir(user_data_dir, filename), item)
    if flag ~= nil then return flag end

    flag = get_item(formatDir(user_data_dir, "weasel.custom.yaml"), item)
    if flag ~= nil then return flag end

    return get_item(formatDir(shared_data_dir, filename), item)
end

-- =================================================================
-- == 主过滤器函数 ==
-- =================================================================

local function filter(input, env)
    local script_text = env.engine.context:get_script_text()
    local show_pinyin = env.engine.context:get_option("new_hide_pinyin")
    local show_code = env.engine.context:get_option("new_hide_code")
    local schema_id = env.engine.schema.schema_id or ""
    local spelling_states = env.engine.context:get_option(spelling_keyword)
    local composition = env.engine.context.composition
    local segment = composition:back()

    log_debug("filter called, script_text='" .. (script_text or "nil") .. "', spelling_states=" .. (spelling_states and "true" or "false"))

    local horizontal = get_horizontal_style(schema_id .. ".custom.yaml", "style/horizontal") or ""

    -- /键引导的命令输入：直接输出所有候选，跳过GB2312过滤和注解处理
    -- 确保 schedule.lua 命令和 symbols.yaml 符号完整显示
    if script_text:find("^([%/])[a-z]*") and not script_text:find("%p$") then
        log_debug("Command mode detected: " .. script_text)
        local cand_count = 0
        for cand in input:iter() do
            cand_count = cand_count + 1
            log_debug("  yielding cmd cand: type=" .. (cand.type or "nil") .. ", text='" .. (cand.text or "nil") .. "'")
            yield(cand)
        end
        log_debug("Command mode finished, yielded " .. cand_count .. " candidates")
        return
    end

    -- 检测是否为纯拼音输入（仅混输时有效）
    local is_pinyin_input = env.is_mixed and
        script_text:match("^[a-z]+$") and
        not script_text:match("^[zvw][a-z]+$") and
        not script_text:match("^[%`%~z/]") and
        not script_text:match(".*[`].*")

    -- 显根模式（spelling_states = true）时的处理
    if spelling_states then
        log_debug("Explicit radical mode")
        for cand in input:iter() do
            -- ★ 2026-10-31 修复：自造词（type=user_coined）候选的 comment 是「编码☯」，
            --   加字根/拼音注解会覆盖编码 ⇒ 下游 wubi_pinyin_filter 取不到编码而丢弃，
            --   表现为「手动造词/自动造词保存了却打不出来」。这类候选原样放行，不做注解。
            if cand.type == "user_coined" then
                yield(cand)
            elseif pass_gb2312_filter(cand, env) then
                -- 不含汉字的候选项（如日程命令、统计数字）直接输出
                if env.is_mixed and not has_chinese(cand.text) then
                    yield(cand)
                else
                    -- 混输 + 纯拼音输入模式：为候选项添加注释
                    if env.is_mixed and is_pinyin_input then
                        local add_comment = get_tricomment(cand, env)
                        if add_comment ~= nil and add_comment ~= "" then
                            cand.comment = add_comment
                        end
                        yield(cand)
                    -- 简繁转换器特殊命名空间处理
                    elseif cand.type == 'simplifier' and env.name_space == 'new_for_rvlk' then
                        if cand.comment == "" then
                            local comment = get_tricomment(cand, env)
                            yield(Candidate(spelling_keyword, cand.start, cand._end, cand.text, comment))
                        end
                    -- 普通候选项处理
                    else
                        -- z键引导的反查输入
                        if script_text:find("^z[%a%/]*") and not script_text:find("%p$") then
                            local add_comment = get_tricomment(cand, env)
                            local code_comment = code_lookup(env.code_rvdb, cand.text)

                            if add_comment ~= nil and add_comment ~= "" then
                                if cand.comment:find("(☯)") then
                                    segment.prompt = "〈编码：" .. get_en_code(cand.text, env.spll_rvdb) .. "〉"
                                    yield(cand)
                                else
                                    yield(Candidate(spelling_keyword, cand.start, cand._end, cand.text, add_comment))
                                end
                            else
                                yield(cand)
                            end
                        -- 其他普通输入
                        else
                            local add_comment = ''
                            local code_comment = code_lookup(env.code_rvdb, cand.text)

                            if cand.comment:find("(☯)") and script_text:find("^%`*(%l+%`%l+)") then
                                segment.prompt = "〈编码：" .. get_en_code(cand.text, env.spll_rvdb) .. "〉"
                            end

                            if cand.type == 'punct' and has_chinese(cand.text) then
                                local pinyin = xform(code_comment:gsub('%[(.-),(.-),(.-),(.-)%]', '%3')):gsub('^%s*(.-)%s*$', '%1')
                                local spelling = xform(code_comment:gsub('%[(.-),(.-),(.-),(.-)%]', '%1')):gsub('^%s*(.-)%s*$', '%1')
                                local code = xform(code_comment:gsub('%[(.-),(.-),(.-),(.-)%]', '%2')):gsub('^%s*(.-)%s*$', '%1')
                                add_comment = '〈' .. pinyin .. '〉·〈' .. spelling .. '〉·〈' .. code .. '〉'
                            else
                                if cand.comment == "" then
                                    add_comment = get_tricomment(cand, env)
                                end
                            end

                            if add_comment ~= '' then
                                cand.comment = add_comment
                            end

                            yield(cand)
                        end
                    end
                end
            end
        end
    -- 隐根模式（spelling_states = false）时的处理
    else
        log_debug("Hidden radical mode")
        -- z键引导的查询（隐根模式下强制显示完整三重注解：字根+编码+拼音），跳过GB2312过滤以确保完整显示
        if script_text:find("^z") then
            for cand in input:iter() do
                local show_phrase_pinyin = env.is_mixed and env.engine.context:get_option(phrase_pinyin_keyword) or false

                if env.is_mixed and show_phrase_pinyin and utf8.len(cand.text) > 1 then
                    -- 混输显声：词组拼音
                    local chars = utf8chars(cand.text)
                    local pinyins = {}
                    local has_valid_pinyin = false
                    for i = 1, #chars do
                        local char_raw = spll_lookup(env.spll_rvdb, chars[i])
                        if char_raw ~= '' then
                            local char_pinyin = xform(char_raw:gsub('%[(.-),(.-),(.-),(.-)%]', '%3')):gsub('^%s*(.-)%s*$', '%1')
                            table.insert(pinyins, char_pinyin)
                            has_valid_pinyin = true
                        end
                    end
                    if has_valid_pinyin then
                        cand.comment = '〈' .. table.concat(pinyins, '·') .. '〉'
                    else
                        cand.comment = ""
                    end
                    yield(cand)
                elseif env.is_mixed and show_phrase_pinyin and utf8.len(cand.text) == 1 then
                    -- 混输显声：单字拼音
                    local code_comment = code_lookup(env.code_rvdb, cand.text)
                    if code_comment ~= "" then
                        local pinyin = xform(code_comment:gsub('%[(.-),(.-),(.-),(.-)%]', '%3')):gsub('^%s*(.-)%s*$', '%1')
                        cand.comment = '〈' .. pinyin .. '〉'
                    else
                        cand.comment = ""
                    end
                    yield(cand)
                else
                    -- z键反查：强制显示完整三重注解（拼音+字根+编码），方便学习
                    if utf8.len(cand.text) == 1 then
                        -- 单字：显示拼音·字根·编码
                        local code_comment = code_lookup(env.code_rvdb, cand.text)
                        if code_comment ~= "" then
                            local pinyin = xform(code_comment:gsub('%[(.-),(.-),(.-),(.-)%]', '%3')):gsub('^%s*(.-)%s*$', '%1')
                            local spelling = xform(code_comment:gsub('%[(.-),(.-),(.-),(.-)%]', '%1')):gsub('^%s*(.-)%s*$', '%1')
                            local code = xform(code_comment:gsub('%[(.-),(.-),(.-),(.-)%]', '%2')):gsub('^%s*(.-)%s*$', '%1')
                            cand.comment = '〈' .. pinyin .. '〉·〈' .. spelling .. '〉·〈' .. code .. '〉'
                        else
                            cand.comment = ""
                        end
                    else
                        -- 词组：显示拼音·字根·编码（逐字查询）
                        local chars = utf8chars(cand.text)
                        local pinyins = {}
                        local has_valid_pinyin = false
                        for i = 1, #chars do
                            local char_raw = spll_lookup(env.spll_rvdb, chars[i])
                            if char_raw ~= '' then
                                local char_pinyin = xform(char_raw:gsub('%[(.-),(.-),(.-),(.-)%]', '%3')):gsub('^%s*(.-)%s*$', '%1')
                                table.insert(pinyins, char_pinyin)
                                has_valid_pinyin = true
                            end
                        end
                        local pinyin_str = has_valid_pinyin and table.concat(pinyins, '·') or ''
                        local phrase_spelling = spell_phrase(cand.text, env.spll_rvdb)
                        local phrase_code = get_en_code(cand.text, env.spll_rvdb)
                        local parts = {}
                        if pinyin_str ~= '' then table.insert(parts, '〈' .. pinyin_str .. '〉') end
                        if phrase_spelling ~= '' then
                            phrase_spelling = phrase_spelling:gsub('{(.-)}', '<%1>')
                            table.insert(parts, '〈' .. phrase_spelling .. '〉')
                        end
                        if phrase_code ~= '' then table.insert(parts, '〈' .. phrase_code .. '〉') end
                        if #parts > 0 then
                            cand.comment = table.concat(parts, '·')
                        else
                            cand.comment = ""
                        end
                    end
                    yield(cand)
                end
            end
        -- 其他普通输入（隐根模式）
        else
            -- 隐根（默认）模式：候选按 stream 顺序处理，前 annotate_limit 条做完整注解，
            -- 之后的只做 GB2312 过滤后原样放行（见 init 里的【注解限量】说明）
            local annotate_n = 0
            local annotate_limit = env.annotate_limit
            for cand in input:iter() do
                -- ★ 2026-10-31 修复：自造词（type=user_coined）候选原样放行，不做注解、
                --   不占注解名额 —— comment 保留「编码☯」供 wubi_pinyin_filter 匹配编码。
                if cand.type == "user_coined" then
                    yield(cand)
                    goto annotate_skip
                end
                annotate_n = annotate_n + 1
                if annotate_n > annotate_limit then
                    if pass_gb2312_filter(cand, env) then
                        yield(cand)
                    end
                    goto annotate_skip
                end
                if pass_gb2312_filter(cand, env) then
                    local parts = {}
                    local show_phrase_pinyin = env.is_mixed and env.engine.context:get_option(phrase_pinyin_keyword) or false

                    if env.is_mixed and show_phrase_pinyin and utf8.len(cand.text) > 1 then
                        -- 混输显声：词组拼音
                        local chars = utf8chars(cand.text)
                        local pinyins = {}
                        local has_valid_pinyin = false
                        for i = 1, #chars do
                            local char_raw = spll_lookup(env.spll_rvdb, chars[i])
                            if char_raw ~= '' then
                                local char_pinyin = xform(char_raw:gsub('%[(.-),(.-),(.-),(.-)%]', '%3')):gsub('^%s*(.-)%s*$', '%1')
                                table.insert(pinyins, char_pinyin)
                                has_valid_pinyin = true
                            end
                        end
                        if has_valid_pinyin then
                            cand.comment = '〈' .. table.concat(pinyins, '·') .. '〉'
                        end
                        yield(cand)
                    elseif env.is_mixed and show_phrase_pinyin and utf8.len(cand.text) == 1 then
                        -- 混输显声：单字拼音
                        local code_comment = code_lookup(env.code_rvdb, cand.text)
                        if code_comment ~= "" then
                            local pinyin = xform(code_comment:gsub('%[(.-),(.-),(.-),(.-)%]', '%3')):gsub('^%s*(.-)%s*$', '%1')
                            cand.comment = '〈' .. pinyin .. '〉'
                        else
                            cand.comment = ""
                        end
                        yield(cand)
                    else
                        -- 纯五笔或混输隐声模式
                        if utf8.len(cand.text) == 1 then
                            -- 单字注解
                            local parts = {}
                            if show_pinyin then
                                local code_comment = code_lookup(env.code_rvdb, cand.text)
                                if code_comment ~= "" then
                                    local pinyin = xform(code_comment:gsub('%[(.-),(.-),(.-),(.-)%]', '%3')):gsub('^%s*(.-)%s*$', '%1')
                                    table.insert(parts, '〈' .. pinyin .. '〉')
                                end
                            end
                            if show_code then
                                local code_comment = code_lookup(env.code_rvdb, cand.text)
                                if code_comment ~= "" then
                                    local code = xform(code_comment:gsub('%[(.-),(.-),(.-),(.-)%]', '%2')):gsub('^%s*(.-)%s*$', '%1')
                                    table.insert(parts, '〈' .. code .. '〉')
                                end
                            end
                            if #parts > 0 then
                                cand.comment = table.concat(parts, '·')
                            else
                                cand.comment = ""
                            end
                        else
                            -- 词组注解：调用 get_tricomment 根据开关决定显示拼音或字根
                            local add_comment = get_tricomment(cand, env)
                            if add_comment ~= '' then
                                cand.comment = add_comment
                            end
                        end

                        -- 特殊符号提示
                        if cand.comment:find("(☯)") and script_text:find("^%`*(%l+%`%l+)") then
                            segment.prompt = "〈编码：" .. get_en_code(cand.text, env.spll_rvdb) .. "〉"
                        end

                        yield(cand)
                    end
                end
                ::annotate_skip::
            end
        end
    end
    log_debug("filter finished normally")
end

-- =================================================================
-- == 初始化函数 ==
-- =================================================================

local function init(env)
    log_debug("init called")
    local config = env.engine.schema.config
    page_size = env.engine.schema.page_size
    local spll_rvdb = config:get_string('lua_reverse_db/spelling')
    local code_rvdb = config:get_string('lua_reverse_db/code')
    local abc_extags_size = config:get_list_size('abc_segmentor/extra_tags')

    env.spll_rvdb = ReverseDb('build/' .. spll_rvdb .. '.reverse.bin')
    env.code_rvdb = ReverseDb('build/' .. code_rvdb .. '.reverse.bin')
    env.is_mixtyping = abc_extags_size > 0

    -- 判断是否为混输方案：通过 engine/mixed_input 配置判断
    -- 混输方案需在 schema 的 engine 段显式声明 mixed_input: true
    local mixed_input = config:get_bool('engine/mixed_input') or false
    env.is_mixed = mixed_input

    -- ============================================================
    -- 【注解限量】只对排在最前面的 N 条候选做注音 / 字根 / 编码注解，
    -- 其余仍然照常过 GB2312 过滤，但不再逐条查反查库 ⇒ 省掉大头开销。
    --
    -- 为什么要有这条（2026-09-28 实测，`x_perf2.py` 取 21 次中位数）：
    --   · 第 2 码是候选扇出最宽的时刻（ff / ww / ni / ta 动辄上百条），
    --     也是用户最容易感觉到「卡一下」的一键
    --   · 把 new_spelling 整段摘掉，第 2 码耗时 16.7ms → 6.8ms
    --     ⇒ 说明**一半以上的耗时都在逐候选查反查库做注解**
    --   · 限量 15 条后降到 10.5ms（-33%~-37%），而屏幕上真正显示得下的
    --     通常不超过一页 ⇒ 视觉上无损，只是更后面的候选没有注解
    --
    -- 填 0 或负数 = 不限量（恢复「每条都做注解」的老行为）
    -- ============================================================
    local annotate_limit = config:get_int('new_spelling/annotate_limit')
    if annotate_limit == nil or annotate_limit <= 0 then
        annotate_limit = 15
    end
    env.annotate_limit = annotate_limit

    log_debug("init finished, is_mixed=" .. (env.is_mixed and "true" or "false") ..
              ", annotate_limit=" .. annotate_limit)
end

-- =================================================================
-- == 模块导出 ==
-- =================================================================

return { init = init, func = filter }