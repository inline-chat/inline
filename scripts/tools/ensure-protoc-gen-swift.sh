#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_DIR="${ROOT_DIR}/.tools"
SWIFTPB_VERSION="1.28.2"
SWIFTPB_DIR="${TOOLS_DIR}/swift-protobuf-${SWIFTPB_VERSION}"
BIN_PATH="${TOOLS_DIR}/protoc-gen-swift"
BIN_VERSION_PATH="${BIN_PATH}.version"
BUILD_BIN="${SWIFTPB_DIR}/.build/release/protoc-gen-swift"

if [[ -x "${BIN_PATH}" && -f "${BIN_VERSION_PATH}" && "$(cat "${BIN_VERSION_PATH}")" == "${SWIFTPB_VERSION}" ]]; then
  exit 0
fi

if ! command -v swift >/dev/null 2>&1; then
  echo "error: swift toolchain not found (needed to build protoc-gen-swift ${SWIFTPB_VERSION})." >&2
  exit 1
fi

mkdir -p "${TOOLS_DIR}"

if [[ ! -d "${SWIFTPB_DIR}" ]]; then
  git clone --depth 1 --branch "${SWIFTPB_VERSION}" https://github.com/apple/swift-protobuf.git "${SWIFTPB_DIR}"
fi

(
  cd "${SWIFTPB_DIR}"
  swift build -c release --product protoc-gen-swift
)

if [[ ! -x "${BUILD_BIN}" ]]; then
  echo "error: protoc-gen-swift build output missing at ${BUILD_BIN}." >&2
  exit 1
fi

cp "${BUILD_BIN}" "${BIN_PATH}"
chmod +x "${BIN_PATH}"
echo "${SWIFTPB_VERSION}" > "${BIN_VERSION_PATH}"
