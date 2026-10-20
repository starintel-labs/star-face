#!/usr/bin/env bash
# star-face gates: library load, actor compilation, contract tests.
set -euo pipefail

REPO_ROOT="${STAR_FACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STAR_LANG_SRC="${STAR_LANG_SRC:?STAR_LANG_SRC must point at the star-lang source tree}"
SBCL="${STAR_FACE_SBCL:-sbcl}"
STARLANG="${STARLANG_BIN:-${STAR_LANG_SRC}/result/bin/starlang}"

cd "$REPO_ROOT"

echo "== gate 1: spec library load (locked imports verified)"
"$STARLANG" load spec/star-face.star \
  --cache .cache/specs \
  --manifest .cache/loader-star-face.json

echo "== gate 2: actor program compilation"
for actor in actors/*.star; do
  name="$(basename "$actor" .star)"
  "$STARLANG" compile "$actor" --manifest "manifest/${name}.json"
done

echo "== gate 3: contract tests on the deterministic dispatcher"
STAR_LANG_SRC="$STAR_LANG_SRC" \
STAR_FACE_ROOT="$REPO_ROOT" \
CL_SOURCE_REGISTRY="${STAR_LANG_SRC}//:${REPO_ROOT}/lisp//" \
  "$SBCL" --script lisp/t/run-all.lisp

echo "== gate 4: stub pipeline end to end (engine -> ingest -> search)"
STUB_DB="$(mktemp -d)/db"
STUB_RESULTS="$(mktemp -d)/stub.jsonl"
python3 engine/face_engine.py stub-video --stub > "$STUB_RESULTS"
[ "$(wc -l < "$STUB_RESULTS")" -eq 2 ] || { echo "stub engine lines != 2"; exit 1; }
STAR_LANG_SRC="$STAR_LANG_SRC" STAR_FACE_ROOT="$REPO_ROOT" STAR_FACE_DB="$STUB_DB" \
STAR_FACE_CLOCK="2026-01-01T00:00:00Z" \
CL_SOURCE_REGISTRY="${STAR_LANG_SRC}//:${REPO_ROOT}/lisp//" \
  "$SBCL" --script scripts/ingest-face-results.lisp "$STUB_RESULTS" \
  | tee /dev/stderr | grep -q "total replies:2 faces:2 documents:4 duplicates:0" \
  || { echo "stub ingest summary mismatch"; exit 1; }
[ "$(find "$STUB_DB" -name '*.ndjson' | wc -l)" -eq 4 ] \
  || { echo "stub document count != 4"; exit 1; }
STAR_LANG_SRC="$STAR_LANG_SRC" STAR_FACE_ROOT="$REPO_ROOT" STAR_FACE_DB="$STUB_DB" \
CL_SOURCE_REGISTRY="${STAR_LANG_SRC}//:${REPO_ROOT}/lisp//" \
  "$SBCL" --script scripts/search-faces.lisp --embedding "$STUB_RESULTS" \
  | tee /dev/stderr | grep -q '"status":"ok"' \
  || { echo "stub search did not reply ok"; exit 1; }
STAR_LANG_SRC="$STAR_LANG_SRC" STAR_FACE_ROOT="$REPO_ROOT" STAR_FACE_DB="$STUB_DB" \
STAR_FACE_CLOCK="2026-01-01T00:00:00Z" \
CL_SOURCE_REGISTRY="${STAR_LANG_SRC}//:${REPO_ROOT}/lisp//" \
  "$SBCL" --script scripts/ingest-face-results.lisp "$STUB_RESULTS" \
  | tee /dev/stderr | grep -q "duplicates:4" \
  || { echo "re-ingest did not dedupe"; exit 1; }

echo "== all gates green"
