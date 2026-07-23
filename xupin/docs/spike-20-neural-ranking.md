# Issue #20 phase 1 spike: neural context-aware ranking feasibility

Status: **conversion/execution feasibility confirmed; only real-device latency/memory remain
pending (human, ADR-0002)**. This document is the phase-1 spike deliverable required before
phase 2/3 (`CandidateScorer` rebuild, tokenizer, `NeuralScorer`, UI wiring) can start.

Checkpoint under test: `uer/gpt2-chinese-cluecorpussmall` (HuggingFace, `GPT2LMHeadModel`).

## TL;DR

| Question | Answer | Confidence |
| --- | --- | --- |
| Tokenizer granularity | Character-level for Chinese, confirmed | Confirmed (vocab.txt + live `encode()`) |
| Architecture | 12 layer / 12 head / 768 hidden / vocab 21128 / ~118.3M params | Confirmed (`config.json`) |
| ONNX export (no cache, and `use_cache=True` KV-cache I/O) | Both succeed | Confirmed, ran locally |
| Will `converter_lite` accept these ONNX graphs? | **Yes, both convert successfully** (fp32 and int8 weight-quant, all 4 combinations) | **Confirmed — real `converter_lite` 2.7.0 run, not doc analysis** |
| Does the no-cache (single-shot) graph actually run inference? | **Yes** — fp32 and int8-weight-quant both execute correctly | **Confirmed — real `benchmark_lite` run** |
| Does the KV-cache graph actually run inference? | **Only when the shape is fixed at conversion time** (`--inputShape`); the default dynamic-axis export converts fine but **fails at runtime** (`InferShape fail!` at a `Concat` node) unless baked static. This matches — and empirically confirms — ArkTS's documented static-shape-only constraint | **Confirmed — real execution, both the failure and the fix** |
| Practical implication for cross-keystroke cache reuse | Not reachable as a single reusable model the way `optimum`'s default export produces it; would need a custom fixed-`MAX_CACHE_LEN`-buffer export (phase-2 engineering, not attempted here) | Confirmed constraint; design work is future scope |
| `.ms` file sizes | fp32 ~451.5MB, int8 weight-quant ~116.9MB (both graph variants) | **Confirmed, real converter output** |
| Device latency / memory on real ARM hardware | Unknown | **Pending — human, real device (ADR-0002)**, see §7 |
| Model checkpoint license | **Disputed** — see [License status](#license-status-disputed-not-confirmed) | **Needs a decision, not confirmed** |

Only one item is still genuinely pending: real-device latency/memory, which requires a human on
real ARM hardware per ADR-0002. Everything else that can be resolved without a device has been
resolved — with the real `converter_lite`/`benchmark_lite` tools, not just documentation
analysis (see §5a for how; §7 for the handoff and reproduction path).

## 1. Tokenizer granularity (acceptance criterion: inspect `vocab.txt` before assuming)

`vocab.txt` has 21,128 lines. Breakdown:

- 104 special tokens (`[PAD]`, `[unused1..100]`, `[CLS]`, `[SEP]`, `[UNK]`, `[MASK]`).
- 8,000 single-CJK-character tokens in "plain" form (e.g. `发`, `起`) — these are what
  `BertTokenizerFast` actually emits for Chinese text.
- 8,000 more entries that are the *same* 8,000 characters again, `##`-prefixed
  (BERT WordPiece's "continuation of a word" marker, e.g. `##发`) — see below for why these are
  never used on Chinese input.
- The remaining ~5,024 "multi-character" entries are not Chinese words: digits/years
  (`2017`, `12`), Latin-script WordPiece fragments (`ing`, `tion`, `com`), and a small residual
  (~225) of stray non-Chinese symbol/kana sequences leaked from the CLUECorpusSmall web-scrape
  (e.g. `てす`, `▲top`, `￥799`) — noise, not vocabulary a pinyin IME's dictionary would ever
  produce.

Live confirmation (`BertTokenizerFast.encode()`, no special tokens), using the exact PRD example
from issue `#6`'s context:

```
'发起'             -> ['发', '起']                         [1355, 6629]
'物资'             -> ['物', '资']                         [4289, 6598]
'攻击'             -> ['攻', '击']                         [3122, 1140]
'供给'             -> ['供', '给']                         [897, 5314]
'发起物资攻击供给'  -> ['发','起','物','资','攻','击','供','给']  (8 separate tokens)
'gongji' (romanized pinyin, not real input) -> ['go', '##ng', '##ji']
```

**Conclusion: every Chinese character is its own token, always via the plain (non-`##`) vocab
entry.** This is because BERT's `BasicTokenizer` pre-splits Chinese text by inserting a boundary
around every CJK character before WordPiece ever runs (`_tokenize_chinese_chars`), so each
character is handed to WordPiece as its own 1-character "word" and WordPiece finds a direct
whole-token match — the `##` continuation form only fires for sub-pieces *within* multi-character
words, which never happens for isolated CJK characters. The `##`-prefixed CJK half of the
vocabulary is therefore dead weight for this project's use case (candidate words are always
Chinese), not something the ArkTS tokenizer needs to handle.

**Implication for phase 2's tokenizer**: a straightforward `char -> id` map built from the plain
single-character vocab entries is sufficient for scoring Chinese candidate words. No multi-token
merge/greedy-longest-match logic is needed for that path. (The `##`/Latin/digit entries would
only matter if the model were ever asked to tokenize non-Chinese input, which is out of scope —
`ScoringContext.precedingWords` and candidate words are always Chinese per `CandidateEntry`.)

## 2. Architecture (`config.json`, via `transformers.GPT2Config.from_pretrained`)

```
GPT2LMHeadModel: n_layer=12, n_head=12, n_embd=768, n_positions=1024,
vocab_size=21128, activation_function=gelu_new (tanh approximation, not exact/erf GELU)
```

Total parameters (from the exported ONNX graph's initializers): **118,295,040** (~118.3M).
fp32 ONNX file size: ~451.3–451.6MB for both export variants (matches 118.3M × 4 bytes). This is
larger than the "GPT2-base ≈124M" folk number would suggest relative to English GPT2 despite the
smaller (21,128 vs 50,257) vocab — the ONNX export does not tie the input embedding and output
`lm_head` projection weights into one matrix, so the ~16.2M-parameter embedding table is
effectively duplicated in the graph. This duplication is a pure export artifact; whether
`converter_lite` also carries it into the `.ms` file (or a MindSpore Lite weight-dedup pass
removes it) is one of the things the real conversion run will show.

## 3. ONNX export — confirmed, reproducible locally (`xupin/tools/spike-20-export-onnx.py`)

Exported both task variants via `optimum-cli export onnx`:

- `text-generation` (no cache): single forward pass. Inputs: `input_ids`, `attention_mask`,
  `position_ids` (all `int64`, shape `[batch, seq_len]`). One output: `logits`
  `[batch, seq_len, 21128]`.
- `text-generation-with-past` (`use_cache=True`): 27 inputs (`input_ids` + 12 layers ×
  `past_key_values.N.{key,value}` + `attention_mask` + `position_ids`), 25 outputs (`logits` +
  12 layers × `present.N.{key,value}`). Each `past_key_values.N.key/value` is
  `[batch, 12, past_sequence_length, 64]` — `past_sequence_length` is a **dynamic** ONNX axis in
  this default export (grows by the step size every call).

Both exports succeeded (only a harmless fp32 numerical-tolerance warning from `optimum`'s
self-check, max diff ~7e-5 against a 1e-05 threshold — expected ONNX-vs-PyTorch floating point
drift, not a correctness bug).

**This confirms the KV-cache graph *shape* issue #20 asks about exists and exports cleanly** —
the "does a graph with cache state as extra inputs/outputs even exist" half of the spike
question. The remaining, more consequential half — can `converter_lite` convert it, and can
ArkTS actually drive it call-to-call — is addressed in §4 and §5.

Environment note for reproduction: requires **Python 3.10+**. macOS system Python (3.9.6) fails
with `TypeError: unsupported operand type(s) for |: 'pybind11_type' and 'NoneType'` inside
`torch.onnx.utils` — current `torch`/`transformers` releases use PEP 604 `X | None` unions that
`typing.get_type_hints` evaluates eagerly, which needs 3.10+. Confirmed empirically; not a
platform-specific MindSpore issue, just a version floor for the export tooling. Used
`brew install python@3.11` for the actual export venv.

## 4. KV-cache on ArkTS: **the growing-cache pattern is not reachable through the public ArkTS API**

This is a documented platform constraint, not a device measurement, and it directly answers the
issue's "MindSpore Lite 转换/推理是否真的支持这种缓存状态作为额外输入输出的图结构" question for
this project's actual constraints — this project is ArkTS-only, it does not have a Native
(C/C++) module.

From `docs/harmonyos-guides/AI/MindSpore Lite Kit（昇思推理框架服务）/使用MindSpore Lite实现图像分类（ArkTS）.md`:

> 若需基于本Demo适配自有模型，请优先选择静态Shape模型。**由于ArkTS暂不支持动态Shape**，如确有
> 相关需求，请参考使用MindSpore Lite实现图像分类（C/C++），通过Native侧的
> **`OH_AI_ModelResize`** 接口对模型inputs进行动态调整。

The ArkTS binding (`@kit.MindSporeLiteKit`, `mindSporeLite.loadModelFromFile/Buffer` →
`model.predict()`) has no resize/reshape entry point at all — that capability exists only in the
Native C-API (`OH_AI_ModelResize`), which this project does not use and would be a substantial
new engineering surface (NAPI bridge, build toolchain changes) to introduce, well beyond this
issue's scope.

What this rules out specifically: the textbook incremental-decoding win — run the shared
preceding-context forward pass once, cache it, then for each of up to ~50 candidates
(`DEFAULT_DISPLAY_LIMIT`, `CandidateGenerator.ets`) do a cheap 1-token-at-a-time forward reusing
that cache — requires the cache tensor's sequence-length dimension to grow by one on every call
to the *same loaded model*. That is exactly the resize operation ArkTS's API doesn't expose.

What it does **not** rule out — and §5a below confirms this empirically, not just in theory — is
a graph exported with an always-fixed-size cache buffer (e.g. a constant `MAX_CACHE_LEN` physical
slot count, with `attention_mask`/`position_ids` telling the model which slots are real vs.
unused, so every `predict()` call uses identically-shaped tensors). Producing such a graph is
**not** what `optimum`'s standard export gives you by default (it emits the dynamic-axis form
shown in §3) — getting there needs either `converter_lite --inputShape` to bake in one fixed
length (§5a: confirmed to work, but produces one `.ms` per fixed length) or custom ONNX graph
surgery for a genuinely reusable fixed-`MAX_CACHE_LEN` buffer (not attempted here — phase-2-scale
implementation work, out of scope for this spike per the plan agreed before starting it).

**Working conclusion**: true cross-keystroke KV-cache reuse — one loaded model, cache grows by
one slot every call — is not available to this project through ArkTS alone, and (per §5a) not
through MindSpore Lite Kit's own shape inference either when the shape is left dynamic. The
practical question the gate turns on is narrower than the issue originally framed it: not "is
KV-cache viable" but **"is a single fixed-context-window forward pass (no cache reuse) per
candidate fast enough"** — which is exactly the fallback path the issue already specifies
(`StaticWeightScorer` first pass + `NeuralScorer` re-ranking only the top 15–20). The device
latency number (§6, pending) now has to answer that question specifically: is a full ~8–20 token
forward pass fast enough to run up to ~20 times per keystroke?

## 5. `converter_lite` op-support risk — predicted from docs, then checked against the real binary

`docs/harmonyos-guides/AI/MindSpore Lite Kit（昇思推理框架服务）/附录/MindSpore Lite Kit算子支持列表.md`
documents MindSpore Lite Kit's CPU-backend op support "与ONNX Opset18相比". Diffed the exported
graph's actual op histogram against that table (`tools/spike-20-export-onnx.py`,
`report_op_diff`) *before* the real converter was available, to know what to watch for. Same
result for both export variants:

```
938-944  Constant           <- not in the table (see caveat below)
   259   Unsqueeze          supported
   238   Shape              supported
   174   Gather             supported, BUT see int64 note below
   177   Concat             supported
   150   Reshape            supported
    74   Mul                supported
    64   Add                supported
    64   Slice              supported
    60   Transpose          supported
    52   Squeeze            supported
    48   Gemm               supported
    36   Sqrt               supported
    33   Cast               supported, BUT see int64 note below
    25   LayerNormalization <- not in the table (see caveat below)
    25   MatMul             supported
    12   Split              <- NOT IN THE TABLE
    12   Div                supported
    12   Softmax            supported
    12   Pow                supported ("仅支持指数为单个常数" — exponent here is a constant 3, fine)
    12   Tanh               supported
     5   Where              supported
     4   ConstantOfShape    <- NOT IN THE TABLE
     2   Sub                supported
     2   Equal              supported
     2   Expand             supported
     1   Range              supported
     1   Less               <- NOT IN THE TABLE
```

Three real, unambiguous gaps: **`Split`, `ConstantOfShape`, `Less`** do not appear anywhere in
the documented op table. Each appears only a handful of times (likely: `Split` for QKV
projection splitting, `ConstantOfShape`/`Less` for causal-mask construction), so if
`converter_lite` genuinely can't handle them this reads as a fixable "the fusion/fallback pass
doesn't recognize this exact op" problem rather than "the model is fundamentally
inconvertible" — but it can't be resolved without running the real tool.

Two ambiguous ones, flagged rather than treated as blockers:

- **`Constant`** (938/944 occurrences, by far the most common node): absent from the table, but
  this most likely reflects the table only listing ops that need a *runtime kernel* — `Constant`
  nodes are typically folded into the graph's static weight/tensor representation at conversion
  time, not executed. Treated as low risk pending confirmation.
- **`LayerNormalization`** (25 occurrences — 2 per transformer block + 1 final, exactly matching
  12 layers): also absent as its own table row, but the *separate* model-conversion doc
  (`使用MindSpore Lite进行模型转换.md`, "关闭指定算子融合" appendix) lists
  `OnnxLayerNormFusion`/`OnnxLayerNormFusion2` as **fusion passes** the converter applies —
  implying the converter recognizes LayerNorm as a *pattern* (built from primitives) it fuses
  into an efficient kernel, not that it accepts ONNX's native single-node `LayerNormalization`
  op (added in opset 17) as-is. Since our export already emits the single fused
  `LayerNormalization` node rather than the decomposed primitive form, whether the fusion pass
  still recognizes/accepts it is genuinely unclear from documentation and is exactly the kind of
  thing that only running the real converter resolves.

**The `int64` finding is the most consequential one predicted from docs alone.** The same table's
header note states, unconditionally: *"以下所有算子，均不支持int64类型输入"* (none of the listed
ops support int64-type input). Checked the actual exported graph's dtypes directly (not just
assumed): `input_ids`/`attention_mask`/`position_ids` are `int64` (standard for any
HuggingFace/BERT-family tokenizer output), all 174 `Gather` nodes' indices are confirmed `int64`
(this is fundamentally the token-embedding lookup — `Gather(embedding_table, input_ids)` — the
single most unavoidable operation in any token-based model), and `Cast` nodes include
`int64 -> float`/`int64 -> int64` conversions (also confirmed, not assumed). If this restriction
is as blanket as written, the standard `optimum` export would not be directly convertible as-is.
**This did not happen — see §5a.** All of the doc-predicted risks in this section (`Split`,
`ConstantOfShape`, `Less`, `LayerNormalization`, the blanket int64 restriction) turned out not to
block conversion or execution in practice. Kept in this document as-is (rather than deleted) as a
record that doc-only static analysis over-predicted risk here — worth remembering next time a
similar question comes up and the real tool isn't available yet: run the real tool before
treating a docs gap as a blocker.

## 5a. Real `converter_lite` run — confirmed via Docker (Linux x86_64 container, since `converter_lite` has no macOS build)

`converter_lite`/`benchmark_lite` ship only for Linux x86_64 (confirmed: the official download is
Linux-x86_64-only, source build requires Linux, and the `mindspore-lite` PyPI package is a single
stale Linux-only 2.0.0 wheel — no macOS path exists). Ran the real MindSpore Lite 2.7.0 release
tarball inside a Linux x86_64 Docker container (via `colima start --arch x86_64`, i.e. QEMU
emulation on this Apple Silicon Mac) rather than skip this step. **Emulated x86 timing numbers
from this are explicitly not used as latency data anywhere in this document — QEMU adds huge,
unrepresentative overhead, and the target hardware is ARM, not x86 — this step is only used to
answer yes/no conversion and execution questions.**

**Conversion — all 4 combinations succeeded:**

| Variant | Command | Result | `.ms` size |
| --- | --- | --- | --- |
| no-cache, fp32 | `converter_lite --fmk=ONNX --modelFile=onnx_nocache/model.onnx` | `CONVERT RESULT SUCCESS:0` | 473,500,352 B (~451.5 MB) |
| no-cache, int8 weight-quant | + `--configFile=weight_quant.cfg` (`quant_type=WEIGHT_QUANT`, `bit_num=8`, `per_channel=true`) | `CONVERT RESULT SUCCESS:0` | 122,514,456 B (~116.8 MB) |
| with-cache (KV-cache), fp32, dynamic shape | same, no `--inputShape` | `CONVERT RESULT SUCCESS:0` | 473,517,072 B (~451.5 MB) |
| with-cache, int8 weight-quant, dynamic shape | + `--configFile=weight_quant.cfg` | `CONVERT RESULT SUCCESS:0` | 122,531,224 B (~116.9 MB) |

Weight quantization gives the expected ~3.9× size reduction (matches the documented "roughly 1/4
of fp32" expectation). **This directly resolves the doc-predicted op-support risk in §5**: a
model using `Gather` with `int64` indices, `Split`, `ConstantOfShape`, `Less`, and a native
`LayerNormalization` node converts cleanly on the real 2.7.0 converter, contradicting what a
literal reading of the supported-op table would have predicted. The table is evidently either
outdated or narrower than the converter's actual behavior — a useful thing to know for future
spikes: don't stop at the doc when the real tool is reachable.

**Execution — this is where the real, load-bearing finding is**, run via `benchmark_lite`
(MindSpore Lite's own CPU-backend inference smoke-test tool, included in the same tarball):

- **No-cache, fp32**: ran successfully at `input_ids/attention_mask/position_ids` shape `[1,8]`.
  `Run Benchmark nocache_fp32.ms Success.`
- **No-cache, int8 weight-quant**: ran successfully at `[1,8]` and again at `[1,20]` (issue's
  suggested upper context-window bound). `Run Benchmark ... Success.` both times. Confirms
  weight-quant models still do fp32 compute at inference (per MindSpore's own docs — quant here
  only shrinks storage, doesn't change the inference dtype), matching what the doc said to
  expect.
- **With-cache (KV-cache), fp32, shape resized at *inference* time** (`benchmark_lite
  --inputShape=...`, mirroring what a `Resize`-based ArkTS flow would have to do since ArkTS
  itself doesn't support resize at all — see §4): **fails**, both with an empty cache
  (`past_sequence_length=0`) and a non-empty one (`past_sequence_length=8`):
  ```
  [ERROR] ... [te_kernel.cc:51] PreProcess] InferShape fail!
  [ERROR] ... run kernel PreProcess failed, name: /transformer/h.0/attn/Concat_4
  ... Run Benchmark withcache_fp32.ms Failed : -1
  ```
  The failure is at the first transformer block's attention `Concat` — the op that joins cached
  keys/values with the newly computed ones. Not an edge case tied to the empty-cache first call;
  reproduced identically at a non-zero past length.
- **With-cache, fp32, shape fixed at *conversion* time instead** (`converter_lite
  --inputShape='input_ids:1,1;past_key_values.N.key:1,12,8,64;...'`, one specific past length
  baked into the `.ms` file rather than left resizable): **succeeds.**
  `Run Benchmark withcache_staticshape.ms Success.`

**This resolves the issue's own KV-cache gate criterion** ("导出时开了 use_cache 的图，MindSpore
Lite 转换/推理是否真的支持这种缓存状态作为额外输入输出的图结构——这个结论直接决定阶段 2 的退路是
否需要启用") **— not a side finding, the answer to it.** It doesn't just corroborate the ArkTS
"static shape only" doc finding from §4 — it reproduces the *exact* failure mode a dynamic-shape
KV-cache graph would hit, and confirms the fix is the same one the docs point to: **the shape
must be fixed at conversion time, not left dynamic and resized at runtime.** Since ArkTS has no
resize capability at all (§4), it was always going to need the conversion-time-fixed form — this
run confirms that form is real and functional, not just theoretically permitted. The remaining
gap to a genuinely reusable cross-keystroke cache (one model, many different past-lengths) is a
fixed-`MAX_CACHE_LEN`-buffer export design, which is real but bounded phase-2 engineering, not a
new unknown. **Answer to the gate question: the retreat path (StaticWeightScorer full-set pass +
NeuralScorer re-ranking only the top 15–20, §4) is confirmed necessary** — not because latency
forces it (that number is still pending), but because cross-keystroke cache reuse the way
`optimum`'s default export shapes it is confirmed non-functional on this runtime, independent of
how fast the device turns out to be.

Reproduction: `xupin/tools/spike-20-convert-ms.sh` (Docker-based, self-contained — downloads the
official Linux x86_64 MindSpore Lite 2.7.0 release inside the container, no host Linux machine
needed, works from this same macOS/Apple-Silicon setup via `colima start --arch x86_64`). Note on
this script's own verification: every command in it was run interactively during this spike and
confirmed to produce the results above; the script itself (assembled from those commands
afterward, to make the recipe reusable) is syntax-checked (`bash -n`) but has not been re-run
end-to-end as a single script — if it hiccups on a first run, diff it against the commands
described above rather than assuming the recipe itself is wrong.

## 6. Real-device numbers — pending, human-only (ADR-0002)

Everything resolvable without a device is now resolved (§1–§5a). What's left is exactly the two
numbers only a real phone can produce: **inference latency** and **memory footprint**, for the
already-produced, already-quantized `.ms` files. See §7 for exact steps and what to report back.

## 7. Handoff: what the human needs to run

### What already exists (no re-conversion needed)

Five `.ms` files, already converted and quantized by this spike, sitting at
`~/.claude/jobs/fb06b491/tmp/spike20-ms-artifacts/` on this machine (not committed to git — see
"why these aren't in git" below). **That job's tmp directory is deleted along with the job — copy
`nocache_quant.ms` (the one that matters, see below) somewhere durable before that happens.**
Regenerating it costs re-running `spike-20-convert-ms.sh`, which needs a ~15–20 min colima+QEMU
respin (mostly the base VM image download) — not lost work, but not free either.

| File | Size | Graph | Shape | Runs? (x86 smoke test only, not real timing) |
| --- | --- | --- | --- | --- |
| `nocache_fp32.ms` | ~451.5 MB | single forward pass | dynamic (resize at load) | Yes |
| `nocache_quant.ms` | ~116.8 MB | single forward pass, int8 weight-quant | dynamic (resize at load) | Yes |
| `withcache_fp32.ms` | ~451.5 MB | KV-cache I/O | dynamic | **No — do not use for device testing** |
| `withcache_quant.ms` | ~116.9 MB | KV-cache I/O, int8 weight-quant | dynamic | Not tested (same dynamic-shape issue expected; untested because withcache is out of scope for the device test below) |
| `withcache_staticshape.ms` | ~451.3 MB | KV-cache I/O | fixed at conversion (`input_ids:1,1`, `past_key_values.N:1,12,8,64`) | Yes — proof of concept only, not what the device test below needs |

**For the device test, use `nocache_quant.ms`** — it's the one that matches phase 2's actual
fallback design (§4's conclusion: single fixed-context-window forward pass, no cache reuse, one
candidate at a time) and it's the smallest file. `withcache_*` files are included for completeness
/ future reference, not for this round of device testing.

### Why these `.ms` files aren't committed to git

They're derived spike artifacts (regenerable by `tools/spike-20-convert-ms.sh` +
`tools/spike-20-export-onnx.py`), multi-hundred-MB binaries, and — see
[License status](#license-status-disputed-not-confirmed) — from a checkpoint whose license isn't
actually confirmed yet. None of those are reasons to put them in version control. If phase 2/3
proceeds on this checkpoint, the license question needs to resolve first regardless of these
specific files.

### Update: phase 2/3 landed since this section was written

The real IME (not a throwaway page) now has the loading/scoring wiring built and unit-tested
(`Tokenizer.ets`, `NeuralScorer.ets`, `MindSporeNeuralModel.ets`,
`InputMethodService.loadTokenizer()`/`loadNeuralModel()`) — `syscap.json` already exists too. It
loads exactly two rawfiles, both currently absent on purpose (license still unresolved, §"License
status" below): `entry/src/main/resources/rawfile/model/vocab.txt` (the checkpoint's tokenizer
vocab — itself checkpoint-derived, same deferred-license bucket as the `.ms` file, not just the
weights) and `entry/src/main/resources/rawfile/model/neural_scorer.ms`. Both loads fail gracefully
and leave neural ranking degraded to static-only until both files are present — see
`InputMethodService.ets`'s comment on those constants. This means step 2 below should drop
`nocache_quant.ms` at that path **renamed to `neural_scorer.ms`** (plus `vocab.txt` alongside it)
rather than building a separate scratch page — the throwaway-page approach in step 3 is still a
valid *first* smoke test (isolates model-loading/latency from the rest of the IME), but the real
device go/no-go should ultimately exercise the actual IME panel, not just a scratch page.

### Steps (human, real device — ADR-0002; agent does not touch the device)

1. In DevEco Studio, open `xupin/`. `syscap.json` already exists under `entry/src/main/`
   declaring `SystemCapability.AI.MindSporeLite` — no need to add it.
2. Copy `nocache_quant.ms` into `entry/src/main/resources/rawfile/model/neural_scorer.ms`
   (renamed — must match `InputMethodService.NEURAL_MODEL_RAWFILE_PATH`) and a `vocab.txt` (the
   checkpoint's tokenizer vocab, e.g. from the same HF repo used for the ONNX export) alongside it
   at `entry/src/main/resources/rawfile/model/vocab.txt` (must match
   `NEURAL_VOCAB_RAWFILE_PATH`). This mirrors `dict/words.dict.tsv`'s existing placement
   convention.
3. Build/run a throwaway test page (not part of the real IME UI — a temporary button on the
   host app's own `pages/Index.ets`, or a fresh scratch page) that:
   - Loads the model via `resourceManager.getRawFileContentSync` + `mindSporeLite.loadModelFromBuffer`
     (same pattern as `InputMethodService.loadDictionary()` for the dictionary — see
     `InputMethodService.ets`).
   - Builds `input_ids`/`attention_mask`/`position_ids` as `Int32Array` (or whatever
     `MSTensor.setData` expects for an int64-declared tensor — check the exact `MSTensor` API in
     `@ohos.ai.mindSporeLite` before assuming a dtype) at your chosen context length (§4 suggests
     8–16 tokens; try one length in that range, e.g. 12). Token IDs don't need to be meaningful
     for a pure latency/memory measurement — any valid in-vocab IDs (0–21127) work.
   - **The number that actually matters is a *batch*, not a single call**: phase 2's design
     (§4/§5a) means every keystroke fires up to ~15–20 sequential `predict()` calls (one per
     re-ranked candidate), not one. **Time a loop of ~20 back-to-back `predict()` calls at the
     chosen context length and report the total wall time for the whole batch** (plus, for
     context, the min/max/avg of the individual calls within it — per-call cost may not be
     constant, e.g. first-call JIT/cache-warming effects). The batch total against "does this
     still feel responsive per keystroke" is the actual go/no-go signal — don't extrapolate it
     from one call × 20 mentally, measure the batch directly.
   - Optional but cheap while already set up: feed one real context — e.g. tokenize "发起" per
     §1's `encode()` example (`[1355, 6629]`), pad/left-truncate to the chosen context length —
     and eyeball whether the top few predicted next-token logits correspond to plausible Chinese
     characters. This isn't a rigor check, just a fast way to catch an input-construction bug or
     obvious quantization degradation before phase 2 gets built on top of it.
   - Optionally samples process memory before/after load (HarmonyOS API for this — check
     `docs/harmonyos-guides/` for the right memory-profiling API; not looked up as part of this
     spike since it's device-only anyway).
4. Report back: (a) total wall time for a ~20-call back-to-back `predict()` batch at the chosen
   context length, plus per-call min/max/avg within it, (b) peak memory delta after loading the
   model, (c) anything that crashed/errored that the x86 smoke test didn't catch (real ARM
   execution is the actual ground truth — the x86 container run is strong evidence but not a
   guarantee of identical ARM behavior).

### What determines the phase-2 path once these numbers are in

Per the issue's own (deliberately unspecified) threshold: if per-candidate latency at the phase-2
context-window length (§4 suggests picking something in the 8–16 token range, informed by these
numbers) is fast enough for up to ~20 sequential `predict()` calls per keystroke to feel
responsive, phase 2 proceeds with `NeuralScorer` re-ranking the static-weight top-15–20 (§4's
already-settled fallback design, given KV-cache reuse is off the table per §4/§5a). If it's too
slow even at the low end of that range, that's the "spike says stop" outcome the issue asks for —
report the number and the blocker, don't force an unusable implementation.

## License status: disputed, not confirmed

The issue states this as settled ("协议已核实...不需要重新调研协议来源"), but re-checking during
this spike found the opposite of what's claimed, so this is flagged rather than silently
carried forward or silently swapped:

- **Claimed**: HuggingFace API returns `license: apache-2.0` for `uer/gpt2-chinese-cluecorpussmall`,
  and this is what distinguishes it from the `-distil` variant (whose license field is claimed to
  be empty).
- **Found** (checked via `https://huggingface.co/api/models/uer/gpt2-chinese-cluecorpussmall`,
  and the raw `README.md` YAML frontmatter and prose directly): **no `license` field exists
  anywhere** — not in `cardData`, not at the top level of the API response, not in the README's
  YAML frontmatter, not mentioned in the README prose. Checked `uer/gpt2-distil-chinese-cluecorpussmall`
  for comparison: **identical** — no license field there either. The claimed distinction between
  the two checkpoints does not currently exist; neither has an explicit license grant for the
  model weights.
- The `uer` org's training codebase, `UER-py` on GitHub, **is** Apache-2.0-licensed (confirmed
  via GitHub's license API). But that license covers the *training/inference code repository*,
  not necessarily the *specific model weights* `uer` separately published to HuggingFace — those
  have no explicit license statement of their own anywhere checked.
- Model repo's current commit: `c2c0249d8a2731f269414cc3b22dff021f8e07a3` (2023-10-17, "Update
  README.md" — the only recent history; no evidence a license field was ever present and later
  removed).

This needs a human decision before phase 2/3 can proceed on this checkpoint, along the lines
ADR-0004 already established for the dictionary data (see `docs/adr/0004-dictionary-data-source-and-license.md`
for the precedent of treating this kind of check as load-bearing rather than a formality):
either (a) find a more authoritative source that explicitly extends Apache-2.0 (or any license)
to these specific weights, (b) accept the code-repo-license-implies-weights-license inference as
a conscious call, or (c) treat the checkpoint as unlicensed and pick a different one — which, per
the issue's own rule, requires re-confirming protocol before switching for convenience. This is
independent of the technical conversion/latency findings above; nothing here blocks continuing
the technical spike, but it does block writing `THIRD_PARTY_NOTICES.md` as "confirmed Apache-2.0"
and, ultimately, blocks shipping phase 2/3 on this checkpoint without a resolution.
