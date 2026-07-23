"""Issue #22 phase A step 1: empirically confirm whether [CLS] is a usable sentence-start
anchor for uer/gpt2-chinese-cluecorpussmall — NOT trusting GPT2Config.bos_token_id (a BERT-vocab
UER checkpoint's GPT2Config almost certainly carries GPT2's stock English defaults, which would
be out of range for a 21128-entry vocab and prove nothing about training-time behavior).

Method: feed input_ids=[[101]] (just [CLS], not the tokenizer's default [CLS]...[SEP] wrap) and
look at what the model predicts as the FIRST character of a sentence. If [CLS] is genuinely the
training-time start-of-sequence marker, the top predictions at that position should look like
plausible sentence-initial Chinese characters (common opening chars: 我/在/这/中/据/近日 etc.),
not [PAD]/[unused*]/punctuation noise. Contrast against feeding a random ordinary character
alone, to see the difference between "start of sequence" behavior and "just continue after any
single token" behavior.

Setup (same venv as issue-22-export-onnx.py):
  python3.11 -m venv venv && source venv/bin/activate
  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
  pip install "transformers==4.46.*" "torch==2.4.*"
  python3 tools/issue-22-check-cls.py

See xupin/docs/issue-22-shape-fix.md §1 for the results and conclusion from this script's output.
"""
from transformers import BertTokenizer, GPT2LMHeadModel, GPT2Config
import torch

CHECKPOINT = "uer/gpt2-chinese-cluecorpussmall"

tokenizer = BertTokenizer.from_pretrained(CHECKPOINT)
model = GPT2LMHeadModel.from_pretrained(CHECKPOINT)
model.eval()

config = GPT2Config.from_pretrained(CHECKPOINT)
print("=== GPT2Config (NOT trusted as evidence, printed for the record only) ===")
print("bos_token_id:", config.bos_token_id, "eos_token_id:", config.eos_token_id)
print("vocab_size:", config.vocab_size)

cls_id = tokenizer.convert_tokens_to_ids("[CLS]")
sep_id = tokenizer.convert_tokens_to_ids("[SEP]")
pad_id = tokenizer.convert_tokens_to_ids("[PAD]")
print("\n[CLS] id:", cls_id, " [SEP] id:", sep_id, " [PAD] id:", pad_id)
assert cls_id == 101, f"expected [CLS]=101 (standard BERT vocab layout), got {cls_id}"

def top_k_next(input_ids, k=20):
    with torch.no_grad():
        out = model(input_ids=torch.tensor([input_ids]))
    logits = out.logits[0, -1]  # last position's next-token distribution
    probs = torch.softmax(logits, dim=-1)
    top = torch.topk(probs, k)
    return [(tokenizer.convert_ids_to_tokens(int(i)), float(p)) for p, i in zip(top.values, top.indices)]

print("\n=== Case A: input_ids=[[CLS]] only (the D5 candidate: single-token start anchor) ===")
for tok, p in top_k_next([cls_id]):
    print(f"  {tok!r:10s} {p:.4f}")

print("\n=== Case B (contrast): input_ids=[[SEP]] only — a token that should NOT behave like a start anchor ===")
for tok, p in top_k_next([sep_id]):
    print(f"  {tok!r:10s} {p:.4f}")

print("\n=== Case C (contrast): input_ids=[<random ordinary char>] e.g. '的' — mid-stream single token, not a designed anchor ===")
de_id = tokenizer.convert_tokens_to_ids("的")
print("'的' id:", de_id)
for tok, p in top_k_next([de_id]):
    print(f"  {tok!r:10s} {p:.4f}")

print("\n=== Case D (contrast): input_ids=[[PAD]] only ===")
for tok, p in top_k_next([pad_id]):
    print(f"  {tok!r:10s} {p:.4f}")

print("\n=== Case E: tokenizer's own default encode() of an empty-ish/short string, to see how it wraps ===")
enc = tokenizer("发起", return_tensors=None)
print("encode('发起') with special tokens:", enc["input_ids"], [tokenizer.convert_ids_to_tokens(i) for i in enc["input_ids"]])
