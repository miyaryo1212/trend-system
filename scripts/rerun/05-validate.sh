#!/usr/bin/env bash
##############################################################################
# 05-validate.sh — Step 3.6: frontmatter (YAML 構文 + zod 等価のスキーマ型検査)
# を validate-frontmatter.py で実行。失敗したら claude -p に修正を依頼する
# 自動修復オプション付き。
#
# Usage:
#   ./05-validate.sh --report <markdown-path> [--repair]
#
# Options:
#   --repair    検証に失敗した場合 claude -p に修正依頼を出してリトライ
##############################################################################

set -euo pipefail

LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_lib.sh
source "${LIB_DIR}/_lib.sh"

REPORT=""
DO_REPAIR=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --report) REPORT="$2"; shift 2 ;;
        --repair) DO_REPAIR=1; shift ;;
        *) die "unknown argument: $1" ;;
    esac
done

[[ -z "$REPORT" ]] && die "--report is required"
[[ -f "$REPORT" ]] || die "report not found: ${REPORT}"

VALIDATOR="${SYSTEM_DIR}/scripts/validate-frontmatter.py"
[[ -f "$VALIDATOR" ]] || die "validator not found: ${VALIDATOR}"

TMPDIR_LOCAL="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_LOCAL"' EXIT
VALIDATE_OUT="${TMPDIR_LOCAL}/validate.txt"

log "[05-validate] target=${REPORT}"

if python3 "$VALIDATOR" "$REPORT" > "$VALIDATE_OUT" 2>&1; then
    log "  Frontmatter: OK"
    exit 0
fi

log "  Frontmatter: INVALID"
while IFS= read -r line; do log "    | $line"; done < "$VALIDATE_OUT"

if [[ "$DO_REPAIR" != "1" ]]; then
    log "  --repair not specified, exiting"
    exit 1
fi

log "  Falling back to claude -p for repair..."

REPAIR_PROMPT="${TMPDIR_LOCAL}/yaml_repair_prompt.md"
{
    echo "次のMarkdownレポートのfrontmatter (先頭の \`---\` で囲まれたYAML部分) に構文エラーがあります。\`Edit\` ツールで in-place 修正してください。"
    echo
    echo "- ファイル: ${REPORT}"
    echo "- バリデータ出力:"
    echo
    echo '```'
    cat "$VALIDATE_OUT"
    echo '```'
    echo
    echo "修正ルール:"
    echo "1. **frontmatter (先頭の \`---\` 〜 直後の \`---\` の間) のみ** を修正する。本文には触れない。"
    echo "2. **重複キー** がある場合は **末尾側 (閉じ \`---\` に近い方)** を残す。後段で自動注入された値が末尾側であり、これをシステムの正と扱う。"
    echo "3. 型エラー (features が array でなく null/string 等) の場合は schema (array of strings) に合わせる。"
    echo "4. それ以外のYAMLエラー (引用符・インデント等) は最小限の編集で修正する。"
    echo "5. 修正後はそのターンで終了すること。"
} > "$REPAIR_PROMPT"

claude -p \
    --max-turns 5 \
    --allowedTools "Read" "Edit" \
    < "$REPAIR_PROMPT" \
    2>&1 | { if [[ -n "${LOG_FILE:-}" ]]; then tee -a "$LOG_FILE"; else cat; fi; } || true

if python3 "$VALIDATOR" "$REPORT" > "$VALIDATE_OUT" 2>&1; then
    log "[05-validate] REPAIRED by claude -p"
    exit 0
fi

log "ERROR: Frontmatter still invalid after claude repair:"
while IFS= read -r line; do log "    | $line"; done < "$VALIDATE_OUT"
exit 1
