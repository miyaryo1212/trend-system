#!/usr/bin/env bash
##############################################################################
# 03-report.sh — Step 3: claude -p で最終レポート Markdown を生成
#
# Usage:
#   ./03-report.sh --channel <id> --date YYYY-MM-DD --workdir <path>
#                  [--output <path>] [--prev <path>]
#
# Inputs (workdir 配下、Step 0 + 1 + 2 の出力):
#   official_rss.txt
#   community_rss.txt
#   web_search_queries.txt   (任意)
#   sitemap_new_pages.txt    (任意)
#   features.txt             (Step 1 相当 — 手書き)
#   x_search_results.txt     (Step 2 相当)
#
# Inputs (任意):
#   --output     書き出し先 (default: ${REPORTS_DIR}/src/content/reports/${DATE}-${CHANNEL}.md)
#   --prev       直前レポートのパス (default: 同チャネルの最新を REPORTS_DIR から ls)
#                空ファイルや存在しない場合は "(前回レポートなし)" 扱い
##############################################################################

set -euo pipefail

LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_lib.sh
source "${LIB_DIR}/_lib.sh"

CHANNEL=""
DATE=""
WORKDIR=""
OUTPUT_PATH=""
PREV_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --channel) CHANNEL="$2"; shift 2 ;;
        --date)    DATE="$2"; shift 2 ;;
        --workdir) WORKDIR="$2"; shift 2 ;;
        --output)  OUTPUT_PATH="$2"; shift 2 ;;
        --prev)    PREV_FILE="$2"; shift 2 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[[ -z "$CHANNEL" ]] && die "--channel is required"
[[ -z "$DATE"    ]] && die "--date is required (YYYY-MM-DD)"
[[ -z "$WORKDIR" ]] && die "--workdir is required"
mkdir -p "$WORKDIR"
WORKDIR="$(cd "$WORKDIR" && pwd)"

load_channel "$CHANNEL"

OUTPUT_PATH="${OUTPUT_PATH:-${REPORTS_DIR}/src/content/reports/${DATE}-${CHANNEL}.md}"
mkdir -p "$(dirname "$OUTPUT_PATH")"

# 前回レポートの解決 — rerun 時は対象日付より前の最新を選ぶのが筋
if [[ -z "$PREV_FILE" ]]; then
    PREV_FILE="$(find "${REPORTS_DIR}/src/content/reports" \
        -maxdepth 1 -type f -name "*-${CHANNEL}.md" 2>/dev/null \
        | sed -E "s|.*/||" \
        | awk -v d="${DATE}-${CHANNEL}.md" '$0 < d' \
        | sort -r | head -1)"
    [[ -n "$PREV_FILE" ]] && PREV_FILE="${REPORTS_DIR}/src/content/reports/${PREV_FILE}"
fi

PREV_PATH="${WORKDIR}/previous_report.txt"
if [[ -n "$PREV_FILE" && -f "$PREV_FILE" ]]; then
    log "  Previous report: ${PREV_FILE}"
    head -c 20000 "$PREV_FILE" > "$PREV_PATH"
else
    log "  No previous report"
    echo "(前回レポートなし — 初回生成)" > "$PREV_PATH"
fi

# 必須入力の確認 (Step 0/1/2 を済ませてから来ているか)
for f in official_rss.txt community_rss.txt features.txt x_search_results.txt; do
    [[ -f "${WORKDIR}/${f}" ]] || die "missing input: ${WORKDIR}/${f}"
done
# 任意入力は空ファイルで埋める
[[ -f "${WORKDIR}/web_search_queries.txt" ]] || : > "${WORKDIR}/web_search_queries.txt"
[[ -f "${WORKDIR}/sitemap_new_pages.txt"  ]] || : > "${WORKDIR}/sitemap_new_pages.txt"

TMPDIR_LOCAL="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_LOCAL"' EXIT

# テンプレート選択: チャネル専用があればそちら
STEP3_TEMPLATE="${SYSTEM_DIR}/prompts/trend-research-${CHANNEL}.md"
[[ -f "$STEP3_TEMPLATE" ]] || STEP3_TEMPLATE="${SYSTEM_DIR}/prompts/trend-research.md"
log "  Template: ${STEP3_TEMPLATE}"

echo "$CHANNEL_NAME" > "${TMPDIR_LOCAL}/val_channel_name.txt"
echo "$CHANNEL"      > "${TMPDIR_LOCAL}/val_channel_id.txt"
echo "$DATE"         > "${TMPDIR_LOCAL}/val_date.txt"
echo "$OUTPUT_PATH"  > "${TMPDIR_LOCAL}/val_output_path.txt"

render_template "$STEP3_TEMPLATE" "${TMPDIR_LOCAL}/step3_prompt.md" \
    "CHANNEL_NAME=${TMPDIR_LOCAL}/val_channel_name.txt" \
    "CHANNEL_ID=${TMPDIR_LOCAL}/val_channel_id.txt" \
    "DATE=${TMPDIR_LOCAL}/val_date.txt" \
    "OUTPUT_PATH=${TMPDIR_LOCAL}/val_output_path.txt" \
    "RSS_DATA=${WORKDIR}/official_rss.txt" \
    "FEATURES=${WORKDIR}/features.txt" \
    "X_SEARCH_DATA=${WORKDIR}/x_search_results.txt" \
    "COMMUNITY_RSS=${WORKDIR}/community_rss.txt" \
    "PREVIOUS_REPORT=${PREV_PATH}"

log "[03-report] Calling claude -p..."
claude -p \
    --max-turns 15 \
    --allowedTools "Read" "Write" "Bash(curl:*)" "WebSearch" "WebFetch" \
    < "${TMPDIR_LOCAL}/step3_prompt.md" \
    2>&1 | { if [[ -n "${LOG_FILE:-}" ]]; then tee -a "$LOG_FILE"; else cat; fi; }

[[ -f "$OUTPUT_PATH" ]] || die "Report file was not created at ${OUTPUT_PATH}"

FILE_SIZE="$(stat -c%s "$OUTPUT_PATH")"
log "[03-report] done — ${OUTPUT_PATH} (${FILE_SIZE} bytes)"
