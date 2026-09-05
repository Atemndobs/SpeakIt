#!/usr/bin/env bash
# Install the local Kokoro-82M speech engine for SpeakIt.
#
# Everything lands under ~/.speakit/kokoro: a private virtualenv, the ONNX
# model, and the voice pack. Nothing is installed system-wide and nothing is
# added to PATH, so removing that one directory undoes this completely.
#
#   ./scripts/kokoro-setup.sh              # fp32, best quality  (325 MB)
#   ./scripts/kokoro-setup.sh --int8       # quantized, faster   (114 MB)
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOME_DIR="${HOME}/.speakit/kokoro"
VENV="${HOME_DIR}/venv"
RELEASE="https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0"

VARIANT="kokoro-v1.0.onnx"
for arg in "$@"; do
    case "$arg" in
        --int8) VARIANT="kokoro-v1.0.int8.onnx" ;;
        --fp16) VARIANT="kokoro-v1.0.fp16.onnx" ;;
        --fp32) VARIANT="kokoro-v1.0.onnx" ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

mkdir -p "${HOME_DIR}"

# --- Python ---------------------------------------------------------------
# kokoro-onnx needs >= 3.10. macOS ships 3.9, so never use the system one.
echo "› Locating a Python 3.10+ interpreter..."
PYTHON=""
if command -v uv >/dev/null 2>&1; then
    # uv downloads a standalone interpreter if none is installed, which is the
    # difference between this script working on a clean machine and not.
    uv python install 3.12 >/dev/null 2>&1 || true
    PYTHON="$(uv python find 3.12 2>/dev/null || true)"
fi
if [ -z "${PYTHON}" ]; then
    for candidate in python3.12 python3.11 python3.10; do
        if command -v "${candidate}" >/dev/null 2>&1; then
            PYTHON="$(command -v "${candidate}")"
            break
        fi
    done
fi
if [ -z "${PYTHON}" ]; then
    echo "✗ No Python 3.10+ found. Install one:  brew install python@3.12" >&2
    echo "  (or install uv, which fetches its own: brew install uv)" >&2
    exit 1
fi
echo "  using ${PYTHON} ($("${PYTHON}" -V 2>&1))"

# --- Virtualenv -----------------------------------------------------------
if [ ! -x "${VENV}/bin/python" ]; then
    echo "› Creating virtualenv at ${VENV}"
    "${PYTHON}" -m venv "${VENV}"
fi

echo "› Installing kokoro-onnx (this pulls onnxruntime, ~100 MB)..."
"${VENV}/bin/python" -m pip install --quiet --upgrade pip
"${VENV}/bin/python" -m pip install --quiet "kokoro-onnx>=0.4.9"

# --- Model weights --------------------------------------------------------
fetch() {
    local name="$1" dest="${HOME_DIR}/$2"
    if [ -s "${dest}" ]; then
        echo "  ✓ $2 already present"
        return
    fi
    echo "› Downloading ${name}..."
    # -L follows the redirect to the release CDN; --fail turns an HTML error
    # page into a non-zero exit instead of a corrupt file that fails later.
    curl -fL --progress-bar -o "${dest}.part" "${RELEASE}/${name}"
    mv "${dest}.part" "${dest}"
}

fetch "${VARIANT}" "kokoro.onnx"
fetch "voices-v1.0.bin" "voices.bin"

# --- Daemon ---------------------------------------------------------------
# Copied rather than referenced so the engine keeps working when the app is
# installed from a release and the repository is not on disk. build-app.sh
# also bundles a copy inside SpeakIt.app, which takes precedence.
cp "${REPO_ROOT}/scripts/kokoro_daemon.py" "${HOME_DIR}/kokoro_daemon.py"

# --- Verify ---------------------------------------------------------------
# Synthesize one line end to end. A setup that installs cleanly but cannot
# actually produce audio is the failure worth catching here, not later.
echo "› Verifying (synthesizing a test phrase)..."
OUT="$(mktemp -t speakit-kokoro).wav"
if SPEAKIT_KOKORO_MODEL="${HOME_DIR}/kokoro.onnx" \
   SPEAKIT_KOKORO_VOICES="${HOME_DIR}/voices.bin" \
   "${VENV}/bin/python" "${HOME_DIR}/kokoro_daemon.py" <<EOF 2>/dev/null | grep -q '"ok": true'
{"id":1,"text":"SpeakIt is now running Kokoro locally.","voice":"af_heart","speed":1.0,"out":"${OUT}"}
{"shutdown":true}
EOF
then
    echo "  ✓ synthesis works"
    rm -f "${OUT}"
else
    echo "✗ Verification failed. Run the daemon by hand to see the error:" >&2
    echo "    SPEAKIT_KOKORO_MODEL=${HOME_DIR}/kokoro.onnx \\" >&2
    echo "    SPEAKIT_KOKORO_VOICES=${HOME_DIR}/voices.bin \\" >&2
    echo "    ${VENV}/bin/python ${HOME_DIR}/kokoro_daemon.py" >&2
    exit 1
fi

cat <<EOF

✓ Kokoro installed at ${HOME_DIR}
  model:  $(du -h "${HOME_DIR}/kokoro.onnx" | cut -f1)  (${VARIANT})
  voices: $(du -h "${HOME_DIR}/voices.bin" | cut -f1)  (54 voices, 9 languages)

Select it in the SpeakIt menu bar: Engine › Kokoro (Local).
Runs entirely offline. No network, no API key, no per-character cost.
EOF
