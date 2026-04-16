#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# backfill-codex-reviews.sh — 過去レポートへの Codex レビュー後付け
#
# Usage:
#   ./scripts/backfill-codex-reviews.sh --dry-run [--limit N]
#   ./scripts/backfill-codex-reviews.sh [--limit N]
#
# - codex_review フィールドを持たない記事に codex exec で review 生成
# - review 末尾に暫定運用の但し書きを連結
# - frontmatter の閉じ --- 直前に codex_review / codex_importance を注入
# - 既に codex_review: がある記事はスキップ (冪等)
# - 失敗した記事はログに記録し処理継続
##############################################################################

export TZ=Asia/Tokyo

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SYSTEM_DIR="$(dirname "$SCRIPT_DIR")"

if [[ -f "${SYSTEM_DIR}/.env.local" ]]; then
    source "${SYSTEM_DIR}/.env.local"
elif [[ -f "${HOME}/.env.agent" ]]; then
    source "${HOME}/.env.agent"
fi

REPORTS_DIR="${TREND_REPORTS_DIR:-$(dirname "$SYSTEM_DIR")/trend-reports}"
CONTENT_DIR="${REPORTS_DIR}/src/content/reports"
PROMPT_FILE="${SYSTEM_DIR}/prompts/codex-review.md"
LOG_DIR="${SYSTEM_DIR}/logs"
LOG_FILE="${LOG_DIR}/backfill-$(date +%Y%m%d-%H%M%S).log"
BACKFILL_NOTE="※ このレビューは後日生成されました"
SLEEP_SEC=3

DRY_RUN=false
LIMIT=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        --limit)   LIMIT="$2"; shift 2 ;;
        *)         echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

mkdir -p "$LOG_DIR"
log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG_FILE"; }

log "=== Codex backfill start (dry_run=${DRY_RUN}, limit=${LIMIT}) ==="
log "  Content dir: ${CONTENT_DIR}"
log "  Prompt:      ${PROMPT_FILE}"
log "  Log:         ${LOG_FILE}"

# 処理対象リスト作成
TARGETS=()
for md in "$CONTENT_DIR"/*.md; do
    if ! grep -q '^codex_review:' "$md"; then
        TARGETS+=("$md")
    fi
done

TOTAL="${#TARGETS[@]}"
log "  Targets: ${TOTAL} files (without codex_review)"

if [[ "$LIMIT" -gt 0 && "$LIMIT" -lt "$TOTAL" ]]; then
    TARGETS=("${TARGETS[@]:0:$LIMIT}")
    TOTAL="${#TARGETS[@]}"
    log "  Limited to first ${TOTAL} files"
fi

if [[ "$TOTAL" -eq 0 ]]; then
    log "No targets, exiting"
    exit 0
fi

# pull --rebase (dry-run 以外)
if [[ "$DRY_RUN" != true ]]; then
    log "  git pull --rebase origin main"
    (cd "$REPORTS_DIR" && git pull --rebase origin main) >> "$LOG_FILE" 2>&1 || {
        log "ERROR: git pull --rebase failed"
        exit 1
    }
fi

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

SUCCESS_COUNT=0
FAIL_COUNT=0
FAIL_LIST=()

for i in "${!TARGETS[@]}"; do
    md="${TARGETS[$i]}"
    slug="$(basename "$md" .md)"
    idx=$((i + 1))
    log "[${idx}/${TOTAL}] ${slug}"

    # プロンプト組み立て
    awk -v f="$md" '
        /{{REPORT}}/ {
            while ((getline line < f) > 0) print line
            close(f)
            next
        }
        { print }
    ' "$PROMPT_FILE" > "${TMPDIR}/prompt.md"

    # Codex 実行
    RAW="${TMPDIR}/raw.txt"
    if ! codex exec --skip-git-repo-check - < "${TMPDIR}/prompt.md" > "$RAW" 2>>"$LOG_FILE"; then
        log "  FAIL: codex exec returned non-zero"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAIL_LIST+=("$slug")
        sleep "$SLEEP_SEC"
        continue
    fi

    # ANSI除去 + JSON抽出
    CLEAN="${TMPDIR}/clean.json"
    sed 's/\x1b\[[0-9;]*m//g' "$RAW" | awk '/^\{/,/^\}/' > "$CLEAN"

    if [[ ! -s "$CLEAN" ]] || ! jq empty "$CLEAN" 2>/dev/null; then
        log "  FAIL: invalid JSON"
        log "  --- raw ---"
        cat "$RAW" >> "$LOG_FILE"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAIL_LIST+=("$slug")
        sleep "$SLEEP_SEC"
        continue
    fi

    REVIEW="$(jq -r '.review // ""' "$CLEAN")"
    IMP="$(jq -r '.importance // empty' "$CLEAN")"

    if [[ -z "$REVIEW" ]]; then
        log "  FAIL: empty review"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAIL_LIST+=("$slug")
        sleep "$SLEEP_SEC"
        continue
    fi

    FULL_REVIEW="${REVIEW} ${BACKFILL_NOTE}"
    log "  review: \"${FULL_REVIEW}\""
    log "  importance: ${IMP:-?}"

    if [[ "$DRY_RUN" == true ]]; then
        log "  (dry-run: skip frontmatter injection)"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        # frontmatter に注入
        REVIEW_ESC="$(printf '%s' "$FULL_REVIEW" | sed 's/"/\\"/g')"
        awk -v review="$REVIEW_ESC" -v imp="$IMP" '
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
        ' "$md" > "${md}.tmp" && mv "${md}.tmp" "$md"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    fi

    sleep "$SLEEP_SEC"
done

log ""
log "=== Summary ==="
log "  Success: ${SUCCESS_COUNT}"
log "  Fail:    ${FAIL_COUNT}"
if [[ "$FAIL_COUNT" -gt 0 ]]; then
    log "  Failed slugs:"
    for s in "${FAIL_LIST[@]}"; do log "    - $s"; done
fi

# Dry-run 以外なら commit + push
if [[ "$DRY_RUN" != true && "$SUCCESS_COUNT" -gt 0 ]]; then
    log ""
    log "=== Commit & push ==="
    cd "$REPORTS_DIR"
    git add -A
    if git diff --cached --quiet; then
        log "  No changes staged"
    else
        git commit -m "Backfill Codex reviews for ${SUCCESS_COUNT} past reports

Codex CLI (gpt-5.4) に過去レポート本文を渡し、review + 独立 importance を
生成。本文末尾に「※ このレビューは後日生成されました」の但し書きを連結。
本番 cron (run.sh Step 3.5) は但し書きなしで当日生成。

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>" >> "$LOG_FILE" 2>&1

        log "  git pull --rebase origin main (safety)"
        git pull --rebase origin main >> "$LOG_FILE" 2>&1 || {
            log "ERROR: pull --rebase failed after commit, manual intervention needed"
            exit 1
        }
        log "  git push"
        git push origin main >> "$LOG_FILE" 2>&1 || {
            log "ERROR: push failed"
            exit 1
        }
        log "  Pushed successfully"
    fi
fi

log "=== Done ==="
