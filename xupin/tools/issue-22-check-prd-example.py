"""Issue #22: before declaring the batched-scoring redesign done, verify the PRD's own
motivating example actually flips under the REAL model's real logits — not just under the
FakeNeuralModel-fed canned logits NeuralScorer.test.ets uses. Those unit tests prove the blend
formula is wired correctly (issue #20's own acceptance criteria deliberately don't require real-
checkpoint linguistic assertions in unit tests — "单测验证机制,不验证语言学效果"); this script is
the offline (no device needed) check that the mechanism actually produces the desired real-world
answer, using the real HF checkpoint's real logits.

Mirrors exactly what ArkTS's meanTeacherForcedLogProb does: teacher-forced log-prob of each
candidate token at logits[contextLen + j - 1], averaged (not summed), then blended as
score = ln(weight + 1) + coefficient * meanLogProb.

Two things checked:
1. The PRD example itself (issue #20's Context section): 攻击=500,441 vs 供给=238,495 static
   weight. Context "发起" alone should keep 攻击 winning (matches the "发起→攻击" bigram evidence
   the PRD itself cites — that's a real, common collocation, not a bug to fix). Context "物资"
   alone, or the full "发起物资" (both committed, the PRD's literal "已上屏「发起」「物资」后打
   gongji" scenario), should flip it so 供给 wins despite the lower static weight.
2. Whether NeuralScorer.ets's design (prepend [CLS] ONLY when context is empty, feed non-empty
   context raw — issue #22 D5) holds up against the alternative of always prefixing [CLS]. This
   was flagged during implementation as an open question worth resolving with data rather than
   left as an unstated assumption.

Setup (same venv as issue-22-export-onnx.py):
  python3.11 -m venv venv && source venv/bin/activate
  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
  pip install "transformers==4.46.*" "torch==2.4.*"
  python3 tools/issue-22-check-prd-example.py

See xupin/docs/issue-22-shape-fix.md §7 for the results and conclusions from this script's
output. Uses the fp32 PyTorch model directly, not the converted/quantized .ms — weight-only
quantization doesn't change inference dtype (spike-20-neural-ranking.md §5a), so this is strong
evidence for the design's soundness, though not a substitute for on-device verification of the
actual deployed artifact.
"""
import math

import torch
from transformers import BertTokenizer, GPT2LMHeadModel

CHECKPOINT = "uer/gpt2-chinese-cluecorpussmall"
COEFFICIENT = 2.0  # NeuralScorer.DEFAULT_NEURAL_COEFFICIENT

tokenizer = BertTokenizer.from_pretrained(CHECKPOINT)
model = GPT2LMHeadModel.from_pretrained(CHECKPOINT)
model.eval()
CLS = tokenizer.convert_tokens_to_ids("[CLS]")

CANDIDATES = [("攻击", 500441), ("供给", 238495)]


def ids(text):
    return tokenizer.convert_tokens_to_ids(list(text))


def mean_teacher_forced_log_prob(full_ids, context_len, candidate_ids):
    with torch.no_grad():
        logits = model(input_ids=torch.tensor([full_ids])).logits[0]  # [seq, vocab]
    log_probs = torch.log_softmax(logits, dim=-1)
    total = 0.0
    scored = 0
    for j, tok in enumerate(candidate_ids):
        position = context_len + j - 1
        if position < 0:
            continue
        total += float(log_probs[position, tok])
        scored += 1
    return total / scored if scored else None


def blended(weight, mean_log_prob):
    return math.log(weight + 1) + COEFFICIENT * mean_log_prob


def run(label, context_ids):
    print(f"\n=== {label}: context_ids={context_ids} ===")
    scores = {}
    for word, weight in CANDIDATES:
        cand_ids = ids(word)
        full = context_ids + cand_ids
        mlp = mean_teacher_forced_log_prob(full, len(context_ids), cand_ids)
        score = blended(weight, mlp)
        scores[word] = score
        print(f"  {word} (weight={weight}): meanLogProb={mlp:.4f} blended={score:.4f}")
    winner = max(scores, key=scores.get)
    print(f"  winner: {winner}  (gap 供给-攻击 = {scores['供给'] - scores['攻击']:.4f})")
    return scores


print("### 1. PRD example across context variants (design: no-CLS prefix for non-empty context) ###")
run("发起 alone (expect 攻击 to keep winning — common collocation)", ids("发起"))
run("物资 alone (expect 供给 to flip ahead)", ids("物资"))
run("发起物资 (both committed — the PRD's literal scenario)", ids("发起物资"))

print("\n### 2. [CLS]-prefix-for-nonempty-context contrast, at the PRD's literal scenario ###")
run("no-CLS (current design)", ids("发起物资"))
run("CLS-always (contrast)", [CLS] + ids("发起物资"))
