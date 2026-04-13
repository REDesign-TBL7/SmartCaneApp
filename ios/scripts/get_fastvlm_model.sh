#!/usr/bin/env bash
set -euo pipefail

MODEL_SIZE="${1:-0.5b}"
DEST_DIR="${2:-ios/FastVLMAssets/model}"

case "${MODEL_SIZE}" in
  0.5b) MODEL_NAME="llava-fastvithd_0.5b_stage3_llm.fp16" ;;
  1.5b) MODEL_NAME="llava-fastvithd_1.5b_stage3_llm.int8" ;;
  7b) MODEL_NAME="llava-fastvithd_7b_stage3_llm.int4" ;;
  *)
    echo "Invalid model size: ${MODEL_SIZE}. Use 0.5b, 1.5b, or 7b."
    exit 1
    ;;
esac

BASE_URL="https://ml-site.cdn-apple.com/datasets/fastvlm"
TMP_DIR=$(mktemp -d)
ZIP_PATH="${TMP_DIR}/${MODEL_NAME}.zip"
EXTRACT_DIR="${TMP_DIR}/extract"

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

mkdir -p "${EXTRACT_DIR}"
mkdir -p "${DEST_DIR}"

echo "Downloading ${MODEL_NAME}..."
curl -L "${BASE_URL}/${MODEL_NAME}.zip" -o "${ZIP_PATH}"

echo "Extracting model..."
unzip -q "${ZIP_PATH}" -d "${EXTRACT_DIR}"

if [[ -n "$(ls -A "${DEST_DIR}" 2>/dev/null || true)" ]]; then
  echo "Clearing existing destination ${DEST_DIR}"
  rm -rf "${DEST_DIR:?}"/*
fi

cp -r "${EXTRACT_DIR}/${MODEL_NAME}"/* "${DEST_DIR}/"
echo "FastVLM model ready at ${DEST_DIR}"
