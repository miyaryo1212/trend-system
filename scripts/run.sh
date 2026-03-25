#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# run.sh — トレンド調査レポート生成 (2段階パイプライン)
#
# Usage: ./scripts/run.sh <channel-id>
#   例: ./scripts/run.sh claude-code
#       ./scripts/run.sh codex-openai
#       ./scripts/run.sh ai-trends
#       ./scripts/run.sh github-trending
#
# Pipeline:
#   Step 0: RSSフィード取得 (curl)
#   Step 1: 新機能・トピック抽出 (claude -p, コスト$0)
#   Step 2: 機能ごとにX検索 (Grok x_search, ~$0.02/機能)
#   Step 3: 最終レポート生成 (claude -p, コスト$0)
#   Step 4: index.html再生成 + git push
##############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SYSTEM_DIR="$(dirname "$SCRIPT_DIR")"

# 環境設定ファイルの読み込み (.env.local > ~/.env.agent)
if [[ -f "${SYSTEM_DIR}/.env.local" ]]; then
    source "${SYSTEM_DIR}/.env.local"
elif [[ -f "${HOME}/.env.agent" ]]; then
    source "${HOME}/.env.agent"
fi

REPORTS_DIR="${TREND_REPORTS_DIR:-$(dirname "$SYSTEM_DIR")/trend-reports}"
DATE="$(date +%Y-%m-%d)"
LOG_DIR="${SYSTEM_DIR}/logs"
CONFIG_FILE="${SYSTEM_DIR}/config/keywords.yml"

# ---- 引数チェック ----

CHANNEL="${1:-}"
if [[ -z "$CHANNEL" ]]; then
    echo "Usage: $0 <channel-id>" >&2
    echo "Available channels:" >&2
    yq '.channels | keys | .[]' "$CONFIG_FILE" >&2
    exit 1
fi

# ---- ロギング ----

mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/${DATE}-${CHANNEL}.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# ---- ロック ----

LOCK_FILE="/tmp/trend-report-${CHANNEL}.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    log "ERROR: Another instance for channel '${CHANNEL}' is already running."
    exit 1
fi

# ---- 一時ディレクトリ ----

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"; rm -f "$LOCK_FILE"' EXIT

# ---- 設定読み込み ----

if ! yq -e ".channels.${CHANNEL}" "$CONFIG_FILE" > /dev/null 2>&1; then
    log "ERROR: Channel '${CHANNEL}' not found in ${CONFIG_FILE}"
    exit 1
fi

CHANNEL_NAME="$(yq -r ".channels.${CHANNEL}.name" "$CONFIG_FILE")"
log "=== Start: ${CHANNEL_NAME} (${CHANNEL}) ==="

# ---- ユーティリティ関数 ----

fetch_rss() {
    local url="$1"
    local name="$2"
    local max_size="${3:-50000}"

    log "  RSS: ${name}"
    local tmpfile="${TMPDIR}/rss_$(date +%s%N).xml"
    if ! curl -sL --max-time 30 -o "$tmpfile" "$url" 2>/dev/null; then
        log "  WARNING: Failed to fetch ${name}"
        echo "(取得失敗: ${name})"
        return
    fi

    if [[ ! -s "$tmpfile" ]]; then
        log "  WARNING: Empty response from ${name}"
        echo "(取得失敗: ${name})"
        return
    fi

    head -c "$max_size" "$tmpfile"
}

# テンプレートのプレースホルダーを置換するヘルパー
render_template() {
    local template_file="$1"
    local output_file="$2"
    shift 2
    # 残りの引数は "KEY=VALUE" ペア
    cp "$template_file" "$output_file"
    while [[ $# -gt 0 ]]; do
        local key="${1%%=*}"
        local val_file="${1#*=}"
        python3 -c "
import sys
with open('${output_file}', 'r', errors='replace') as f:
    content = f.read()
with open('${val_file}', 'r', errors='replace') as f:
    val = f.read()
content = content.replace('{{${key}}}', val)
with open('${output_file}', 'w') as f:
    f.write(content)
"
        shift
    done
}

##############################################################################
# Step 0: RSSフィード取得
##############################################################################

log "[Step 0] Fetching RSS feeds..."

# 公式ソース (RSS取得 + web_searchクエリ収集)
OFFICIAL_RSS=""
WEB_SEARCH_QUERIES=""
official_count="$(yq ".channels.${CHANNEL}.official_sources | length" "$CONFIG_FILE")"
for ((i = 0; i < official_count; i++)); do
    src_type="$(yq -r ".channels.${CHANNEL}.official_sources[${i}].type" "$CONFIG_FILE")"
    src_name="$(yq -r ".channels.${CHANNEL}.official_sources[${i}].name" "$CONFIG_FILE")"

    if [[ "$src_type" == "rss" ]]; then
        src_url="$(yq -r ".channels.${CHANNEL}.official_sources[${i}].url" "$CONFIG_FILE")"
        OFFICIAL_RSS+="
--- ${src_name} ---
$(fetch_rss "$src_url" "$src_name")
"
    elif [[ "$src_type" == "web_search" ]]; then
        src_query="$(yq -r ".channels.${CHANNEL}.official_sources[${i}].query" "$CONFIG_FILE")"
        log "  Web search: ${src_name} (query: ${src_query})"
        WEB_SEARCH_QUERIES+="
- ${src_name}: ${src_query}"
    fi
done

# コミュニティRSS
COMMUNITY_RSS=""
community_count="$(yq ".channels.${CHANNEL}.community_sources | length" "$CONFIG_FILE" 2>/dev/null || echo 0)"
for ((i = 0; i < community_count; i++)); do
    src_type="$(yq -r ".channels.${CHANNEL}.community_sources[${i}].type" "$CONFIG_FILE")"
    src_name="$(yq -r ".channels.${CHANNEL}.community_sources[${i}].name" "$CONFIG_FILE")"

    if [[ "$src_type" == "rss" ]]; then
        src_url="$(yq -r ".channels.${CHANNEL}.community_sources[${i}].url" "$CONFIG_FILE")"
        COMMUNITY_RSS+="
--- ${src_name} ---
$(fetch_rss "$src_url" "$src_name")
"
    fi
done

echo "$OFFICIAL_RSS" > "${TMPDIR}/official_rss.txt"
echo "$COMMUNITY_RSS" > "${TMPDIR}/community_rss.txt"
echo "$WEB_SEARCH_QUERIES" > "${TMPDIR}/web_search_queries.txt"

##############################################################################
# Step 1: 新機能・トピック抽出 (claude -p)
##############################################################################

log "[Step 1] Extracting features/topics..."

FEATURES_PATH="${TMPDIR}/features.txt"
EXTRACTION_PROMPT="$(yq -r ".channels.${CHANNEL}.feature_extraction.prompt" "$CONFIG_FILE")"

# プロンプト構築
cat "${SYSTEM_DIR}/prompts/feature-extraction.md" > "${TMPDIR}/step1_template.md"

echo "$CHANNEL_NAME" > "${TMPDIR}/val_channel_name.txt"
echo "$EXTRACTION_PROMPT" > "${TMPDIR}/val_extraction_prompt.txt"
echo "$FEATURES_PATH" > "${TMPDIR}/val_features_path.txt"

render_template "${TMPDIR}/step1_template.md" "${TMPDIR}/step1_prompt.md" \
    "CHANNEL_NAME=${TMPDIR}/val_channel_name.txt" \
    "EXTRACTION_PROMPT=${TMPDIR}/val_extraction_prompt.txt" \
    "RSS_DATA=${TMPDIR}/official_rss.txt" \
    "WEB_SEARCH_QUERIES=${TMPDIR}/web_search_queries.txt" \
    "FEATURES_PATH=${TMPDIR}/val_features_path.txt"

log "  Calling claude -p for feature extraction..."
claude -p \
    --max-turns 6 \
    --allowedTools "Read" "Write" "Bash(curl:*)" \
    < "${TMPDIR}/step1_prompt.md" \
    2>> "$LOG_FILE" || true

# features.txtが生成されたか確認
if [[ ! -f "$FEATURES_PATH" ]]; then
    log "  WARNING: features.txt not created, using fallback"
    echo "なし" > "$FEATURES_PATH"
fi

FEATURES="$(cat "$FEATURES_PATH")"
log "  Extracted features: $(echo "$FEATURES" | head -5)"

##############################################################################
# Step 2: 機能ごとにX検索 (Grok x_search)
##############################################################################

log "[Step 2] Searching X/Twitter per feature..."

X_SEARCH_RESULTS=""

if [[ "$FEATURES" == "なし" || -z "$FEATURES" ]]; then
    log "  No features to search, skipping X search"
    X_SEARCH_RESULTS="(新機能なし — X検索スキップ)"
elif [[ -z "${XAI_API_KEY:-}" ]]; then
    log "  WARNING: XAI_API_KEY not set, skipping X search"
    X_SEARCH_RESULTS="(X検索スキップ: APIキー未設定)"
else
    PROMPT_TEMPLATE="$(yq -r ".channels.${CHANNEL}.x_search.prompt_template" "$CONFIG_FILE")"
    WEEK_AGO="$(date -d '7 days ago' +%Y-%m-%d)"

    # features.txtの各行を処理
    while IFS= read -r line; do
        # "- 機能名: 説明" の形式をパース
        line="$(echo "$line" | sed 's/^[[:space:]]*-[[:space:]]*//')"
        [[ -z "$line" ]] && continue

        FEATURE_NAME="${line%%:*}"
        FEATURE_DESC="${line#*: }"
        [[ "$FEATURE_NAME" == "$FEATURE_DESC" ]] && FEATURE_DESC=""

        log "  X search: ${FEATURE_NAME}"

        # プロンプトテンプレートに機能名を埋め込み
        search_prompt="${PROMPT_TEMPLATE}"
        search_prompt="${search_prompt//\{\{FEATURE_NAME\}\}/$FEATURE_NAME}"
        search_prompt="${search_prompt//\{\{FEATURE_DESCRIPTION\}\}/$FEATURE_DESC}"

        response="$(curl -s --max-time 60 https://api.x.ai/v1/responses \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer ${XAI_API_KEY}" \
            -d "$(jq -n \
                --arg prompt "$search_prompt" \
                --arg from_date "$WEEK_AGO" \
                '{
                    model: "grok-4-1-fast",
                    input: [{role: "user", content: $prompt}],
                    tools: [{type: "x_search", from_date: $from_date}]
                }'
            )" 2>/dev/null || echo "")"

        text=""
        if [[ -n "$response" ]]; then
            text="$(echo "$response" | jq -r \
                '.output[] | select(.type=="message") | .content[] | select(.type=="output_text") | .text' \
                2>/dev/null || echo "")"
        fi

        if [[ -z "$text" ]]; then
            text="(検索結果なし)"
            log "  WARNING: No results for ${FEATURE_NAME}"
        fi

        X_SEARCH_RESULTS+="
### ${FEATURE_NAME}
${text}
"
    done < "$FEATURES_PATH"
fi

echo "$X_SEARCH_RESULTS" > "${TMPDIR}/x_search_results.txt"

##############################################################################
# Step 3: 最終レポート生成 (claude -p)
##############################################################################

log "[Step 3] Generating final report..."

OUTPUT_PATH="${REPORTS_DIR}/src/content/reports/${DATE}-${CHANNEL}.md"
mkdir -p "$(dirname "$OUTPUT_PATH")"

# 前回レポート取得
PREV_FILE="$(ls -t "${REPORTS_DIR}/src/content/reports/"*"-${CHANNEL}.md" 2>/dev/null | head -1 || echo "")"
if [[ -n "${PREV_FILE:-}" && -f "$PREV_FILE" ]]; then
    log "  Previous report: ${PREV_FILE}"
    head -c 20000 "$PREV_FILE" > "${TMPDIR}/previous_report.txt"
else
    log "  No previous report"
    echo "(前回レポートなし — 初回生成)" > "${TMPDIR}/previous_report.txt"
fi

# プロンプト構築
cat "${SYSTEM_DIR}/prompts/trend-research.md" > "${TMPDIR}/step3_template.md"

echo "$CHANNEL_NAME" > "${TMPDIR}/val_channel_name.txt"
echo "$CHANNEL" > "${TMPDIR}/val_channel_id.txt"
echo "$DATE" > "${TMPDIR}/val_date.txt"
echo "$OUTPUT_PATH" > "${TMPDIR}/val_output_path.txt"

render_template "${TMPDIR}/step3_template.md" "${TMPDIR}/step3_prompt.md" \
    "CHANNEL_NAME=${TMPDIR}/val_channel_name.txt" \
    "CHANNEL_ID=${TMPDIR}/val_channel_id.txt" \
    "DATE=${TMPDIR}/val_date.txt" \
    "OUTPUT_PATH=${TMPDIR}/val_output_path.txt" \
    "RSS_DATA=${TMPDIR}/official_rss.txt" \
    "FEATURES=${TMPDIR}/features.txt" \
    "X_SEARCH_DATA=${TMPDIR}/x_search_results.txt" \
    "COMMUNITY_RSS=${TMPDIR}/community_rss.txt" \
    "PREVIOUS_REPORT=${TMPDIR}/previous_report.txt"

log "  Calling claude -p for report generation..."
claude -p \
    --max-turns 15 \
    --allowedTools "Read" "Write" "Bash(curl:*)" \
    < "${TMPDIR}/step3_prompt.md" \
    2>> "$LOG_FILE"

# 出力確認
if [[ ! -f "$OUTPUT_PATH" ]]; then
    log "ERROR: Report file was not created at ${OUTPUT_PATH}"
    exit 1
fi

FILE_SIZE="$(stat -c%s "$OUTPUT_PATH")"
if [[ "$FILE_SIZE" -lt 200 ]]; then
    log "WARNING: Report file is suspiciously small (${FILE_SIZE} bytes)"
fi

log "  Report generated: ${OUTPUT_PATH} (${FILE_SIZE} bytes)"

##############################################################################
# Step 4: git push (Astroビルド・デプロイはGitHub Actionsが担当)
##############################################################################

log "[Step 4] Publishing..."

# git commit & push
cd "$REPORTS_DIR"
git add -A
if git diff --cached --quiet; then
    log "  No changes to commit"
else
    git commit -m "Report: ${CHANNEL_NAME} ${DATE}"
    git push origin main 2>> "$LOG_FILE" || log "  WARNING: git push failed"
    log "  Pushed to trend-reports"
fi

log "=== Done: ${CHANNEL_NAME} (${CHANNEL}) ==="
