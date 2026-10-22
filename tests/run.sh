#!/bin/bash
# Tests for 划词查词, run by `./build.sh test` after a build. They use the dictionaries
# installed on this Mac (Oxford English–Chinese for the Chinese glosses).
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/WordPop.app/Contents/MacOS/WordPop
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
failed=0
check() {
  if eval "$2"; then echo "  ok    $1"; else echo "  FAIL  $1"; failed=1; fi
}

echo "Dictionary lookups and the vocabulary file"
export WORDPOP_VOCAB="$TMP/vocab.txt"
"$APP" --snapshot "soils," "$TMP/soils.png"
"$APP" --snapshot soil "$TMP/soil.png"
"$APP" --snapshot Ubiquitous "$TMP/ubiquitous.png" toggle
"$APP" --snapshot personal "$TMP/personal.png"
"$APP" --snapshot natively "$TMP/natively.png"
"$APP" --snapshot xyzzyq "$TMP/missing.png"
check "a looked-up word is added under its headword (soils -> soil)" "grep -q '^soil	' '$WORDPOP_VOCAB'"
check "looking it up again counts and marks it" "grep -qE '^soil	.*	2$' '$WORDPOP_VOCAB'"
check "移出生词本 takes a word off the list" "! grep -q '^ubiquitous' '$WORDPOP_VOCAB'"
check "Oxford comes before the Apple Dictionary (personal != Personal Voice)" "! grep -q 'Personal Voice' '$WORDPOP_VOCAB'"
check "English-only entries keep a clean headword (natively)" "grep -q '^natively	by birth' '$WORDPOP_VOCAB'"
check "words not in any dictionary aren't added" "! grep -q '^xyzzyq' '$WORDPOP_VOCAB'"
check "popups render" "[ -s '$TMP/soils.png' ] && [ -s '$TMP/missing.png' ]"
if grep -q '^personal	个人' "$WORDPOP_VOCAB"; then
  echo "  ok    Chinese glosses from Oxford English–Chinese"
else
  echo "  skip  Chinese glosses (Oxford English–Chinese is not installed in Dictionary.app)"
fi

echo "Reading words off the screen (OCR)"
clang -fobjc-arc -fmodules -O2 -w -framework Cocoa -framework Vision -framework ScreenCaptureKit \
  -framework UniformTypeIdentifiers -framework ImageIO -framework CoreServices \
  tests/ocr_test.m -o build/ocr_test
build/ocr_test || failed=1

if [ "$failed" = 0 ]; then echo "All tests passed"; else echo "Some tests failed"; fi
exit "$failed"
