#!/usr/bin/env bash
##############################################################################
# 06-publish.sh — Step 4: trend-reports リポを pull --rebase → commit → push
#
# Usage:
#   ./06-publish.sh --channel <id> --date YYYY-MM-DD [--confirm]
#
# Options:
#   --confirm   実際に git commit + push を行う。指定しなければ dry-run
#               (差分の表示のみ) で止まる。事故防止のため必須にしている。
##############################################################################

set -euo pipefail

LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_lib.sh
source "${LIB_DIR}/_lib.sh"

CHANNEL=""
DATE=""
CONFIRM=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --channel) CHANNEL="$2"; shift 2 ;;
        --date)    DATE="$2"; shift 2 ;;
        --confirm) CONFIRM=1; shift ;;
        *) die "unknown argument: $1" ;;
    esac
done

[[ -z "$CHANNEL" ]] && die "--channel is required"
[[ -z "$DATE"    ]] && die "--date is required (YYYY-MM-DD)"

load_channel "$CHANNEL"

REPORT_REL="src/content/reports/${DATE}-${CHANNEL}.md"
REPORT_ABS="${REPORTS_DIR}/${REPORT_REL}"
[[ -f "$REPORT_ABS" ]] || die "report not found: ${REPORT_ABS}"

cd "$REPORTS_DIR"

log "[06-publish] ${CHANNEL_NAME} ${DATE} — confirm=${CONFIRM}"
log "  git status:"
git status --short | while IFS= read -r line; do log "    | $line"; done
log "  git diff ${REPORT_REL}:"
git diff -- "$REPORT_REL" | head -60 | while IFS= read -r line; do log "    | $line"; done

if [[ "$CONFIRM" != "1" ]]; then
    log "[06-publish] dry-run: re-run with --confirm to actually publish"
    exit 0
fi

# 順序: stage → commit → fetch/rebase → push
# (`pull --rebase` を unstaged 状態で走らせると "cannot pull with rebase:
# You have unstaged changes" で落ちるため、コミットしてからリベース)
git add -- "$REPORT_REL"
if git diff --cached --quiet; then
    log "  No changes to commit"
    exit 0
fi

git commit -m "Report: ${CHANNEL_NAME} ${DATE} (manual rerun)"

git fetch origin 2>&1 | { if [[ -n "${LOG_FILE:-}" ]]; then tee -a "$LOG_FILE"; else cat; fi; }
git rebase origin/main 2>&1 | { if [[ -n "${LOG_FILE:-}" ]]; then tee -a "$LOG_FILE"; else cat; fi; } \
    || die "git rebase failed — resolve conflict and re-run with --confirm"

git push origin main 2>&1 | { if [[ -n "${LOG_FILE:-}" ]]; then tee -a "$LOG_FILE"; else cat; fi; } \
    || die "git push failed"

log "[06-publish] done"
