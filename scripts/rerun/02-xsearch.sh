#!/usr/bin/env bash
##############################################################################
# 02-xsearch.sh — Step 2: features.txt の各機能について xAI Grok の x_search で
# 直近 N 日分の X 反応を集める。
#
# Usage:
#   ./02-xsearch.sh --channel <id> --workdir <path> [--date YYYY-MM-DD]
#
# Inputs:
#   --channel    keywords.yml のチャネル ID
#   --workdir    ${workdir}/features.txt が必要 (Step 1 相当を手書きする)
#   --date       検索ウィンドウの基準日 (default: today)。実際の from_date は
#                date - 7日。run.sh は常に今日基準だが rerun は過去日の再生成
#                を想定するため日付指定を受ける。
#
# Output:
#   ${workdir}/x_search_results.txt
##############################################################################

set -euo pipefail

LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_lib.sh
source "${LIB_DIR}/_lib.sh"

CHANNEL=""
WORKDIR=""
BASE_DATE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --channel) CHANNEL="$2"; shift 2 ;;
        --workdir) WORKDIR="$2"; shift 2 ;;
        --date)    BASE_DATE="$2"; shift 2 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[[ -z "$CHANNEL" ]] && die "--channel is required"
[[ -z "$WORKDIR" ]] && die "--workdir is required"
mkdir -p "$WORKDIR"
WORKDIR="$(cd "$WORKDIR" && pwd)"
BASE_DATE="${BASE_DATE:-$(date +%Y-%m-%d)}"

FEATURES_PATH="${WORKDIR}/features.txt"
OUTPUT_PATH="${WORKDIR}/x_search_results.txt"

[[ ! -f "$FEATURES_PATH" ]] && die "features.txt not found at ${FEATURES_PATH}"

load_channel "$CHANNEL"

log "[02-xsearch] ${CHANNEL_NAME} (${CHANNEL}) base_date=${BASE_DATE}"

FEATURES="$(cat "$FEATURES_PATH")"
X_SEARCH_RESULTS=""

X_SEARCH_ENABLED="$(yq -r ".channels.${CHANNEL}.x_search.enabled" "$CONFIG_FILE")"
[[ "$X_SEARCH_ENABLED" == "null" ]] && X_SEARCH_ENABLED="true"

if [[ "$X_SEARCH_ENABLED" == "false" ]]; then
    log "  X search disabled for this channel, skipping"
    X_SEARCH_RESULTS="(X検索無効 — スキップ)"
elif [[ "$FEATURES" == "なし" || -z "$FEATURES" ]]; then
    log "  No features to search, skipping X search"
    X_SEARCH_RESULTS="(新機能なし — X検索スキップ)"
elif [[ -z "${XAI_API_KEY:-}" ]]; then
    log "  WARNING: XAI_API_KEY not set, skipping X search"
    X_SEARCH_RESULTS="(X検索スキップ: APIキー未設定)"
else
    PROMPT_TEMPLATE="$(yq -r ".channels.${CHANNEL}.x_search.prompt_template" "$CONFIG_FILE")"
    FROM_DATE="$(date -d "${BASE_DATE} - 7 days" +%Y-%m-%d)"
    log "  x_search from_date=${FROM_DATE}"

    while IFS= read -r line; do
        line="$(echo "$line" | sed 's/^[[:space:]]*-[[:space:]]*//')"
        [[ -z "$line" ]] && continue

        FEATURE_NAME="${line%%:*}"
        FEATURE_DESC="${line#*: }"
        [[ "$FEATURE_NAME" == "$FEATURE_DESC" ]] && FEATURE_DESC=""

        log "  X search: ${FEATURE_NAME}"

        search_prompt="${PROMPT_TEMPLATE}"
        search_prompt="${search_prompt//\{\{FEATURE_NAME\}\}/$FEATURE_NAME}"
        search_prompt="${search_prompt//\{\{FEATURE_DESCRIPTION\}\}/$FEATURE_DESC}"

        response="$(curl -s --max-time 60 https://api.x.ai/v1/responses \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer ${XAI_API_KEY}" \
            -d "$(jq -n \
                --arg prompt "$search_prompt" \
                --arg from_date "$FROM_DATE" \
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

echo "$X_SEARCH_RESULTS" > "$OUTPUT_PATH"
log "[02-xsearch] done — ${OUTPUT_PATH}"
