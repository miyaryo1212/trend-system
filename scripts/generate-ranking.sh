#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# generate-ranking.sh — 直近4週間Top 5ランキング生成 (AI選定)
#
# Usage: ./scripts/generate-ranking.sh [--dry-run]
#
# - 直近4週間 (28日) の★4+レポートを候補に (5件未満なら★3+で補充)
# - claude -p でTop 5を選定、30〜40字の短評を添付
# - trend-reports/src/data/ranking.json に出力
# - git push で Cloudflare Pages 再ビルドをトリガ
##############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SYSTEM_DIR="$(dirname "$SCRIPT_DIR")"

if [[ -f "${SYSTEM_DIR}/.env.local" ]]; then
    source "${SYSTEM_DIR}/.env.local"
elif [[ -f "${HOME}/.env.agent" ]]; then
    source "${HOME}/.env.agent"
fi

REPORTS_DIR="${TREND_REPORTS_DIR:-$(dirname "$SYSTEM_DIR")/trend-reports}"
CONTENT_DIR="${REPORTS_DIR}/src/content/reports"
OUTPUT_FILE="${REPORTS_DIR}/src/data/ranking.json"
LOG_DIR="${SYSTEM_DIR}/logs"
PERIOD_END="$(date +%Y-%m-%d)"
PERIOD_START="$(date -d '27 days ago' +%Y-%m-%d)"
PERIOD_LABEL="${PERIOD_START}〜${PERIOD_END}"
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/ranking-$(date +%Y%m%d).log"
log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG_FILE"; }

log "=== Ranking generation: ${PERIOD_LABEL} ==="
log "  Reports dir: ${CONTENT_DIR}"
log "  Output:      ${OUTPUT_FILE}"

if [[ ! -d "$CONTENT_DIR" ]]; then
    log "ERROR: reports dir not found"
    exit 1
fi

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

##############################################################################
# Step 1: 直近4週間のレポートをスキャンしてメタデータ抽出
##############################################################################

CANDIDATES_TSV="${TMPDIR}/candidates.tsv"
: > "$CANDIDATES_TSV"

shopt -s nullglob
for md in "${CONTENT_DIR}"/*.md; do
    slug="$(basename "$md" .md)"
    # frontmatterを `---` 間で抽出
    fm="$(awk '/^---$/{c++; next} c==1' "$md")"
    # yqでパース (入力はyaml)
    title="$(echo "$fm" | yq -r '.title // ""')"
    channel="$(echo "$fm" | yq -r '.channel // ""')"
    importance="$(echo "$fm" | yq -r '.importance // 0')"
    date_val="$(echo "$fm" | yq -r '.date // ""')"
    summary="$(echo "$fm" | yq -r '.summary // ""')"

    [[ -z "$title" ]] && continue
    [[ -z "$date_val" ]] && continue

    # 期間フィルタ: PERIOD_START <= date_val <= PERIOD_END (YYYY-MM-DD 辞書順比較)
    date_day="${date_val:0:10}"
    [[ "$date_day" < "$PERIOD_START" ]] && continue
    [[ "$date_day" > "$PERIOD_END" ]] && continue

    # TSV: slug \t date \t importance \t channel \t title \t summary
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$slug" "$date_val" "$importance" "$channel" "$title" "$summary" \
        >> "$CANDIDATES_TSV"
done
shopt -u nullglob

TOTAL="$(wc -l < "$CANDIDATES_TSV" | tr -d ' ')"
log "  Found ${TOTAL} reports in last 4 weeks"

if [[ "$TOTAL" -eq 0 ]]; then
    log "No reports in period, skipping"
    exit 0
fi

##############################################################################
# Step 2: ★4+を優先、5件未満なら★3+で補充
##############################################################################

STAR4_TSV="${TMPDIR}/star4.tsv"
STAR3_TSV="${TMPDIR}/star3.tsv"

awk -F'\t' '$3 >= 4' "$CANDIDATES_TSV" | sort -t $'\t' -k2,2r > "$STAR4_TSV"
awk -F'\t' '$3 == 3' "$CANDIDATES_TSV" | sort -t $'\t' -k2,2r > "$STAR3_TSV"

STAR4_COUNT="$(wc -l < "$STAR4_TSV" | tr -d ' ')"
STAR3_COUNT="$(wc -l < "$STAR3_TSV" | tr -d ' ')"

log "  ★4+ candidates: ${STAR4_COUNT}"
log "  ★3  candidates: ${STAR3_COUNT}"

SELECTED_TSV="${TMPDIR}/selected.tsv"
cp "$STAR4_TSV" "$SELECTED_TSV"

if [[ "$STAR4_COUNT" -lt 5 ]]; then
    NEED=$((5 - STAR4_COUNT))
    log "  Adding top ${NEED} ★3 reports to reach 5"
    head -n "$NEED" "$STAR3_TSV" >> "$SELECTED_TSV"
fi

CANDIDATE_COUNT="$(wc -l < "$SELECTED_TSV" | tr -d ' ')"
log "  Total candidates for AI: ${CANDIDATE_COUNT}"

##############################################################################
# Step 3: プロンプト構築
##############################################################################

CANDIDATES_BLOCK="${TMPDIR}/candidates_block.md"
: > "$CANDIDATES_BLOCK"

while IFS=$'\t' read -r slug date_val imp channel title summary; do
    cat >> "$CANDIDATES_BLOCK" <<EOF

---

- **slug**: \`${slug}\`
- **date**: ${date_val}
- **channel**: ${channel}
- **importance**: ★${imp}
- **title**: ${title}
- **summary**: ${summary}
EOF
done < "$SELECTED_TSV"

PROMPT_FILE="${TMPDIR}/prompt.md"
sed -e "s|{{PERIOD}}|${PERIOD_LABEL}|g" "${SYSTEM_DIR}/prompts/ranking-selection.md" > "${PROMPT_FILE}.tmp"
# {{CANDIDATES}} をファイル差し込み
awk -v f="$CANDIDATES_BLOCK" '
    /{{CANDIDATES}}/ {
        while ((getline line < f) > 0) print line
        close(f)
        next
    }
    { print }
' "${PROMPT_FILE}.tmp" > "$PROMPT_FILE"

if [[ "$DRY_RUN" == true ]]; then
    log "=== DRY RUN: prompt preview ==="
    cat "$PROMPT_FILE"
    log "=== end prompt ==="
    exit 0
fi

##############################################################################
# Step 4: Claude呼び出し
##############################################################################

log "[Claude] Selecting Top 5..."
RAW_OUTPUT="${TMPDIR}/claude_output.txt"

claude -p \
    --max-turns 2 \
    --allowedTools "Read" \
    < "$PROMPT_FILE" \
    > "$RAW_OUTPUT" 2>> "$LOG_FILE" || true

if [[ ! -s "$RAW_OUTPUT" ]]; then
    log "ERROR: claude returned empty output"
    exit 1
fi

# コードフェンス除去 + JSONオブジェクト抽出
CLEAN_JSON="${TMPDIR}/ranking_raw.json"
awk '
    /^```/ { in_fence = !in_fence; next }
    { print }
' "$RAW_OUTPUT" | sed -n '/{/,/}/p' > "$CLEAN_JSON"

if ! jq empty "$CLEAN_JSON" 2>/dev/null; then
    log "ERROR: invalid JSON from claude"
    log "--- raw output ---"
    cat "$RAW_OUTPUT" | tee -a "$LOG_FILE"
    exit 1
fi

##############################################################################
# Step 5: メタ情報を追加して最終JSON生成
##############################################################################

FINAL_JSON="${TMPDIR}/ranking.json"
jq --arg period_start "$PERIOD_START" \
   --arg period_end "$PERIOD_END" \
   --arg generated_at "$NOW_ISO" \
    '{generated_at: $generated_at, period_start: $period_start, period_end: $period_end, items: .items}' \
    "$CLEAN_JSON" > "$FINAL_JSON"

log "  Generated ranking:"
jq -r '.items[] | "    #\(.rank) \(.slug) — \(.reason)"' "$FINAL_JSON" | tee -a "$LOG_FILE"

mkdir -p "$(dirname "$OUTPUT_FILE")"
cp "$FINAL_JSON" "$OUTPUT_FILE"

##############################################################################
# Step 6: git commit & push
##############################################################################

cd "$REPORTS_DIR"
if git diff --quiet -- "src/data/ranking.json" 2>/dev/null; then
    log "  No changes in ranking.json, skipping commit"
else
    git add "src/data/ranking.json"
    git commit -m "ranking: update Top 5 (${PERIOD_LABEL})" >> "$LOG_FILE" 2>&1
    git push >> "$LOG_FILE" 2>&1
    log "  Pushed to remote"
fi

log "=== Done ==="
