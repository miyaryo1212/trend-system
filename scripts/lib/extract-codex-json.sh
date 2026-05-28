#!/usr/bin/env bash
# extract-codex-json.sh
# codex exec の生出力から ANSI カラーコードを除去し、最初に `{` で始まる行から
# 最初に `}` で始まる行までを JSON オブジェクトとして抽出する。
# 用途: Step 3.5 (codex_review JSON のパース前処理)。
#
# Usage: extract-codex-json.sh <codex_raw_output_file>
#        cat raw.txt | extract-codex-json.sh -
set -euo pipefail
src="${1:--}"
sed 's/\x1b\[[0-9;]*m//g' "$src" | awk '/^\{/,/^\}/'
