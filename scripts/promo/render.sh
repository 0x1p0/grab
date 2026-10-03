#!/bin/bash
# Renders promo/Grab-promo.mp4: 30 s, 1920×1080 at 60 fps, with its synthesized soundtrack.
#   scripts/promo/render.sh            full video
#   scripts/promo/render.sh --stills 4.5 12 20   PNG stills (seconds) into promo/stills
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN=$(mktemp -d)/GrabPromo
swiftc -O -o "$BIN" scripts/promo/GrabPromo.swift
mkdir -p promo
if [ "${1:-}" = "--stills" ]; then
  shift
  mkdir -p promo/stills
  "$BIN" --stills promo/stills "$@"
else
  "$BIN" promo/Grab-promo.mp4
fi
