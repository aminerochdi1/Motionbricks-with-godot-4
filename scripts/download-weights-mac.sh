#!/usr/bin/env bash
# Downloads the exact MotionBricks G1 model weights (about 733 MB) and verifies every file.
# Source: Hugging Face LocalAI-io/MotionBricks-G1-GGML at commit cc2a47603dbc203a4f18f35dd06ed3611833f506
# Each file is checked against the repo's MANIFEST.json (size + SHA-256). Re-running skips verified files.
# Run from the repo root (after build-motionbricks-mac.sh):  bash scripts/download-weights-mac.sh
set -euo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)/third_party/motion-bricks.cpp"
OUT="$SRC/generated"
REPO="LocalAI-io/MotionBricks-G1-GGML"
REV="cc2a47603dbc203a4f18f35dd06ed3611833f506"
MANIFEST="$SRC/scripts/hf/MotionBricks-G1-GGML/MANIFEST.json"
BASE="${HF_BASE:-https://huggingface.co/$REPO/resolve/$REV}"

cd "$SRC"

# 1) The repo's own downloader, using the macOS system certificate bundle
#    (Homebrew's Python often lacks one, which causes CERTIFICATE_VERIFY_FAILED).
if SSL_CERT_FILE="${SSL_CERT_FILE:-/etc/ssl/cert.pem}" python3 -I scripts/download_gguf_weights.py --output "$OUT"; then
  :
else
  # 2) Fallback: curl uses the system trust store. Same pinned commit, same checksums.
  echo
  echo "Python download failed; falling back to curl..."
  python3 -I - "$MANIFEST" "$OUT" "$BASE" <<'PY'
import hashlib, json, os, subprocess, sys, urllib.parse
from pathlib import Path

manifest, out, base = sys.argv[1], Path(sys.argv[2]), sys.argv[3]

def sha(p):
    h = hashlib.sha256()
    with p.open("rb") as f:
        for b in iter(lambda: f.read(8 << 20), b""):
            h.update(b)
    return h.hexdigest()

def ok(p, e):
    return p.is_file() and p.stat().st_size == e["bytes"] and sha(p) == e["sha256"]

for e in json.load(open(manifest))["files"]:
    rel = e["path"]
    if Path(rel).is_absolute() or ".." in Path(rel).parts:
        sys.exit("unsafe path in manifest: " + rel)
    dest = out / rel
    if ok(dest, e):
        print("verified", dest)
        continue
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_name(dest.name + ".download")
    print("downloading", rel)
    subprocess.run(["curl", "-fL", "--retry", "3", "-o", str(tmp),
                    base + "/" + urllib.parse.quote(rel)], check=True)
    os.replace(tmp, dest)
    if not ok(dest, e):
        sys.exit("verification failed: " + str(dest))
print("MotionBricks GGUF and style bundles are present and verified")
PY
fi

echo
echo "Weights are in: $OUT"
ls -lh "$OUT/g1-f32" | sed 's/^/  /'
echo "Note: the weights stay under the NVIDIA Open Model License (not Apache-2.0). Read it before shipping a game with them."
