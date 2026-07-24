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

## 实测结果(待人工填写)

| 场景 | setData(ms) | predict(ms) | getData(ms) | predict()合计(ms) | end-to-end(ms) | 备注 |
| --- | --- | --- | --- | --- | --- | --- |
| 单次按键(g) | | | | | | |
| 单次按键(gongji 最后一击,防抖后触发) | | | | | | |
| 连续打字整串 gongji,是否只触发一次 predict | | | | | | 是/否 |
| 停手后首候选是否变"供给"并点亮 | | | | | | 是/否 |

当前绝对基线(用户此前反馈):每次按键 2 秒以上(#24 issue 原文)。
