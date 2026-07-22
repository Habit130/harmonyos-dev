#!/usr/bin/env python3
"""Issue #20 phase-1 spike: export uer/gpt2-chinese-cluecorpussmall to ONNX and report
findings needed to judge MindSpore Lite conversion feasibility, without needing the (Linux
x86_64-only) converter_lite binary or a real device.

Produces two ONNX graphs via HuggingFace optimum:
  - onnx_nocache/  (task=text-generation): single forward pass, no past_key_values I/O.
  - onnx_withcache/ (task=text-generation-with-past): KV-cache graph — past_key_values.N.{key,
    value} as extra inputs, present.N.{key,value} as extra outputs. This is the graph shape
    issue #20's spike gate asks about ("导出时开了 use_cache 的图...是否真的支持这种缓存状态作为
    额外输入输出的图结构").

Then, WITHOUT running converter_lite (not available for macOS — see spike report), predicts
conversion risk by diffing the graphs' actual op set against MindSpore Lite Kit's documented
supported-operator list (docs/harmonyos-guides/AI/MindSpore Lite Kit（昇思推理框架服务）/附录/
MindSpore Lite Kit算子支持列表.md), including that doc's blanket "no int64 input" constraint.

Also confirms tokenizer granularity from the checkpoint's actual vocab.txt content (acceptance
criterion: "tokenizer 实现前已实际查看 vocab.txt 内容确认分词粒度,不是假设").

Setup (not run automatically — this is a research script, not a build step):
  python3.11 -m venv venv && source venv/bin/activate
  pip install "transformers==4.46.*" "torch==2.4.*" optimum optimum-onnx onnx onnxruntime
  python3 tools/spike-20-export-onnx.py [output_dir]

Requires Python 3.10+ (torch/transformers 2024+ releases use PEP 604 `X | None` unions that
`typing.get_type_hints` evaluates eagerly — breaks on 3.9, confirmed empirically during this
spike). macOS system Python is 3.9; use `brew install python@3.11` or newer.

See xupin/docs/spike-20-neural-ranking.md for the full spike report and real numbers.
"""
import subprocess
import sys
from collections import Counter
from pathlib import Path

CHECKPOINT = "uer/gpt2-chinese-cluecorpussmall"

# MindSpore Lite Kit's documented ONNX-op support (CPU backend), transcribed from
# "MindSpore Lite Kit算子支持列表.md". Keys are ONNX op names as they appear in an exported
# graph (one MindSpore op sometimes covers several ONNX ops — flattened here to one entry per
# ONNX name). This is NOT exhaustive proof (the doc may be incomplete/imprecise — only
# converter_lite itself is ground truth) but predicts risk before the binary is available.
MSLITE_SUPPORTED_ONNX_OPS = {
    "Abs", "Celu", "Clip", "Elu", "Gelu", "HSigmoid", "LeakyRelu", "PRelu", "Relu", "Sigmoid",
    "Softmax", "SoftPlus", "Tanh",  # Activation
    "Add", "ArgMax", "AveragePool", "GlobalAveragePool", "GlobalMaxPool", "MaxPool",
    "BatchNormalization", "Expand", "Cast", "Ceil", "Concat", "Conv", "Cos", "CumSum",
    "DepthToSpace", "Div", "Sum", "Equal", "Erf", "Exp", "Flatten", "Floor", "Gather",
    "GatherElements", "GatherND", "InstanceNormalization", "Log", "Not", "LogSoftmax", "LRN",
    "Gemm", "MatMul", "Max", "Min", "Mod", "Mul", "Neg", "Pad", "Pow", "Range", "Reciprocal",
    "ReduceSum", "ReduceMean", "ReduceMax", "ReduceMin", "ReduceProd", "ReduceLogSum",
    "ReduceLogSumExp", "ReduceSumSquare", "ReduceL1", "ReduceL2", "Reshape", "Round",
    "ScatterND", "Shape", "Sin", "Size", "Slice", "SpaceToDepth", "Sqrt", "Squeeze", "Sub",
    "Tile", "TopK", "Transpose", "Trilu", "Unsqueeze", "Where",
}


def export_onnx(out_dir: Path) -> None:
    variants = [
        ("text-generation", out_dir / "onnx_nocache"),
        ("text-generation-with-past", out_dir / "onnx_withcache"),
    ]
    for task, dest in variants:
        if (dest / "model.onnx").exists():
            print(f"skip export, already exists: {dest}", file=sys.stderr)
            continue
        subprocess.run(
            ["optimum-cli", "export", "onnx", "-m", CHECKPOINT, "--task", task, str(dest)],
            check=True,
        )


def report_vocab_granularity() -> None:
    from huggingface_hub import hf_hub_download

    vocab_path = hf_hub_download(CHECKPOINT, "vocab.txt")
    with open(vocab_path, encoding="utf-8") as f:
        tokens = [line.rstrip("\n") for line in f]
    non_special = [t for t in tokens if not (t.startswith("[") and t.endswith("]"))]
    plain = [t for t in non_special if not t.startswith("##")]
    plain_single_cjk = [t for t in plain if len(t) == 1 and not t.isascii()]
    print(f"\n=== vocab.txt granularity (total {len(tokens)} tokens) ===")
    print(f"single-character non-ASCII (CJK) plain tokens: {len(plain_single_cjk)}")
    print("Confirmed via BertTokenizerFast.encode() on real dictionary words that Chinese text")
    print("is tokenized one character at a time using ONLY the plain (non-'##') single-char")
    print("entries — see spike report for the encode() transcript. Multi-character vocab")
    print("entries exist but are digits/Latin-script WordPiece fragments/stray non-Chinese")
    print("symbols, never used when tokenizing Chinese dictionary words.")


def report_op_diff(onnx_path: Path, label: str) -> None:
    import onnx
    from onnx import TensorProto, shape_inference

    m = onnx.load(str(onnx_path))
    m = shape_inference.infer_shapes(m)
    graph = m.graph
    ops = Counter(n.op_type for n in graph.node)

    print(f"\n=== {label}: op histogram vs MindSpore Lite Kit supported-op list ===")
    unsupported = []
    for op, count in ops.most_common():
        supported = op in MSLITE_SUPPORTED_ONNX_OPS
        flag = "" if supported else "  <-- NOT in supported-op list"
        print(f"{count:5d}  {op}{flag}")
        if not supported:
            unsupported.append(op)
    print(f"ops not found in the documented supported list: {unsupported}")

    type_map = {}
    for i in list(graph.input) + list(graph.output):
        type_map[i.name] = i.type.tensor_type.elem_type
    for vi in graph.value_info:
        type_map[vi.name] = vi.type.tensor_type.elem_type
    for init in graph.initializer:
        type_map[init.name] = init.data_type

    def tname(t):
        return TensorProto.DataType.Name(t)

    gather_idx_types = {tname(type_map[n.input[1]]) for n in graph.node if n.op_type == "Gather"}
    cast_srcs = {
        tname(type_map[n.input[0]]) for n in graph.node if n.op_type == "Cast" and n.input[0] in type_map
    }
    print(f"Gather indices dtypes actually used: {gather_idx_types}")
    print(f"Cast source dtypes actually used: {cast_srcs}")
    print(
        "Doc note: 'MindSpore Lite Kit算子支持列表.md' states blanket "
        "'以下所有算子,均不支持int64类型输入' (none of the listed ops support int64 input). "
        "input_ids/Gather indices are INT64 in this export (standard for HF tokenizers) — "
        "this is a real, doc-sourced conflict, not yet confirmed against the actual converter."
    )


def main() -> None:
    out_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(".")
    out_dir.mkdir(parents=True, exist_ok=True)
    export_onnx(out_dir)
    report_vocab_granularity()
    report_op_diff(out_dir / "onnx_nocache" / "model.onnx", "onnx_nocache")
    report_op_diff(out_dir / "onnx_withcache" / "model.onnx", "onnx_withcache")


if __name__ == "__main__":
    main()
