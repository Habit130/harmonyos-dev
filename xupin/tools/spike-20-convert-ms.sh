#!/bin/bash
# Issue #20 phase-1 spike: convert the ONNX graphs from spike-20-export-onnx.py to MindSpore
# Lite's .ms format and smoke-test that they actually run, using the REAL converter_lite /
# benchmark_lite tools (2.7.0) — not doc-based prediction.
#
# converter_lite ships only for Linux x86_64 (official prebuilt download, and source build both
# require Linux — see docs/harmonyos-guides/AI/MindSpore Lite Kit（昇思推理框架服务）/
# 使用MindSpore Lite进行模型转换.md; the `mindspore-lite` PyPI package is also Linux-only and
# stale at 2.0.0 — confirmed during this spike, no macOS path exists). This script runs the real
# tool inside a Linux x86_64 Docker container so it works from macOS (including Apple Silicon,
# via QEMU emulation) without needing a separate Linux machine.
#
# On macOS without Docker Desktop, get a Linux container runtime via colima:
#   brew install colima docker qemu lima-additional-guestagents
#   colima start --arch x86_64 --cpu 4 --memory 6 --disk 20
# (lima-additional-guestagents is required — without it colima fails with "guest agent binary
# could not be found for Linux-x86_64", confirmed during this spike.)
#
# IMPORTANT: any timing numbers this script's benchmark_lite smoke test prints are NOT real
# latency data — QEMU x86-on-ARM64 emulation overhead is enormous and unrepresentative, and the
# actual target hardware is ARM, not x86. This script only answers "does it convert" and "does
# it run at all" — real latency/memory needs a real device (see xupin/docs/spike-20-neural-ranking.md §7).
#
# Usage: from xupin/, after running spike-20-export-onnx.py to produce onnx_nocache/ and
# onnx_withcache/ (e.g. in a scratch directory):
#   ./tools/spike-20-convert-ms.sh <dir containing onnx_nocache/ and onnx_withcache/> <output dir>
set -euo pipefail

ONNX_DIR="${1:?usage: $0 <onnx source dir> <output dir>}"
OUT_DIR="${2:?usage: $0 <onnx source dir> <output dir>}"
MINDSPORE_LITE_VERSION="2.7.0"
MINDSPORE_LITE_URL="https://ms-release.obs.cn-north-4.myhuaweicloud.com/${MINDSPORE_LITE_VERSION}/MindSporeLite/lite/release/linux/x86_64/mindspore-lite-${MINDSPORE_LITE_VERSION}-linux-x64.tar.gz"
CONTAINER_NAME="xupin-spike20-convert"

if ! docker version >/dev/null 2>&1; then
  echo "docker not reachable — start it first (see this script's header for the colima setup)." >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
docker volume rm "${CONTAINER_NAME}-vol" >/dev/null 2>&1 || true
docker volume create "${CONTAINER_NAME}-vol" >/dev/null
docker run -d --name "$CONTAINER_NAME" --platform linux/amd64 -v "${CONTAINER_NAME}-vol:/work" ubuntu:22.04 sleep infinity >/dev/null

# docker cp, not a bind mount: bind-mounting the host dir directly (`-v host:/work`) was observed
# to serve a stale/empty view of the mounted tree during this spike (colima's virtiofs mount —
# root cause not fully diagnosed, reproduced twice, worked around by copying files in instead).
docker cp "$ONNX_DIR/onnx_nocache" "$CONTAINER_NAME:/work/onnx_nocache"
docker cp "$ONNX_DIR/onnx_withcache" "$CONTAINER_NAME:/work/onnx_withcache"
docker exec "$CONTAINER_NAME" mkdir -p /work/out
docker exec "$CONTAINER_NAME" bash -c "apt-get update -qq && apt-get install -qq -y curl ca-certificates >/dev/null"

docker exec "$CONTAINER_NAME" bash -c "cat > /work/run_convert.sh" << EOF
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

echo "=== no-cache, fp32 ==="
\$CONVERTER --fmk=ONNX --modelFile=/work/onnx_nocache/model.onnx --outputFile=/work/out/nocache_fp32 2>&1 | tee /work/out/nocache_fp32.log

echo "=== no-cache, int8 weight-quant ==="
\$CONVERTER --fmk=ONNX --modelFile=/work/onnx_nocache/model.onnx --outputFile=/work/out/nocache_quant --configFile=/work/out/weight_quant.cfg 2>&1 | tee /work/out/nocache_quant.log

echo "=== with-cache (KV-cache), fp32, dynamic shape ==="
\$CONVERTER --fmk=ONNX --modelFile=/work/onnx_withcache/model.onnx --outputFile=/work/out/withcache_fp32 2>&1 | tee /work/out/withcache_fp32.log

echo "=== with-cache, int8 weight-quant, dynamic shape ==="
\$CONVERTER --fmk=ONNX --modelFile=/work/onnx_withcache/model.onnx --outputFile=/work/out/withcache_quant --configFile=/work/out/weight_quant.cfg 2>&1 | tee /work/out/withcache_quant.log

echo "=== with-cache, fp32, shape FIXED at conversion time (one past_sequence_length=8 example) ==="
SHAPE="input_ids:1,1"
for i in \$(seq 0 11); do
  SHAPE="\$SHAPE;past_key_values.\$i.key:1,12,8,64;past_key_values.\$i.value:1,12,8,64"
done
SHAPE="\$SHAPE;attention_mask:1,9;position_ids:1,1"
\$CONVERTER --fmk=ONNX --modelFile=/work/onnx_withcache/model.onnx --outputFile=/work/out/withcache_staticshape --inputShape="\$SHAPE" 2>&1 | tee /work/out/withcache_staticshape.log

echo "=== smoke-test: does it actually run? (benchmark_lite; NOT real latency, see script header) ==="
BENCH="\$MSDIR/tools/benchmark/benchmark"
export LD_LIBRARY_PATH="\$MSDIR/runtime/lib:\$MSDIR/runtime/third_party/glog:\$MSDIR/runtime/third_party/securec:\$MSDIR/runtime/third_party/libjpeg-turbo"

\$BENCH --modelFile=/work/out/nocache_fp32.ms --modelType=MindIR_Lite --inputShape='input_ids:1,8;attention_mask:1,8;position_ids:1,8' --loopCount=3 2>&1 | tail -5
\$BENCH --modelFile=/work/out/nocache_quant.ms --modelType=MindIR_Lite --inputShape='input_ids:1,8;attention_mask:1,8;position_ids:1,8' --loopCount=3 2>&1 | tail -5
\$BENCH --modelFile=/work/out/withcache_staticshape.ms --modelType=MindIR_Lite --loopCount=2 2>&1 | tail -5

ls -la /work/out/
EOF
docker exec "$CONTAINER_NAME" bash /work/run_convert.sh

for f in nocache_fp32.ms nocache_quant.ms withcache_fp32.ms withcache_quant.ms withcache_staticshape.ms \
         nocache_fp32.log nocache_quant.log withcache_fp32.log withcache_quant.log withcache_staticshape.log; do
  docker cp "$CONTAINER_NAME:/work/out/$f" "$OUT_DIR/$f" 2>/dev/null || true
done
chmod 644 "$OUT_DIR"/*.ms 2>/dev/null || true

echo "Done. Output in $OUT_DIR"
echo "Cleaning up the container (the volume/colima VM are left running — stop with 'colima stop' when done with all conversion work)."
docker rm -f "$CONTAINER_NAME" >/dev/null
docker volume rm "${CONTAINER_NAME}-vol" >/dev/null
