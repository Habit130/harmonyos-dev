#!/bin/bash
# Issue #22 phase A: convert the no-cache ONNX graph (tools/issue-22-export-onnx.py) to a
# MindSpore Lite .ms file with batch AND sequence length baked to a FIXED shape at conversion
# time (D1/D3/D4: batch = candidate-bar display limit = 9, seq = context window 12 + max
# candidate tokens 8 = 20) — this is the actual fix for the bug issue #22 exists to close: the
# #20 implementation shipped a .ms with a dynamic sequence axis, which ArkTS's MindSpore Lite
# binding cannot resize (no OH_AI_ModelResize equivalent — see
# xupin/docs/spike-20-neural-ranking.md §4), so predict() never produced real output on-device.
#
# Whenever N (the batch/display-limit constant) or the context-window/candidate-token split
# changes, this script must be re-run and the resulting .ms re-bundled — these are model-asset
# parameters now, not ArkTS constants you can just recompile (see
# xupin/docs/issue-22-shape-fix.md and CandidateGenerator.ets/NeuralScorer.ets's
# DEFAULT_DISPLAY_LIMIT/DEFAULT_CONTEXT_WINDOW_CHARS/MAX_CANDIDATE_TOKENS doc comments).
#
# converter_lite ships only for Linux x86_64 — see tools/spike-20-convert-ms.sh's header for the
# full colima/Docker setup rationale (unchanged here). Quick setup recap:
#   brew install colima docker qemu lima-additional-guestagents
#   colima start --arch x86_64 --cpu 4 --memory 6 --disk 20
#
# Usage: from xupin/, after running issue-22-export-onnx.py to produce onnx_nocache/:
#   ./tools/issue-22-convert-ms.sh <dir containing onnx_nocache/> <output dir> [batch] [seq]
# batch/seq default to 9/20 (D3/D4's confirmed values) if omitted.
set -euo pipefail

ONNX_DIR="${1:?usage: $0 <onnx source dir> <output dir> [batch=9] [seq=20]}"
OUT_DIR="${2:?usage: $0 <onnx source dir> <output dir> [batch=9] [seq=20]}"
BATCH="${3:-9}"
SEQ="${4:-20}"
MINDSPORE_LITE_VERSION="2.7.0"
MINDSPORE_LITE_URL="https://ms-release.obs.cn-north-4.myhuaweicloud.com/${MINDSPORE_LITE_VERSION}/MindSporeLite/lite/release/linux/x86_64/mindspore-lite-${MINDSPORE_LITE_VERSION}-linux-x64.tar.gz"
CONTAINER_NAME="xupin-issue22-convert"

if ! docker version >/dev/null 2>&1; then
  echo "docker not reachable — start colima first (see this script's header)." >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
docker volume rm "${CONTAINER_NAME}-vol" >/dev/null 2>&1 || true
docker volume create "${CONTAINER_NAME}-vol" >/dev/null
docker run -d --name "$CONTAINER_NAME" --platform linux/amd64 -v "${CONTAINER_NAME}-vol:/work" ubuntu:22.04 sleep infinity >/dev/null

# docker cp, not a bind mount — see tools/spike-20-convert-ms.sh's header for why (colima
# virtiofs served a stale/empty view of a bind-mounted host dir during the #20 spike).
docker cp "$ONNX_DIR/onnx_nocache" "$CONTAINER_NAME:/work/onnx_nocache"
docker exec "$CONTAINER_NAME" mkdir -p /work/out
docker exec "$CONTAINER_NAME" bash -c "apt-get update -qq && apt-get install -qq -y curl ca-certificates >/dev/null"

# docker exec -i (stdin attached) is required for this heredoc-to-cat pattern to actually land
# the script file inside the container — without -i the container-side `cat > file` sees no
# stdin and silently writes an empty file (confirmed the hard way during this issue's work; the
# #20 spike script has the same bug pattern but the failure wasn't hit/noticed there).
docker exec -i "$CONTAINER_NAME" bash -c "cat > /work/run_convert.sh" << EOF
#!/bin/bash
set -ex
cd /work
curl -L -o mindspore-lite.tar.gz "$MINDSPORE_LITE_URL"
tar xzf mindspore-lite.tar.gz
MSDIR=/work/mindspore-lite-${MINDSPORE_LITE_VERSION}-linux-x64
export LD_LIBRARY_PATH="\$MSDIR/tools/converter/lib:\$MSDIR/runtime/lib:\${LD_LIBRARY_PATH:-}"
CONVERTER="\$MSDIR/tools/converter/converter/converter_lite"

cat > /work/out/weight_quant.cfg << 'CFG'
[common_quant_param]
quant_type=WEIGHT_QUANT
bit_num=8
min_quant_weight_size=0
min_quant_weight_channel=16

[weight_quant_param]
per_channel=true
CFG

SHAPE="input_ids:${BATCH},${SEQ};attention_mask:${BATCH},${SEQ};position_ids:${BATCH},${SEQ};"

echo "=== fp32, shape baked to \$SHAPE at CONVERSION time ==="
\$CONVERTER --fmk=ONNX --modelFile=/work/onnx_nocache/model.onnx --outputFile=/work/out/static_${BATCH}_${SEQ}_fp32 \
  --inputShape="\$SHAPE" 2>&1 | tee /work/out/static_${BATCH}_${SEQ}_fp32.log

echo "=== int8 weight-quant, shape baked to \$SHAPE at CONVERSION time ==="
\$CONVERTER --fmk=ONNX --modelFile=/work/onnx_nocache/model.onnx --outputFile=/work/out/static_${BATCH}_${SEQ}_quant \
  --inputShape="\$SHAPE" --configFile=/work/out/weight_quant.cfg 2>&1 | tee /work/out/static_${BATCH}_${SEQ}_quant.log

echo "=== benchmark_lite smoke test — NO --inputShape passed here. This is the load-bearing check: ==="
echo "=== if the shape didn't really bake at conversion time, this run fails/needs --inputShape.  ==="
BENCH="\$MSDIR/tools/benchmark/benchmark"
export LD_LIBRARY_PATH="\$MSDIR/runtime/lib:\$MSDIR/runtime/third_party/glog:\$MSDIR/runtime/third_party/securec:\$MSDIR/runtime/third_party/libjpeg-turbo"
\$BENCH --modelFile=/work/out/static_${BATCH}_${SEQ}_fp32.ms --modelType=MindIR_Lite --loopCount=3
\$BENCH --modelFile=/work/out/static_${BATCH}_${SEQ}_quant.ms --modelType=MindIR_Lite --loopCount=3

ls -la /work/out/
EOF
docker exec "$CONTAINER_NAME" bash /work/run_convert.sh

for f in "static_${BATCH}_${SEQ}_fp32.ms" "static_${BATCH}_${SEQ}_quant.ms" \
         "static_${BATCH}_${SEQ}_fp32.log" "static_${BATCH}_${SEQ}_quant.log" weight_quant.cfg; do
  docker cp "$CONTAINER_NAME:/work/out/$f" "$OUT_DIR/$f" 2>/dev/null || true
done
chmod 644 "$OUT_DIR"/*.ms 2>/dev/null || true

echo "Done. Output in $OUT_DIR"
echo "Rename static_${BATCH}_${SEQ}_quant.ms to neural_scorer.ms and drop it (plus vocab.txt) at"
echo "entry/src/main/resources/rawfile/model/ per InputMethodService.ets's NEURAL_MODEL_RAWFILE_PATH."
echo "Cleaning up the container (the volume/colima VM are left running)."
docker rm -f "$CONTAINER_NAME" >/dev/null
docker volume rm "${CONTAINER_NAME}-vol" >/dev/null
