# Issue #24 阶段 2:运行时参数(不重转模型)

## 2026-07-24 更新:怀疑 fp16 导致模型加载失败,已回退,待复测确认

第一版(`threadNum=4`+`BIG_CORES_FIRST`+`preferred_fp16`)部署后,人工反馈"神经排序完全不起作用了、
没有蓝色加粗、感觉像回退到通用输入法"——这个症状和"模型压根没加载成功"完全吻合,不是"变慢了"或"排序
错了"的症状。**根因分析**:`loadNeuralModel()` 加载失败时只有 `hilog.warn`(非致命降级,和
`loadDictionary()`/`loadTokenizer()` 同一套设计),不会有任何用户可见的报错;`preferred_fp16` 是
"preferred"不是"guaranteed"(官方文档原话"其余设置情况均为不支持"),如果这台设备的芯片不支持,
`loadModelFromBuffer()` 有可能直接失败而不是静默退回 fp32——一旦模型没加载成功,
`neuralModelHolder` 永远是空,每次按键都会走 `runNeuralRerank()` 里"assets missing"分支,整个体验
和从来没有神经排序时(#20 之前)完全一样,精确对应"回退到通用输入法"这句反馈。

**已经把 `NEURAL_PRECISION_MODE` 单独回退成 `'enforce_fp32'`**(`threadNum`/`threadAffinityMode`
保持不动)——这是本阶段最初就写好的应急预案(见下面判断标准),不是新猜测。

**2026-07-24 后续:回退后复测,神经排序恢复正常。** 用户回报"现在可以正常序列预测了",并贴出 6 条
`predict timings` 日志(见下面"实测结果")。这是一次干净的单变量对照:`threadNum`/
`threadAffinityMode` 全程没变,唯一变量是 `precisionMode` 从 `preferred_fp16` 改回
`enforce_fp32`,问题就消失了——**结论可以定为"这台设备的芯片不支持 preferred_fp16,导致
`loadModelFromBuffer()` 加载失败",置信度较高,但仍缺 `loadNeuralModel failed` 那行日志的原始文本
作为最终实锤**(如果之前那版的日志还留着,补一下更好;没留着不强求,不阻塞后续)。**结论:这台设备上
不要再启用 `preferred_fp16`。**

### 确认根因(复测时必做,不只是看效果)

1. **重新部署这次回退后的版本,启动序拼(触发 `onCreate`→`loadNeuralModel()`),立刻看
   `hdc shell hilog | grep XupinIME` 里有没有这两行之一**:
   - `neural model loaded` —— 模型加载成功
   - `loadNeuralModel failed, neural ranking stays disabled: <code> <message>` —— 加载失败,把
     完整的 `<code>`/`<message>` 也贴出来,这是唯一能确认失败原因的地方
2. 如果这次(`enforce_fp32`)出现 `neural model loaded`,而**上一版(`preferred_fp16`)当时的日志里
   是 `loadNeuralModel failed`**(如果你保留了上一版的 log 请对照确认;如果没保留,至少确认这次
   `enforce_fp32` 下能看到 `neural model loaded`)——那就实锤是 fp16 不被这台设备支持,本节可以标记为
   "已确认根因并修复"。
3. 如果这次 `enforce_fp32` 下**依然没有** `neural model loaded`(也没有 `loadNeuralModel failed`,
   什么都没有),说明问题不在 precisionMode,可能是 `threadNum=4` 或 `threadAffinityMode=
   BIG_CORES_FIRST` 导致的——**回来告诉我这一条,不要自己继续试**,需要重新分析。
4. 顺带确认阶段 1 的老问题:打完 `gongji` 停顿约 1~1.5 秒(200ms 防抖 + ~750ms 推理 + 余量),首候选
   是否变"供给"并点亮。

## 前提:阶段 0 的判断结果

`xupin/docs/issue-24-phase0-instrumentation.md` 的真机实测已确认 `predict()` 是压倒性瓶颈
(`predict=724~755ms` 占 `predict()`内部合计`total=735~765ms`的 98%+,`setData`/`getData` 都在
10ms 量级)。按判断标准,继续做阶段 2。

## 改了什么(当前状态,已含上面的回退)

`InputMethodService.ets` 的 `loadNeuralModel()`,`msContext.cpu` 从只写 `{}`(全部走默认值)改成
显式设置三个具名常量:

```ts
const NEURAL_THREAD_NUM: number = 4;
const NEURAL_THREAD_AFFINITY_MODE = mindSporeLite.ThreadAffinityMode.BIG_CORES_FIRST;
const NEURAL_PRECISION_MODE: string = 'enforce_fp32'; // 原本是 'preferred_fp16',见上面的回退记录
```

- `threadNum`:默认 2 → 4(未回退)
- `threadAffinityMode`:默认不绑核 → 绑大核优先(未回退,手机通常是大小核架构,推理这种持续吃满 CPU
  的任务绑大核优先是常规操作)
- `precisionMode`:**已回退到默认值 `enforce_fp32`,没有实际改动**——这一档目前只剩
  threadNum+threadAffinityMode 两个变量在起作用,fp16 的加速收益暂时拿不到了,等确认根因后再决定是
  否重试。

三行都不需要重转 `.ms`、不需要重新下发 117MB 资产,只是运行时配置。

## 人工需要做的事(ADR-0002)

1. 构建 + 部署这次回退后的版本,先做上面"确认根因"一节的日志检查。
2. 确认神经排序恢复正常(PRD 例子翻转 + 首候选点亮)后,记录新的 `predict timings`/`end-to-end`
   数字,和阶段 0 的基线(单次按键 `predict≈735~765ms`)对比——这次只有 threadNum/threadAffinityMode
   在起作用,提速幅度大概率不如原计划(fp16 那部分没了)。
3. **可选实验,不是本档的默认路径**:`msContext.target = ['nnrt']` + `msContext.nnrt = {}`(可选
   `performanceMode = mindSporeLite.PerformanceMode.PERFORMANCE_HIGH` 之类)。官方样例原话"本样例
   模型,不支持配置 `context.target = ['nnrt']`"——这个 checkpoint 支不支持没人验证过,试一下成本很
   低但也可能直接 `loadModelFromBuffer` 失败。**这是给人工临时改代码试一次的实验,不是这次 PR 要 ship
   的默认行为**——如果想试,自己在 `loadNeuralModel()` 里临时改 `msContext.target`,测完记录结果
   (成功/失败/耗时),不需要让 agent 加自动 fallback 逻辑。

## 判断标准

- 如果新的 `predict`/`end-to-end` 已经 ≤300ms(阶段 0 的目标),**本 issue 到此收工,阶段 3 不做**。
- 如果没达标,把这一档的数字如实记录,阶段 3(N/SEQ 收缩、`--fp16` 转换期量化、`FULL_QUANT`)才启动。

## 实测结果(待人工填写)

| 场景 | threadNum | threadAffinityMode | precisionMode | predict(ms) | end-to-end(ms) | PRD 例子是否仍翻转 |
| --- | --- | --- | --- | --- | --- | --- |
| 阶段 0 基线(默认参数,对照) | 2(默认) | NO_AFFINITIES(默认) | enforce_fp32(默认) | 724~755(平均~735) | 待补 | 是(#22 已验证) |
| 阶段 2 第一版(**确认导致模型加载失败,不要再用**) | 4 | BIG_CORES_FIRST | preferred_fp16 | — | — | 否(神经排序完全不起作用——单变量对照确认是加载失败,不是排序算错) |
| 阶段 2 当前版(已回退 precisionMode,2026-07-24 复测 6 次) | 4 | BIG_CORES_FIRST | enforce_fp32 | 595/607/625/611/611/605(平均~609) | 待补 | 是(用户确认"可以正常序列预测了") |
| （不再计划重试,除非查到这台设备实际支持 fp16 的证据)fp16 | 4 | BIG_CORES_FIRST | preferred_fp16 | | | |
| （可选)nnrt 实验 | - | - | - | | | 成功/加载失败:__ |

### 判断结果:阶段 2(当前配置)预计够不到 300ms,阶段 3 大概率要启动

- `predict` 从阶段 0 基线 ~735ms 降到 ~609ms,只有 `threadNum`+`threadAffinityMode` 在起作用(fp16
  这台设备用不了),提速约 **1.2×**,远低于 issue 原估算"三项合计 2~3×"——因为最大的那个杠杆(fp16)
  已经确认拿不到。
- `predict` 单项已经 ~609ms,只多不少地超过 300ms 的**整个**端到端预算(还没算上 200ms 防抖 +
  ArkTS 侧开销),不存在"再调参数就能压到 300ms 以内"的空间——阶段 2 已经没有别的旋钮了(线程数/绑核
  已经用上,fp16 用不了,`nnrt` 是未知成功率的实验项)。
- 这与 issue 原文的预估一致("阶段 2 单独大概率落在 700ms~1s,阶段 3 很可能真的需要做")——只是因为
  fp16 用不了,实际结果比原估算的下限还要差一些。
- **达标(≤300ms)与否:否。** 按分档 gate 的触发条件("阶段1+2都做完仍不达标"),阶段 3 的条件已经
  满足,但启动前还要确认阶段 1 自己的验收标准(连续打字防抖是否真的只触发一次 predict)——这一项目前
  仍然完全没有真机数据,阶段 0/2 的日志都是"一个字母等稳定再敲下一个"的单次按键节奏,不是连续打字。
