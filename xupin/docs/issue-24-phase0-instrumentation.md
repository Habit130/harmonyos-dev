# Issue #24 阶段 0:埋点方案 + 人工测量清单

## 已加的埋点

### 1. `MindSporeNeuralModel.predict()`(`entry/src/main/ets/InputMethodExtensionAbility/model/MindSporeNeuralModel.ets`)

每次 `predict()` 调用结束前打一条 `hilog.info`,格式:

```
MindSporeNeuralModel.predict timings (ms): setData=<a> predict=<b> getData=<c> total=<d> (batch=9 seq=20 vocab=21128)
```

- `setData`:三个输入 tensor(`input_ids`/`attention_mask`/`position_ids`)的 `setData()` 耗时
- `predict`:`await this.model.predict(inputs)` 本身耗时(MindSpore Lite 的真实推理)
- `getData`:`logitsTensor.getData()` + 包装成 `Float32Array` 的耗时
- `total` = 三段之和(不含调用方等待 Promise resolve 之外的开销)

### 2. `Index.ets` 的 `runNeuralRerank()`(`entry/src/main/ets/InputMethodExtensionAbility/pages/Index.ets`)

包住整个 `rankCandidates()` 调用(即 `NeuralScorer.prepare()` + 排序)的端到端一条:

```
runNeuralRerank: end-to-end <e>ms (neuralRanked=true)
```

`e` 减去上面的 `total`,就是 ArkTS 侧分词 + log-softmax 打分 + 排序的开销(issue 估算 <10ms,待验证)。
**注意**:`e` 里包含了 `rankCandidates()` 内部重新跑一次 `generateCandidates()` 的耗时——阶段 1 的
stage 1(静态候选立即上屏)已经跑过一次,stage 2 的 `rankCandidates()` facade 没改,又跑了一次同样
的静态生成。这是有意保留、不是遗漏(`rankCandidates()` 是已有测试覆盖的门面,不为省这一次重复计算去
碰它),但读 `end-to-end` 数字时要知道它比"纯神经部分"多算了一次静态候选生成(数量级远小于推理本身,
预计不影响判断标准,但数字对不上时先想到这一点)。

两条日志的差值链条:

```
静态候选上屏(同步,不产生 hilog) → [停手 200ms 防抖] → runNeuralRerank 开始
  → predict() 内部 setData/predict/getData 三段(上面第1条)
  → 返回后 ArkTS 侧打分 + 排序
  → runNeuralRerank: end-to-end <e>ms(上面第2条)
```

## 人工需要做的事(ADR-0002,agent 不碰真机)

1. 按现有流程构建 + 部署到真机,把序拼设为默认输入法(资产文件 `neural_scorer.ms`/`vocab.txt` 已经在
   `entry/src/main/resources/rawfile/model/` 下,是上一轮 #22 真机验证时放的,本机应该不用重新复制;
   换机器/换 checkout 才需要按 `issue-22-shape-fix.md` §4 重新放)。
2. 打开日志:`hdc shell hilog | grep XupinIME`(或 DevEco Studio 的 Log 面板过滤 `XupinIME`)。
3. **单次按键**:在任意输入框,先上屏"发起""物资"(PRD 例子的上文),然后打字 `gongji`,每敲一个字母
   都等它稳定(不要连打)再敲下一个。记录:
   - 每次 `predict timings` 里的 `setData`/`predict`/`getData`/`total`
   - 对应的 `runNeuralRerank: end-to-end`
   - 主观感受的"从松手到候选变化"的时间(不需要精确,几百毫秒 vs 几秒的量级即可)
4. **连续打字**:不停顿地快速敲完 `gongji` 六个字母,观察:
   - 静态候选(未点亮样式)是否每敲一下都跟着刷新、看起来跟手(这是防抖改造要保住的部分)
   - `predict timings`/`runNeuralRerank` 这两条日志在这一串按键期间应该只出现**一次**(防抖生效的
     证据——如果每敲一下都出现一次,防抖没生效,需要回来查)
   - 停手后首候选是否变成"供给"并点亮样式(蓝色加粗)
   - **诊断提示(#22 遗留的未验证疑点)**:如果日志里 `runNeuralRerank: end-to-end` 显示
     `neuralRanked=true`,但屏幕上顺序没变(供给没跑到第一位),先怀疑 `ForEach` 在 `Row`/`Scroll`
     容器下、候选词+matchedLength 键值不变只是顺序调整时到底有没有真的重排(PR #21 就留了这个疑点,
     没人工验证过)——根因大概率在 `ForEach`,不在推理或排序逻辑,不要回头查模型或 `NeuralScorer`。
     这次阶段 1 把"同一批候选换个顺序"这件事从每次按键触发,变成了 debounce 触发后才触发一次,如果
     `ForEach` 真的有这个问题,阶段 1 落地后应该照样能在这次测量中复现。
5. **当前绝对基线**:如果还没有已经很明确的"几秒"量级记录,用上面单次按键的
   `runNeuralRerank: end-to-end` 数字本身就是新基线(阶段 1 的防抖不改变单次 `predict()` 本身的算力
   开销,只改变触发频率)。
6. 把上面 3、4、5 步实际测出的数字填进本文件末尾的"实测结果"表格,原样回报即可,不需要额外加工。

## 判断标准(不要自己下结论,照抄这条走)

- 如果 `predict` 段(上面第1条日志的 `predict=` 字段)占 `end-to-end` 总耗时的大头(issue 原文预期
  是"几乎肯定"),阶段 1 已经落地、可以继续做阶段 2。
- 如果 `predict` 段只占一小部分,大头在 `setData`/`getData` 或 ArkTS 侧打分排序,**停下来汇报,不要
  凭这份 issue 原有的阶段 2/3 计划继续做**——需要重新规划瓶颈对应的优化方向。

## 实测结果

2026-07-24 09:34,4 次独立 `predict()` 调用,每次相隔约 1.05~1.10s。**这个间隔本身不能证明防抖在真机
上生效**——单次 `predict()` 就要 ~750ms,哪怕防抖完全没起作用,只要两次按键天然隔了一秒左右,日志间隔
看起来会是同一个样子,这份数据没法把"用户就是敲得慢"和"防抖生效、快速连打也会收敛成一次"这两种可能
区分开。**连续不停顿打字时日志是否只出现一次,是下一轮真机测试必须补的、阶段 1 验收标准本身要求的
数据,不是锦上添花**,见下面"下一轮必须做"一节。PRD 翻转/样式点亮同样仍未回报。

| # | setData(ms) | predict(ms) | getData(ms) | predict()合计(ms) |
| --- | --- | --- | --- | --- |
| 1 | 0 | 740 | 10 | 750 |
| 2 | 1 | 746 | 9 | 756 |
| 3 | 0 | 724 | 11 | 735 |
| 4 | 0 | 755 | 10 | 765 |

`end-to-end`(`runNeuralRerank`)那条日志本次没有一并回报——待补,但不影响下面的判断(`predict` 段本身
已经占 `predict()`内部合计的 98%+,`setData`/`getData` 单位数毫秒可忽略不计)。

### 判断结果:**predict() 确认是瓶颈,继续阶段 2**

按上面的判断标准,`predict=724~755ms` 占 `total=735~765ms` 的 98%+,`setData`/`getData` 都在 10ms
量级,与 issue 原估算("`getData()`+转 `Float32Array` 不到10ms")吻合。**不需要重新规划方向。**

### 額外发现(代码层面推理,不是这份实测直接证明的):可能解释"秒级"基线的成因

单次 `predict()` 本身只要 ~735~765ms,并不是"几秒"——但 issue 原文的"每次按键 2 秒以上"基线是在
**#22(阶段1改造前)**测的,那时候的旧代码(读 `main` 合并前的 `refreshCandidates()`)确认没有取消
机制,每个字母都会立即触发一次 `predict()`:输入"gongji" 6 个字母,理论上会连续排队 6 次
`predict()`(每次都跑满 ~750ms,前 5 次的结果最后被 buffer 陈旧性守卫丢弃,但计算本身已经发生、CPU
时间已经花掉),累计确实够到秒级。**这是从旧代码结构推出来的合理解释,不是这次实测证明的**——阶段 1
的防抖单测(`NeuralRerankScheduler.test.ets`)证明了"一串 `request()` 只留最后一次待执行"这个逻辑本身
是对的,但"真机上快速连打真的只触发一次 `predict()`"仍然要靠下面的连续打字测试确认,不能从这 4 条
单次按键日志推出来。

### 阶段 2 的空间

单次 `predict()` ~750ms 是阶段 2 要优化的新基线。目标 ≤300ms,issue 预估阶段 2(线程数+绑核+
fp16)能拿到 2~3×,即优化后落在 250~375ms 区间——**有落进 300ms 的可能,但也可能不够,不能假设阶段 2
单独就达标,仍然要下一轮真机数字说话**。

### 下一轮真机测试必须做(不阻塞已经进入的阶段 2 代码实现,但阶段 1 的验收标准还没有任何数据能证明,不是可选项)

**连续不停顿打完 `gongji` 六个字母**这一项是重中之重——目前完全没有数据能区分"防抖生效"和"防抖没生效
但用户碰巧敲得慢"这两种情况,阶段 1 的核心承诺("连续打字期间不发起任何 predict()")目前只有单测证明
了调度逻辑本身对,没有任何真机证据。麻烦优先做这一项,其余顺带一起测:

| 场景 | 待回报数字 |
| --- | --- |
| **连续不停顿打完 `gongji` 六个字母,`predict timings`/`runNeuralRerank` 日志是否只出现一次**(不是"隔得开"就算,是打字期间数一下日志条数) | 是/否 + 实际出现次数 |
| 静态候选(未点亮样式)在连续打字期间是否跟手刷新 | 是/否 |
| 对应上面 4 次按键的 `runNeuralRerank: end-to-end` | ms |
| 停手后首候选是否变成"供给"并点亮样式(蓝色加粗)

### 2026-07-24:连续打字测试第一轮结果——3 次 predict() 而不是 1 次,原因待定

用户快速敲完 `gongji` 后回报 3 条 `predict timings` 日志(不是理想的 1 条),`total` 分别为
877/652/659ms。反推每次 `predict()` 的开始时间(`日志时间戳 - total`),三次调用**首尾相接、几乎不
重叠**(前一次结束到下一次开始,间隔约 313ms/349ms,比 200ms 防抖窗口略大但同量级),不是三次并发/
交叠调用。

**暂时无法判定这是不是 bug**,两种可能都说不通反驳:
1. **不是 bug,是防抖按设计工作**:虚拟键盘逐字母敲击,即使用户主观感觉"快",单键间隔经常自然超过
   200ms(尤其是拼音分段处如"gong|ji"容易有肌肉记忆停顿)——如果真有 2 次超过 200ms 的自然停顿,防抖
   在每次停顿处各触发一次是完全符合设计的,不是缺陷。
2. **是 bug**:比如某种机制让 `predict()` 完成后才"放行"下一批按键处理(打字期间事件被阻塞排队),
   使得按键节奏被 predict() 耗时人为拉长、变相制造出多次"停顿"。

**现有日志没法区分这两种情况**——不知道每个字母具体是几点几分敲的,只能看到 `predict()` 的开始/结束
时间。已经加了一行诊断埋点堵住这个盲区:`Index.ets` 的 `onLetterKey()` 现在会给每个字母单独打一条
`onLetterKey: <字母> (buffer=<当前buffer>)`,时间戳直接用 hilog 自带的那一列,不需要额外计算。

**麻烦重新部署后再做一次同样的连续打字测试,这次把 `onLetterKey` 和 `predict timings`/
`runNeuralRerank` 这几类日志都完整贴出来(不要只挑 predict 那几行)**,能直接看出每个字母的敲击时刻
和防抖触发时刻的对应关系,一次性判定是typing节奏问题还是代码问题。

### 2026-07-24:按键级日志实锤——**不是 bug,防抖按设计工作**

用户回报的按键时间戳:

| 按键 | 时间戳 | 与上一键间隔 |
| --- | --- | --- |
| g | 14:25:08.170 | — |
| o | 14:25:08.440 | 270ms |
| n | 14:25:09.435 | **995ms** |
| g | 14:25:09.450 | 15ms |
| j | 14:25:09.464 | 14ms |
| i | 14:25:09.468 | 4ms |

按 200ms 防抖逐一推演:`g`→`o` 间隔 270ms(>200ms)→ `g` 单独触发一次结算;`o`→`n` 间隔 995ms
(>200ms)→ `go` 单独再触发一次;`n`/`g`/`j`/`i` 四键间隔分别只有 15/14/4ms(远小于 200ms)→
这四键正确收敛成**一次**结算(`gongji` 整体)。**推演出的结算次数正好是 3 次,和之前实测的 3 条
`predict timings` 完全吻合。**

**结论:防抖逻辑没有问题,这次"3 次而不是 1 次"完全是用户自己打字节奏里有两次真实超过 200ms 的停顿
造成的(`g`→`o` 隔了 270ms,`o`→`n` 隔了将近 1 秒)——不是"连续打字",是"打字中间夹了两次停顿"。防抖
对每次真实停顿都正确结算了一次,对最后这段没有停顿的连续按键(`n`/`g`/`j`/`i`)也正确只结算了一次,
没有一键一次地滥发 `predict()`。阶段 1 的核心承诺("连续/无停顿输入期间不发起 predict()")在这份数据
里被直接验证成立,不需要再测。 | 是/否(若"是但没点亮"或"点亮但顺序没变",按上面的 ForEach 诊断提示排查) |
