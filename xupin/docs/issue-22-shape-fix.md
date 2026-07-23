# Issue #22 phase A: static-shape model resource, confirmed

Status: **gate passed — phase B/C/D unblocked.** This document is the phase-A deliverable
issue #22 requires before any ArkTS changes: confirms the `[CLS]` start-anchor premise (D5),
reconfirms the ONNX graph's actual input contract, and proves — via the real `converter_lite`/
`benchmark_lite` binaries, not documentation analysis — that a `.ms` file with batch and
sequence length baked to a fixed shape at *conversion* time runs with **zero runtime resize**,
which is the exact ArkTS-equivalence judgment this issue's root-cause fix depends on.

Builds on `xupin/docs/spike-20-neural-ranking.md` (issue #20's phase-1 spike) — re-reads that
document's §1/§2/§3 conclusions (tokenizer granularity, architecture, ONNX export mechanics)
rather than re-deriving them; only the two things #22 actually changes get re-verified here:
whether `[CLS]` really is a usable start anchor, and whether a *baked*-shape `.ms` avoids the
runtime-resize dependency ArkTS doesn't support.

## 1. `[CLS]` as a start-of-sequence anchor (D5's premise) — confirmed empirically

D5 assumes `[CLS]` is usable as a single-token "start of sequence" anchor when there's no
committed context yet. `GPT2Config.bos_token_id`/`eos_token_id` are **not** evidence for this —
checked and, as expected for a BERT-vocab checkpoint carrying stock `GPT2Config` defaults, they
read `50256` (GPT2's English tokenizer's id), which is out of range for this checkpoint's
21,128-entry vocab and reflects nothing about training-time behavior. Verified empirically
instead, mirroring exactly how phase B will use it — feeding `input_ids=[[101]]` alone (`[CLS]`
by itself, not the tokenizer's default `[CLS]...[SEP]` wrap) and inspecting what the model
predicts as the *first* character of a sequence:

```
input_ids=[[CLS]] (101) → top predictions:
  如 .039  很 .030  这 .029  有 .020  书 .018  不 .017  为 .016  我 .016  一 .015  你 .015
  在 .014  还 .011  中 .010  《 .008  大 .008  看 .007  好 .007  怎 .007  小 .007
```

This is a natural, plausible sentence-initial distribution — common opening characters/words for
Chinese text (我/这/在/中/一 etc.), no degenerate tokens. Contrast with three controls:

- `input_ids=[[SEP]]` (102) alone: top predictions are `，`(.069) `。`(.039) `的`(.034)
  `[UNK]`(.026) `[SEP]`(.023) — punctuation/continuation-particle-heavy, i.e. "end/boundary of a
  clause" behavior, not a start anchor.
- `input_ids=[[PAD]]` (0) alone: top predictions are stray Latin WordPiece fragments and ASCII
  punctuation (`)` `-` `）` `.` `/` `##t` `##s` `##a` ...) — clear noise, `[PAD]` was never a
  meaningful training-time position.
- `input_ids=[的]` (an ordinary mid-stream character) alone: top predictions are
  `，`(.031) `人`(.017) `。`(.017) `一`(.015) `时`(.013) — plausible *continuation* after "的",
  a visibly different distribution shape from the `[CLS]` case (no start-of-sentence flavor).

Additionally, the tokenizer's own default `encode()` wraps every input in `[CLS] ... [SEP]`
(`encode('发起')` → `[101, 1355, 6629, 102]` → `['[CLS]', '发', '起', '[SEP]']`), the standard
BERT-family preprocessing convention this UER checkpoint's training pipeline follows.

**Conclusion: `[CLS]` is a genuine, trained start-of-sequence anchor for this checkpoint** — the
`[CLS]`-alone distribution looks like real sentence beginnings and is clearly distinguishable
from both a boundary/continuation token (`[SEP]`) and a never-meaningfully-trained token
(`[PAD]`). D5's premise holds; no change of anchor strategy needed.

Reproduction: `xupin/tools/issue-22-check-cls.py`.

Special-token ids in the real vocab, confirmed via `BertTokenizer.from_pretrained(...)` (not
assumed): `[PAD]=0`, `[UNK]=100`, `[CLS]=101`, `[SEP]=102`, `[MASK]=103`.

## 2. ONNX graph input/output contract — reconfirmed

`MindSporeNeuralModel.ets` hardcodes three input names and throws on anything else. Re-exported
the no-cache (`text-generation` task) graph and read the graph's actual `input`/`output` list
directly (not assumed carried over from the #20 spike):

```
inputs:
  input_ids       INT64  [batch_size, sequence_length]
  attention_mask  INT64  [batch_size, sequence_length]
  position_ids    INT64  [batch_size, sequence_length]
outputs:
  logits          FLOAT  [batch_size, sequence_length, 21128]
```

Unchanged from the #20 spike's finding — three inputs, exact same names, all `int64`, one
`logits` output. `MindSporeNeuralModel.ets`'s existing input-name dispatch (`valuesFor()`)
doesn't need new cases.

Reproduction: `xupin/tools/issue-22-export-onnx.py`.

## 3. `converter_lite` with baked `[9, 20]` shape — converts and runs resize-free

Batch = 9 (D3: batch size == `DEFAULT_DISPLAY_LIMIT`, the candidate-bar display cap). Sequence
length = 20 (D4: 12-token context window + 8-token max candidate length). Converted with both
dimensions baked in **at conversion time** via `--inputShape`, not left dynamic:

```
converter_lite --fmk=ONNX --modelFile=onnx_nocache/model.onnx --outputFile=static_9_20_fp32 \
  --inputShape="input_ids:9,20;attention_mask:9,20;position_ids:9,20;"
```

Both variants converted successfully (real `converter_lite` 2.7.0, Linux x86_64 via colima —
same Docker-in-QEMU setup as the #20 spike, see `tools/issue-22-convert-ms.sh`'s header):

| Variant | Result | `.ms` size |
| --- | --- | --- |
| fp32 | `CONVERT RESULT SUCCESS:0` | 473,323,632 B (~451.3 MB) |
| int8 weight-quant | `CONVERT RESULT SUCCESS:0` | 122,337,872 B (~116.7 MB) |

**The load-bearing check**: `benchmark_lite` invoked with **no `--inputShape` argument at all**
— this is what makes the check equivalent to what ArkTS's `mindSporeLite.Model.predict()` can
actually do, since ArkTS has no resize entry point (`spike-20-neural-ranking.md` §4). Note this
is a *stricter* test than the #20 spike ran on the (dynamic-shape) no-cache `.ms`: that spike
passed `--inputShape=...` to `benchmark_lite` at *run* time, which is the exact runtime-resize
pattern ArkTS can't do — so that earlier "no-cache ran fine" result did **not** actually prove
what #22 needs proven. This run doesn't repeat that mistake:

```
$ benchmark --modelFile=static_9_20_fp32.ms  --modelType=MindIR_Lite --loopCount=3
Run Benchmark static_9_20_fp32.ms Success.

$ benchmark --modelFile=static_9_20_quant.ms --modelType=MindIR_Lite --loopCount=3
Run Benchmark static_9_20_quant.ms Success.
```

Both succeed with zero `--inputShape` at benchmark time. **This directly answers #22's phase-A
acceptance criterion**: the shape is genuinely baked at conversion time, not merely "still
resizable but happens to also accept a resize call" — confirming the ArkTS-side redesign (batch
predict, no resize anywhere in the call path) is unblocked.

(The run timings themselves — 30+ seconds per loop — are QEMU x86-on-ARM64 emulation overhead,
same caveat as the #20 spike: not real latency data, not used for any latency conclusion here.
Real on-device latency is still phase D, human-only, ADR-0002.)

Reproduction: `xupin/tools/issue-22-convert-ms.sh <onnx dir> <out dir> [batch=9] [seq=20]`.

## 4. Where the converted `.ms` files are

Not committed to git (same reasons as the #20 spike's artifacts: derived/regenerable,
multi-hundred-MB binaries, and the checkpoint's license is still unresolved per
`spike-20-neural-ranking.md`'s "License status" section — #22 fixes the shape bug, it does not
resolve the license question). Sitting at `~/Documents/XupinModelArtifacts/issue-22/` on this
machine (durable, not a job tmp dir that gets swept):

| File | Size | Shape | Runs resize-free in `benchmark_lite`? |
| --- | --- | --- | --- |
| `static_9_20_fp32.ms` | ~451.3 MB | `[9,20]` baked at conversion | Yes |
| `static_9_20_quant.ms` | ~116.7 MB | `[9,20]` baked at conversion, int8 weight-quant | Yes |

**For phase D device testing, use `static_9_20_quant.ms`** (smallest, matches phase B/C's actual
design) — rename to `neural_scorer.ms` and place at
`entry/src/main/resources/rawfile/model/neural_scorer.ms` per
`InputMethodService.NEURAL_MODEL_RAWFILE_PATH`, alongside a `vocab.txt` at
`entry/src/main/resources/rawfile/model/vocab.txt`
(`NEURAL_VOCAB_RAWFILE_PATH`) — same placement convention as `dict/words.dict.tsv`.

**This supersedes `spike-20-neural-ranking.md` §7's handoff**, which points at
`nocache_quant.ms` — the *dynamic-shape* file that predates this issue's fix and would
reproduce the exact `predict()`-never-succeeds bug #22 exists to close if used on-device now.
Do not use any `.ms` file from the #20 spike for device testing going forward.

## 5. N / context-window are model-resource parameters, not ArkTS constants

Per #22's own explicit deviation note: `DEFAULT_DISPLAY_LIMIT` (batch size, 9) and
`DEFAULT_CONTEXT_WINDOW_CHARS` (12, paired with `MAX_CANDIDATE_TOKENS` = 8 to make the 20-token
sequence length) are baked into the converted `.ms` file's tensor shapes. **Changing any of
these three numbers in ArkTS source requires re-running `tools/issue-22-export-onnx.py` +
`tools/issue-22-convert-ms.sh` and re-bundling the resulting `.ms`** — it is not a
recompile-only change. See `CandidateGenerator.ets` (`DEFAULT_DISPLAY_LIMIT`) and
`NeuralScorer.ets` (`DEFAULT_CONTEXT_WINDOW_CHARS`, `DEFAULT_MAX_CANDIDATE_TOKENS`,
`DEFAULT_BATCH_SIZE`) for where these live in code.

## 6. What phase A does *not* answer

Real-device latency and memory for the batched `[9,20]` forward pass — still phase D, human-only
(ADR-0002). Phase A only establishes that the resize-free execution path is real; how fast it is
on actual ARM hardware is unmeasured until a human runs it.

## 7. Offline sanity check: does the redesign's own PRD example actually flip, on the real model?

Not a phase-A acceptance criterion, but worth doing before calling phase B/C done: the unit tests
in `NeuralScorer.test.ets` feed `FakeNeuralModel` hand-picked "confident" logits to prove the
blend formula (`ln(weight+1) + coefficient·meanLogProb`) mechanically reorders candidates when
told to — by design, per issue #20's own acceptance criteria, they don't (and shouldn't) prove
the *real* checkpoint actually produces that confidence for this PRD example
("单测验证机制,不验证语言学效果"). Ran the exact same math (teacher-forced log-prob at
`logits[contextLen+j-1]`, averaged, blended with `coefficient=2`) against the real fp32 model
instead — reproducible via `xupin/tools/issue-22-check-prd-example.py`:

| Context | 攻击 (w=500,441) blended | 供给 (w=238,495) blended | Winner |
| --- | --- | --- | --- |
| `发起` alone | 6.97 | -0.38 | **攻击** (expected — "发起→攻击" is a real, common collocation; not a case #22 needs to flip) |
| `物资` alone | 3.20 | 8.16 | **供给** (flips despite the lower static weight) |
| `发起物资` (both committed — the PRD's literal "已上屏「发起」「物资」" scenario) | 6.21 | 7.49 | **供给** |

The PRD's actual scenario (both `发起` and `物资` committed before typing `gongji`) flips
correctly with the current `coefficient=2` default — this isn't just a mechanism test passing,
it's real evidence the calibration is in a reasonable range for this example. (`发起` alone
correctly does *not* flip — that's consistent with the closed `#6`'s bigram-corpus evidence that
"发起→攻击" is a genuine, frequent collocation, not a gap this feature is meant to correct.)

**Also resolves an open design question from implementation**: D5 only prepends `[CLS]` when
committed context is empty; non-empty context is fed raw (position 0 = the first real character,
not `[CLS]`). Tested the alternative (always prefixing `[CLS]`, even with real context) at the
PRD's literal `发起物资` scenario — it **reverses the correct result** (供给-攻击 gap flips from
+1.28 to -0.33, i.e. 攻击 wins again, wrong). **D5 as specified — `[CLS]` only for empty
context — is empirically the right call for this checkpoint, not an arbitrary choice.** No change
needed; this closes the question rather than leaving it as an unstated assumption.

Caveat: this checks the fp32 PyTorch model's logits directly, not the converted/quantized `.ms`
running through MindSpore Lite Kit. Weight-only quantization doesn't change inference dtype
(`spike-20-neural-ranking.md` §5a — compute stays fp32), so no material difference is expected,
but this is offline evidence for the *design*, not a substitute for phase D's on-device check
against the actual deployed artifact.
