#!/usr/bin/env bash
set -euo pipefail

# Reports are dated in JST; pin all date commands to Asia/Tokyo so the
# filename and log timestamps line up even if the host is in another TZ.
export TZ=Asia/Tokyo

##############################################################################
# run.sh — トレンド調査レポート生成 (2段階パイプライン)
#
# Usage: ./scripts/run.sh [--dry-run] <channel-id>
#   例: ./scripts/run.sh claude-anthropic
#       ./scripts/run.sh --dry-run codex-openai
#
# Options:
#   --dry-run  Step 0-2 を実行し、収集データをコンソールに出力して終了
#              (レポート生成・git push は行わない)
#
# Pipeline:
#   Step 0:   RSSフィード取得 (curl)
#   Step 1:   新機能・トピック抽出 (claude -p, コスト$0)
#   Step 2:   機能ごとにX検索 (Grok x_search, ~$0.02/機能)
#   Step 3:   最終レポート生成 (claude -p, コスト$0)
#   Step 3.5: Codex レビュー注入 (codex exec, サブスク枠内, 任意)
#   Step 3.6: frontmatter YAML 静的解析 (失敗時 claude -p で修正)
#   Step 4:   index.html再生成 + git push
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

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
    shift
fi

CHANNEL="${1:-}"
if [[ -z "$CHANNEL" ]]; then
    echo "Usage: $0 [--dry-run] <channel-id>" >&2
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

fetch_sitemap_diff() {
    local name="$1"       # キャッシュキー (例: "anthropic", "openai-product")
    local urls="$2"       # 改行区切りのサイトマップURL
    local exclude="$3"    # grep -E 除外パターン (空文字なら除外なし)

    local cache_dir="${SYSTEM_DIR}/cache/sitemap"
    local cache_file="${cache_dir}/${name}.tsv"
    local current_file="${TMPDIR}/sitemap_${name}_current.tsv"

    mkdir -p "$cache_dir"

    # 全サイトマップからURL+lastmodペアを抽出
    > "$current_file"
    while IFS= read -r sitemap_url; do
        [[ -z "$sitemap_url" ]] && continue
        curl -sL --max-time 15 "$sitemap_url" 2>/dev/null | \
            python3 -c "
import sys, xml.etree.ElementTree as ET
try:
    tree = ET.parse(sys.stdin)
    ns = {'s': 'http://www.sitemaps.org/schemas/sitemap/0.9'}
    for url_elem in tree.findall('.//s:url', ns):
        loc = url_elem.find('s:loc', ns)
        lastmod = url_elem.find('s:lastmod', ns)
        if loc is not None:
            print(f'{loc.text}\t{lastmod.text if lastmod is not None else \"\"}')
except Exception:
    pass
" >> "$current_file" 2>/dev/null || true
    done <<< "$urls"

    # 多言語版を除外 (OpenAIの /ja-JP/ 等)
    grep -vE '/[a-z]{2}-[A-Z]{2}/' "$current_file" > "${current_file}.tmp" 2>/dev/null \
        && mv "${current_file}.tmp" "$current_file" || true

    # ユーザ指定の除外パターン
    if [[ -n "$exclude" ]]; then
        grep -vE "$exclude" "$current_file" > "${current_file}.tmp" 2>/dev/null \
            && mv "${current_file}.tmp" "$current_file" || true
    fi

    # キャッシュとの差分検出
    local new_urls=""
    if [[ -f "$cache_file" ]]; then
        # 新規行 or lastmod が変わった行 → URL を抽出
        new_urls="$(comm -23 <(sort "$current_file") <(sort "$cache_file") | cut -f1)"
    else
        # 初回: lastmod が直近48時間以内のURLのみ
        new_urls="$(python3 -c "
import sys
from datetime import datetime, timedelta, timezone
cutoff = datetime.now(timezone.utc) - timedelta(hours=48)
for line in sys.stdin:
    parts = line.strip().split('\t')
    if len(parts) >= 2 and parts[1]:
        try:
            dt = datetime.fromisoformat(parts[1].replace('Z', '+00:00'))
            if dt > cutoff:
                print(parts[0])
        except Exception:
            pass
" < "$current_file")"
    fi

    # キャッシュ更新
    cp "$current_file" "$cache_file"

    echo "$new_urls"
}

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

fetch_json_api() {
    local url="$1"
    local name="$2"
    local max_size="${3:-80000}"

    log "  JSON API: ${name}"
    local tmpfile="${TMPDIR}/api_$(date +%s%N).json"
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

    # JSONを読みやすい形式に変換 (タイトル、著者、概要)
    jq -r '.[] | "Title: \(.paper.title)\nAuthors: \(.paper.authors // [] | map(.name // .user // "") | join(", "))\nSummary: \(.paper.summary // "N/A" | .[0:300])\nUpvotes: \(.paper.upvotes // 0)\n"' \
        "$tmpfile" 2>/dev/null | head -c "$max_size" || head -c "$max_size" "$tmpfile"
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

# 公式ソース (RSS取得 + web_searchクエリ収集 + サイトマップ差分)
OFFICIAL_RSS=""
WEB_SEARCH_QUERIES=""
SITEMAP_NEW_PAGES=""
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
    elif [[ "$src_type" == "json_api" ]]; then
        src_url="$(yq -r ".channels.${CHANNEL}.official_sources[${i}].url" "$CONFIG_FILE")"
        OFFICIAL_RSS+="
--- ${src_name} ---
$(fetch_json_api "$src_url" "$src_name")
"
    elif [[ "$src_type" == "sitemap" ]]; then
        src_urls="$(yq -r ".channels.${CHANNEL}.official_sources[${i}].urls[]" "$CONFIG_FILE")"
        src_exclude="$(yq -r ".channels.${CHANNEL}.official_sources[${i}].exclude_patterns // \"\"" "$CONFIG_FILE")"
        cache_key="${CHANNEL}-$(echo "$src_name" | tr ' ' '-' | tr '[:upper:]' '[:lower:]')"
        log "  Sitemap: ${src_name} (cache: ${cache_key})"
        sitemap_new="$(fetch_sitemap_diff "$cache_key" "$src_urls" "$src_exclude")"
        if [[ -n "$sitemap_new" ]]; then
            new_count="$(echo "$sitemap_new" | wc -l)"
            log "  Sitemap: ${new_count} new/updated pages found"
            SITEMAP_NEW_PAGES+="
--- ${src_name}: 新規・更新ページ ---
${sitemap_new}
"
        else
            log "  Sitemap: no new pages"
        fi
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
echo "$SITEMAP_NEW_PAGES" > "${TMPDIR}/sitemap_new_pages.txt"

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
    "SITEMAP_NEW_PAGES=${TMPDIR}/sitemap_new_pages.txt" \
    "WEB_SEARCH_QUERIES=${TMPDIR}/web_search_queries.txt" \
    "FEATURES_PATH=${TMPDIR}/val_features_path.txt"

log "  Calling claude -p for feature extraction..."
claude -p \
    --max-turns 6 \
    --allowedTools "Read" "Write" "Bash(curl:*)" "WebSearch" "WebFetch" \
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

# X検索が無効化されているチャネルはスキップ
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

# ---- dry-run: 収集データを出力して終了 ----

if [[ "$DRY_RUN" == true ]]; then
    echo ""
    echo "========== DRY RUN: ${CHANNEL_NAME} (${DATE}) =========="
    echo ""
    echo "--- Features (Step 1) ---"
    cat "$FEATURES_PATH"
    echo ""
    echo "--- X Search Results (Step 2) ---"
    cat "${TMPDIR}/x_search_results.txt"
    echo ""
    echo "--- Sitemap New Pages ---"
    cat "${TMPDIR}/sitemap_new_pages.txt"
    echo ""
    echo "--- Official RSS (${#OFFICIAL_RSS} chars) ---"
    echo "$OFFICIAL_RSS" | head -50
    echo ""
    echo "--- Community RSS (${#COMMUNITY_RSS} chars) ---"
    echo "$COMMUNITY_RSS" | head -50
    echo ""
    echo "--- Web Search Queries ---"
    cat "${TMPDIR}/web_search_queries.txt"
    echo ""
    echo "========== END DRY RUN =========="
    log "=== Dry run complete ==="
    exit 0
fi

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

# プロンプト構築 (チャネル専用テンプレートがあればそちらを使用)
STEP3_TEMPLATE="${SYSTEM_DIR}/prompts/trend-research-${CHANNEL}.md"
if [[ ! -f "$STEP3_TEMPLATE" ]]; then
    STEP3_TEMPLATE="${SYSTEM_DIR}/prompts/trend-research.md"
fi
cat "$STEP3_TEMPLATE" > "${TMPDIR}/step3_template.md"

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
    --allowedTools "Read" "Write" "Bash(curl:*)" "WebSearch" "WebFetch" \
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
# Step 3.5: Codex レビュー (任意 — codex CLI が無ければスキップ)
##############################################################################

if command -v codex >/dev/null 2>&1; then
    log "[Step 3.5] Generating Codex review..."

    CODEX_PROMPT="${TMPDIR}/codex_prompt.md"
    awk -v f="$OUTPUT_PATH" '
        /{{REPORT}}/ {
            while ((getline line < f) > 0) print line
            close(f)
            next
        }
        { print }
    ' "${SYSTEM_DIR}/prompts/codex-review.md" > "$CODEX_PROMPT"

    CODEX_OUTPUT="${TMPDIR}/codex_output.txt"
    if codex exec --skip-git-repo-check - < "$CODEX_PROMPT" > "$CODEX_OUTPUT" 2>>"$LOG_FILE"; then
        # ANSI カラー除去 + 外側 { から } までを抽出
        CLEAN_JSON="${TMPDIR}/codex_review.json"
        sed 's/\x1b\[[0-9;]*m//g' "$CODEX_OUTPUT" | awk '/^\{/,/^\}/' > "$CLEAN_JSON"

        if [[ -s "$CLEAN_JSON" ]] && jq empty "$CLEAN_JSON" 2>/dev/null; then
            CODEX_REVIEW_TEXT="$(jq -r '.review // ""' "$CLEAN_JSON")"
            CODEX_IMP="$(jq -r '.importance // empty' "$CLEAN_JSON")"

            if [[ -n "$CODEX_REVIEW_TEXT" ]]; then
                log "  Codex: \"${CODEX_REVIEW_TEXT}\" (★${CODEX_IMP:-?})"

                # frontmatter に 2 フィールド注入 (閉じ `---` の直前)
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
                ' "$OUTPUT_PATH" > "${OUTPUT_PATH}.tmp" && mv "${OUTPUT_PATH}.tmp" "$OUTPUT_PATH"
                log "  Injected codex_review + codex_importance"
            else
                log "  WARNING: codex returned empty review"
            fi
        else
            log "  WARNING: codex output did not contain valid JSON"
            log "  --- codex raw output ---"
            cat "$CODEX_OUTPUT" >> "$LOG_FILE"
        fi
    else
        log "  WARNING: codex exec failed"
    fi
else
    log "[Step 3.5] codex CLI not found, skipping Codex review"
fi

##############################################################################
# Step 3.6: frontmatter YAML 静的解析 (失敗時は claude -p で修正)
##############################################################################
#
# 過去事例 (2026-04-26): Step 3 のClaudeが frontmatter に codex_review を勝手に
# 書いた状態で Step 3.5 awk が同キーをもう1組注入し、duplicate-key で CF Pages
# のビルドが失敗した。Astro/js-yaml と等価な strict パース (重複キー検出) を
# 注入後の最終状態にかけ、壊れていれば claude -p で修正してリトライする。

log "[Step 3.6] Validating frontmatter YAML..."

VALIDATOR="${SYSTEM_DIR}/scripts/validate-frontmatter.py"
VALIDATE_OUT="${TMPDIR}/frontmatter_validate.txt"

if python3 "$VALIDATOR" "$OUTPUT_PATH" > "$VALIDATE_OUT" 2>&1; then
    log "  Frontmatter YAML: OK"
else
    log "  Frontmatter YAML: INVALID"
    while IFS= read -r line; do log "    | $line"; done < "$VALIDATE_OUT"
    log "  Falling back to claude -p for repair..."

    REPAIR_PROMPT="${TMPDIR}/yaml_repair_prompt.md"
    {
        echo "次のMarkdownレポートのfrontmatter (先頭の \`---\` で囲まれたYAML部分) に構文エラーがあります。\`Edit\` ツールで in-place 修正してください。"
        echo
        echo "- ファイル: ${OUTPUT_PATH}"
        echo "- バリデータ出力:"
        echo
        echo '```'
        cat "$VALIDATE_OUT"
        echo '```'
        echo
        echo "修正ルール:"
        echo "1. **frontmatter (先頭の \`---\` 〜 直後の \`---\` の間) のみ** を修正する。本文には触れない。"
        echo "2. **重複キー** がある場合は **末尾側 (閉じ \`---\` に近い方)** を残す。後段で自動注入された値が末尾側であり、これをシステムの正と扱う。"
        echo "3. それ以外のYAMLエラー (引用符・インデント等) は最小限の編集で修正する。"
        echo "4. 修正後はそのターンで終了すること。"
    } > "$REPAIR_PROMPT"

    claude -p \
        --max-turns 5 \
        --allowedTools "Read" "Edit" \
        < "$REPAIR_PROMPT" \
        2>> "$LOG_FILE" || true

    if python3 "$VALIDATOR" "$OUTPUT_PATH" > "$VALIDATE_OUT" 2>&1; then
        log "  Frontmatter YAML: REPAIRED by claude -p"
    else
        log "  ERROR: Frontmatter YAML still invalid after claude repair:"
        while IFS= read -r line; do log "    | $line"; done < "$VALIDATE_OUT"
        exit 1
    fi
fi

##############################################################################
# Step 4: git push (Astroビルド・デプロイはGitHub Actionsが担当)
##############################################################################

log "[Step 4] Publishing..."

# git commit & push
cd "$REPORTS_DIR"
git pull --rebase origin main 2>> "$LOG_FILE" || log "  WARNING: git pull --rebase failed"
git add -A
if git diff --cached --quiet; then
    log "  No changes to commit"
else
    git commit -m "Report: ${CHANNEL_NAME} ${DATE}"
    git push origin main 2>> "$LOG_FILE" || log "  WARNING: git push failed"
    log "  Pushed to trend-reports"
fi

log "=== Done: ${CHANNEL_NAME} (${CHANNEL}) ==="
