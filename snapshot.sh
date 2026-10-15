#!/bin/bash
# Renderiza o painel com dados fictícios em PNG.
set -euo pipefail
cd "$(dirname "$0")"
OUT="${1:-docs}"; mkdir -p "$OUT" .build
swiftc -O -parse-as-library -o .build/snapshot $(ls Sources/CastMenubar/*.swift | grep -v App.swift) Snapshot/Snapshot.swift 2>&1 | grep "error:" || true
.build/snapshot "$OUT"
