# Issue #24 阶段 2:运行时参数(不重转模型)

## 前提:阶段 0 的判断结果

`xupin/docs/issue-24-phase0-instrumentation.md` 的真机实测已确认 `predict()` 是压倒性瓶颈
(`predict=724~755ms` 占 `predict()`内部合计`total=735~765ms`的 98%+,`setData`/`getData` 都在
10ms 量级)。按判断标准,继续做阶段 2。

## 改了什么

`InputMethodService.ets` 的 `loadNeuralModel()`,`msContext.cpu` 从只写 `{}`(全部走默认值)改成
显式设置三个具名常量:

```ts
const NEURAL_THREAD_NUM: number = 4;
const NEURAL_THREAD_AFFINITY_MODE = mindSporeLite.ThreadAffinityMode.BIG_CORES_FIRST;
const NEURAL_PRECISION_MODE: string = 'preferred_fp16';
```

- `threadNum`:默认 2 → 4
- `threadAffinityMode`:默认不绑核 → 绑大核优先(手机通常是大小核架构,推理这种持续吃满 CPU 的任务
  绑大核优先是常规操作)
- `precisionMode`:默认 `enforce_fp32` → `preferred_fp16`(半精度推理,官方文档原话"是否使能"取决于
  芯片支持,"preferred"不是"guaranteed")

三行都不需要重转 `.ms`、不需要重新下发 117MB 资产,只是运行时配置。

## 人工需要做的事(ADR-0002)

1. 构建 + 部署,和阶段 0 同样的方式跑一轮(上屏"发起""物资",打 `gongji`,看 hilog `XupinIME`)。
2. **必须确认 `preferred_fp16` 没有把结果跑错**:首候选变成"供给"这件事,在这一轮里必须仍然成立
   ——`preferred_fp16` 改变数值精度,不是纯粹的性能开关。如果这一轮翻转失败(首候选还是"攻击"或排序
   没变化),**只把 `NEURAL_PRECISION_MODE` 单独改回 `'enforce_fp32'`,threadNum/threadAffinityMode
   不用跟着回退**,再跑一轮确认。
3. 记录新的 `predict timings`/`end-to-end` 数字,和阶段 0 的基线(单次按键 `predict≈735~765ms`)对比。
4. **可选实验,不是本档的默认路径**:`msContext.target = ['nnrt']` + `msContext.nnrt = {}`(可选
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
| 阶段 0 基线(默认参数,对照) | 2(默认) | NO_AFFINITIES(默认) | enforce_fp32(默认) | 724~755 | 待补 | 是(#22 已验证) |
| 阶段 2(三个新参数) | 4 | BIG_CORES_FIRST | preferred_fp16 | | | |
| 若 fp16 翻车,单独回退后重测 | 4 | BIG_CORES_FIRST | enforce_fp32 | | | |
| （可选）nnrt 实验 | - | - | - | | | 成功/加载失败:__ |

达标(≤300ms)与否:__
