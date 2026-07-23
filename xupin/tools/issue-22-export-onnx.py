#!/usr/bin/env python3
"""Issue #22 phase A: export uer/gpt2-chinese-cluecorpussmall's no-cache (single forward pass)
ONNX graph, the only variant this issue's design needs — D1 rules out KV-cache/Native entirely
(xupin/docs/spike-20-neural-ranking.md §4/§5a already confirmed cross-keystroke KV-cache reuse
isn't reachable through ArkTS; #22 uses one batched forward pass per keystroke instead, see
xupin/docs/issue-22-shape-fix.md).

Unlike the #20 spike script (tools/spike-20-export-onnx.py), this does NOT export the
text-generation-with-past variant and does NOT do doc-vs-op-table risk prediction — that
question is already answered (§5 of the #20 spike report). This script's only job is producing
the ONNX graph that tools/issue-22-convert-ms.sh bakes to a fixed [9, 20] shape.

Setup:
  python3.11 -m venv venv && source venv/bin/activate
  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY  # see CLAUDE.md: Clash proxy breaks pip/HF
  pip install "transformers==4.46.*" "torch==2.4.*" optimum optimum-onnx onnx onnxruntime
  python3 tools/issue-22-export-onnx.py [output_dir]

Requires Python 3.10+ (see spike-20-export-onnx.py's docstring for why; same constraint here).

Prints the graph's actual input/output names, dtypes and shapes — issue #22 phase A requires
reconfirming these before assuming MindSporeNeuralModel.ets's hardcoded input names still match
(they do, as of this writing: input_ids/attention_mask/position_ids, all int64, one `logits`
output — see xupin/docs/issue-22-shape-fix.md for the confirmed values).
"""
import sys
from pathlib import Path

CHECKPOINT = "uer/gpt2-chinese-cluecorpussmall"


def export_onnx(out_dir: Path) -> Path:
    import subprocess

    dest = out_dir / "onnx_nocache"
    if (dest / "model.onnx").exists():
        print(f"skip export, already exists: {dest}", file=sys.stderr)
        return dest
    subprocess.run(
        ["optimum-cli", "export", "onnx", "-m", CHECKPOINT, "--task", "text-generation", str(dest)],
        check=True,
    )
    return dest


def report_graph_io(onnx_path: Path) -> None:
    import onnx
    from onnx import TensorProto

    m = onnx.load(str(onnx_path))
    g = m.graph
    print(f"\n=== {onnx_path}: graph inputs ===")
    for i in g.input:
        t = i.type.tensor_type
        dims = [(d.dim_value if d.dim_value else d.dim_param) for d in t.shape.dim]
        print(f"  name={i.name!r:20s} dtype={TensorProto.DataType.Name(t.elem_type)} shape={dims}")
    print(f"=== {onnx_path}: graph outputs ===")
    for o in g.output:
        t = o.type.tensor_type
        dims = [(d.dim_value if d.dim_value else d.dim_param) for d in t.shape.dim]
        print(f"  name={o.name!r:20s} dtype={TensorProto.DataType.Name(t.elem_type)} shape={dims}")


def main() -> None:
    out_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(".")
    out_dir.mkdir(parents=True, exist_ok=True)
    onnx_dir = export_onnx(out_dir)
    report_graph_io(onnx_dir / "model.onnx")


if __name__ == "__main__":
    main()
