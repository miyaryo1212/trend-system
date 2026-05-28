#!/usr/bin/env bash
##############################################################################
# 04-codex-review.sh — Step 3.5: codex exec で review を生成し、
# frontmatter に codex_review / codex_importance を注入。
# 既存の同名フィールドは事前に除去するため再実行で重複しない。
#
# Usage:
#   ./04-codex-review.sh --report <markdown-path>
##############################################################################

set -euo pipefail

LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_lib.sh
source "${LIB_DIR}/_lib.sh"

REPORT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --report) REPORT="$2"; shift 2 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[[ -z "$REPORT"   ]] && die "--report is required"
[[ -f "$REPORT"   ]] || die "report not found: ${REPORT}"

command -v codex >/dev/null 2>&1 || die "codex CLI not found"

TMPDIR_LOCAL="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_LOCAL"' EXIT

log "[04-codex-review] target=${REPORT}"

# 既存の codex_review / codex_importance を frontmatter から除去
# (rerun で重複させないため)
awk '
    BEGIN { c = 0 }
    /^---$/ { c++; print; next }
    c == 1 && /^codex_review:/   { next }
    c == 1 && /^codex_importance:/ { next }
    { print }
' "$REPORT" > "${REPORT}.tmp" && mv "${REPORT}.tmp" "$REPORT"

# プロンプト構築
CODEX_PROMPT="${TMPDIR_LOCAL}/codex_prompt.md"
awk -v f="$REPORT" '
    /{{REPORT}}/ {
        while ((getline line < f) > 0) print line
        close(f)
        next
    }
    { print }
' "${SYSTEM_DIR}/prompts/codex-review.md" > "$CODEX_PROMPT"

CODEX_OUTPUT="${TMPDIR_LOCAL}/codex_output.txt"
# モデル明示 pin (run.sh と同様、デフォルト drift による silent 失敗の防止)
CODEX_MODEL="${CODEX_MODEL:-gpt-5.4}"
if ! codex exec --model "$CODEX_MODEL" --skip-git-repo-check - < "$CODEX_PROMPT" > "$CODEX_OUTPUT" 2>>"${LOG_FILE:-/dev/null}"; then
    die "codex exec failed"
fi

# ANSI カラー除去 + 外側 { から } までを抽出
CLEAN_JSON="${TMPDIR_LOCAL}/codex_review.json"
sed 's/\x1b\[[0-9;]*m//g' "$CODEX_OUTPUT" | awk '/^\{/,/^\}/' > "$CLEAN_JSON"

if [[ ! -s "$CLEAN_JSON" ]] || ! jq empty "$CLEAN_JSON" 2>/dev/null; then
    log "  codex raw output ---"
    cat "$CODEX_OUTPUT" | { if [[ -n "${LOG_FILE:-}" ]]; then tee -a "$LOG_FILE"; else cat; fi; }
    die "codex output did not contain valid JSON"
fi

CODEX_REVIEW_TEXT="$(jq -r '.review // ""' "$CLEAN_JSON")"
CODEX_IMP="$(jq -r '.importance // empty' "$CLEAN_JSON")"

if [[ -z "$CODEX_REVIEW_TEXT" ]]; then
    die "codex returned empty review"
fi

log "  Codex: \"${CODEX_REVIEW_TEXT}\" (★${CODEX_IMP:-?})"

REVIEW_ESC="$(printf '%s' "$CODEX_REVIEW_TEXT" | sed 's/"/\\"/g')"
awk -v review="$REVIEW_ESC" -v imp="$CODEX_IMP" '
    BEGIN { c = 0; injected = 0 }
    /^---$/ {
        c++
        if (c == 2 && !injected) {
            print "codex_review: \"" review "\""
            if (imp != "") print "codex_importance: " imp
            injected = 1
        }
    }
    { print }
' "$REPORT" > "${REPORT}.tmp" && mv "${REPORT}.tmp" "$REPORT"

log "[04-codex-review] done — codex_review/codex_importance injected"
