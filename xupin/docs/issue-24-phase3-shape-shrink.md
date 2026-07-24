# Issue #24 阶段 3:N/SEQ 分档收缩

## 前提:阶段 1+2 的判断结果

`xupin/docs/issue-24-phase2-runtime-params.md` 已确认阶段 2(`threadNum=4` + `BIG_CORES_FIRST` +
`enforce_fp32`,`preferred_fp16` 在这台设备上加载失败已回退)实测 `predict()` ≈609ms,仍远超 300ms
目标,且阶段 2 已经没有别的旋钮(线程数/绑核已用上,fp16 用不了,`nnrt` 是未知成功率的实验项)。按分档
gate,阶段 3 启动。

## 第 1 项:N 9→5,SEQ 20→16(已完成,等待真机对照)

### 改了什么

- `CandidateGenerator.ets`:`DEFAULT_DISPLAY_LIMIT` 9 → 5。
- `NeuralScorer.ets`:`DEFAULT_MAX_CANDIDATE_TOKENS` 8 → 4;`DEFAULT_CONTEXT_WINDOW_CHARS` 保持
  12 不变。`sequenceLength = contextWindowChars + maxCandidateTokens` 因此从 20 变成 16。
- 两处的文档注释同步更新(引用的历史数字 9/20/8 标注为"原值",不悄悄改写 #22 当时的决策记录
  `issue-22-shape-fix.md` 本身——那份文档是 #22 的历史快照,留作 #22 当时决策的证据,不随 #24 的改动
  回改)。
- `CandidateGenerator.test.ets` 里依赖 `DEFAULT_DISPLAY_LIMIT` 具体值的断言(`results.length`)从
  9 改成 5。`hvigorw test` 全绿(0 条 `ERROR:` 行)。

  **验证方法上的一个坑,记一下**:`hvigorw test` 的 `BUILD SUCCESSFUL` **不代表测试全过**——故意把这条
  断言改成错误值(`assertEqual(999)`)复测过,hypium 会在 stdout 打一行
  `ERROR: Error in <test name>, expect X equals Y` 并列出 `AssertException` 堆栈,但 hvigor 任务
  本身仍然收在 `BUILD SUCCESSFUL`(它只是构建+生成覆盖率报告成功,不是"测试全部通过"的信号)。之后每次
  跑 `hvigorw test` 必须 grep 输出里的 `ERROR:`,不能只看最后一行 `BUILD SUCCESSFUL`。

- 候选 token 上限继续压到 2(而不是止步于 4)已经讨论过并否决,不是这次漏做——理由(用
  `words.dict.tsv` 实测过):4→2 只让 SEQ 从 16 降到 14,是 N/SEQ/候选三个杠杆里最小的一块(线性估算
  `predict()` 只多省约 34ms),但会让前两字相同的多字候选(如"社会主义"/"社会上")神经分算成完全相同的
  值,丢失区分度,不划算。维持 4。

### 词典覆盖率数字(用于 doc 注释,实测而非凭记忆)

用 `entry/src/main/resources/rawfile/dict/words.dict.tsv`(格式 `pinyin\tword\tweight`,208652 条)
统计 `word` 列长度分布:

| 阈值 | 覆盖条目 | 占比 | 超出部分 |
| --- | --- | --- | --- |
| ≤8 字符(阶段 2 之前的值) | 208527 | 99.94% | 125 条 |
| ≤4 字符(本次新值) | 201266 | 96.46% | 7386 条 |

与 issue 原文估算的 96.5% 吻合。超出 4 字符的候选按前 4 个 token 打分(`meanTeacherForcedLogProb`
本身长度归一化,是截断估计,不是降级)。

### 重新导出 + 转换 `.ms`

1. `tools/issue-22-export-onnx.py` 重新导出(同一 checkpoint
   `uer/gpt2-chinese-cluecorpussmall`,图本身是动态 `batch_size`/`sequence_length`,不需要因
   N/SEQ 改动重新导出,但本机没有缓存的 `onnx_nocache/`,所以还是走了一次完整导出)。确认导出的
   input/output 签名和 #22 记录的一致:`input_ids`/`attention_mask`/`position_ids`(INT64)→
   `logits`(FLOAT,`[batch_size, sequence_length, 21128]`)。
2. `tools/issue-22-convert-ms.sh <onnx dir> <out dir> 5 16`(colima x86_64 + docker,同 #22 的
   流程)转换出:
   - `static_5_16_fp32.ms`:473,314,352 字节(~451.4MB)
   - `static_5_16_quant.ms`(`WEIGHT_QUANT` int8,和阶段 2 用的是同一种量化,只压体积不提速):
     122,328,592 字节(~116.6MB)——和阶段 2 用的 `[9,20]` 版本(122,337,872 字节)几乎同大小,符合
     预期:体积主要由参数量决定,batch/seq 收缩对权重量化后的文件大小几乎没有影响。
   - `benchmark_lite` smoke test(不传 `--inputShape`)两个 `.ms` 都跑通,确认 shape 真的在转换时
     baked 进去了(同 #22 的验证方法)。**这一步只是"能跑"的确认,不是速度参考**——x86_64 虚拟机跑的是
     未做 ARM NEON 优化的通用算子路径,测出来的 ~13.8s/次跟手机 ARM CPU 的真实耗时没有可比性,不要拿这
     个数字类比。
3. 已把 `static_5_16_quant.ms` 改名 `neural_scorer.ms`,替换进
   `entry/src/main/resources/rawfile/model/`(覆盖了阶段 2 用的 `[9,20]` 版本;旧版本备份在本机
   `/tmp`,不在仓库版本控制范围,这个模型资产目录本身就在 `.gitignore` 里)。`vocab.txt` 不变——
   tokenizer 跟 shape 无关。

### 已跳过:`--fp16` 转换

issue 原文阶段 3 第 2 项(转换时加 `--fp16`)**本次不做**——用户确认此前已经验证过并报错,不再重试。
不清楚具体报错信息(不在这次对话记录范围内),只记录"已验证过、不要再碰"这个结论本身,后续 session 看到
这条不要重新提议。

## 第 2 项:`FULL_QUANT` 调研(评估阶段,未实施)

本地文档语料(`docs/harmonyos-guides/`)没有覆盖量化配置文件字段,查的是 MindSpore Lite 上游官方文档
(`mindspore.cn/lite/docs/en/r2.7.0/advanced/quantization.html`,版本号对应
`issue-22-convert-ms.sh` 里固定的 `MINDSPORE_LITE_VERSION=2.7.0`)。

### 确认的配置字段

`quant_type=FULL_QUANT`(`[common_quant_param]` 段,8-bit only,不像 `WEIGHT_QUANT` 支持
0~16 bit 任意选)。除了 `weight_quant.cfg` 已有的 `[common_quant_param]`,还需要新增两段:

```
[data_preprocess_param]
calibrate_path=input_ids:/path/to/dir,attention_mask:/path/to/dir,position_ids:/path/to/dir
calibrate_size=100~500 之间(文档推荐区间)
input_type=BIN   # 不是 IMAGE——我们三个输入都是 int64 的 token/mask/position 序列,不是图片,
                 # IMAGE 那一路的 image_to_format/normalize_mean/std/resize_* 字段跟本模型无关

[full_quant_param]
activation_quant_method=MAX_MIN(或 KL / REMOVAL_OUTLIER)
bias_correction=true
per_channel=true
```

`calibrate_path` 要求多输入时每个输入名对应一个单独目录,目录里放 `.bin` 文件,内容是该输入单个样本的
原始数据 buffer(格式要跟推理时实际喂给模型的格式一致——对我们来说就是跟 `buildBatchRow()`/
`buildDummyRow()` 产出的 `int64` 数组逐字节一致,不是图片的 NHWC 布局,那是给 CV 模型场景写的默认假
设,可以忽略)。

### 结论:技术上可行,但要先看第 1 项够不够,不是默认要做的下一步

1. **可行性没有硬性阻碍**:`input_type=BIN` 这条路径就是给非图片模型用的,不需要伪造图片输入。
2. **成本比 `WEIGHT_QUANT` 高一整层**:`WEIGHT_QUANT`(阶段 2、本次都在用)不需要校准集;`FULL_QUANT`
   需要真造 100~500 个"上下文 + 候选 token"对应的 `input_ids`/`attention_mask`/`position_ids` 三元
   组(shape 都是 `[5,16]`,跟当前 batch/seq 绑定),按真实使用分布构造(文档原话"calibration data
   must be co-distributed with training data")——这是本仓库现有语料(`words.dict.tsv` 之类)里没有
   现成脚本能直接产出的,需要专门写一段采样代码。
3. **精度风险未知**:上游文档自己写"Full Quantization... provides better inference acceleration
   with average precision loss"——对 causal LM 的 attention/softmax 路径做激活量化,是否会破坏
   PRD 例子(供给/攻击)那种细粒度的排序翻转,没人验证过,只能造出校准集实测才知道。
4. **按 issue 原文 gate("每做一项跑一次真机对照,达标即停,不必三项全做完")**:如果第 1 项(N/SEQ
   收缩)真机对照已经 ≤300ms,本项直接不做,省下造校准集的成本。**先等第 1 项的真机数字,再决定要不要
   启动这项**——不是本次顺手就做的下一步。

## 人工需要做的事(ADR-0002,agent 不碰真机)

1. 构建 + 部署这次的版本(`neural_scorer.ms` 已经是 `[5,16]` shape,替换到位)。
2. 先做和阶段 2 一样的加载确认:`hdc shell hilog | grep XupinIME`,确认出现 `neural model loaded`
   而不是 `loadNeuralModel failed`(排除"看起来变快了其实是模型没加载,退化成静态排序"这个假阳性)。
3. PRD 例子(发起"物资"上文 + `gongji` → 供给应该翻到第一位并点亮)确认仍然翻转——SEQ 从 20 收缩到
   16、候选 token 上限从 8 收缩到 4 之后,这个例子的两个候选词都是 2 字词,没有超过新的 4-token 上限,
   理论上不受影响,但要实测确认,不能假设。
4. 记录新的 `predict timings`(`setData`/`predict`/`getData`/`total`)和 `runNeuralRerank:
   end-to-end`,填进下面的表格。
5. **达标(神经重排 ≤300ms)就此收工,不用做 `FULL_QUANT`**;没达标,回来说一声,再决定是否启动上面
   "第 2 项"的校准集构造工作。

## 实测结果(待人工填写)

| 场景 | N(batch) | SEQ | predict(ms) | end-to-end(ms) | PRD 例子是否仍翻转 |
| --- | --- | --- | --- | --- | --- |
| 阶段 2 基线(对照,已确认) | 9 | 20 | 595~625(平均~609) | 待补 | 是 |
| 阶段 3 第 1 项(N=5, SEQ=16) | 5 | 16 | | | |

### 判断结果:待人工数字回填后补充
