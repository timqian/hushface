#!/usr/bin/env bash
# Developer install: run hushface straight from this checkout, using the node,
# pi and llama.cpp already on the machine (no bundled runtime, no 73 MB payload).
#
#   tools/install-from-source.sh            # link ~/.local/bin/hushface
#   tools/install-from-source.sh /usr/local/bin
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target="${1:-$HOME/.local/bin}"
mkdir -p "$target"
ln -sf "$here/bin/hushface" "$target/hushface"
chmod +x "$here/bin/hushface"
echo "linked $target/hushface → $here/bin/hushface"
case ":$PATH:" in
  *":$target:"*) ;;
  *) echo "add to your shell profile:  export PATH=\"$target:\$PATH\"" ;;
esac
echo
echo "next:  hushface          # installs llama.cpp/pi if missing, then downloads the model"
echo "       tests/run.sh      # 83 offline tests"
