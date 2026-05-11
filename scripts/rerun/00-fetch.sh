#!/usr/bin/env bash
##############################################################################
# 00-fetch.sh — Step 0: RSS / sitemap / JSON API / web_search 候補の取得
#
# Usage:
#   ./00-fetch.sh --channel <channel-id> --workdir <path> [--sitemap-readonly]
#
# Inputs:
#   --channel            keywords.yml の channels.* のキー
#   --workdir            ステップ間で共有する作業ディレクトリ
#   --sitemap-readonly   サイトマップ差分検出のキャッシュを更新しない
#                        (本番 cron の差分検出を rerun が消費しないようにする)
#
# Outputs (workdir 配下):
#   official_rss.txt        公式ソースの RSS / JSON API / sitemap 連結
#   community_rss.txt       コミュニティソースの RSS 連結
#   web_search_queries.txt  web_search 型ソースのクエリ一覧
#   sitemap_new_pages.txt   サイトマップ差分で検出された新規 URL 一覧
##############################################################################

set -euo pipefail

LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_lib.sh
source "${LIB_DIR}/_lib.sh"

CHANNEL=""
SITEMAP_READONLY="0"
WORKDIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --channel) CHANNEL="$2"; shift 2 ;;
        --workdir) WORKDIR="$2"; shift 2 ;;
        --sitemap-readonly) SITEMAP_READONLY="1"; shift ;;
        *) die "unknown argument: $1" ;;
    esac
done

[[ -z "$CHANNEL" ]] && die "--channel is required"
[[ -z "$WORKDIR" ]] && die "--workdir is required"
mkdir -p "$WORKDIR"
WORKDIR="$(cd "$WORKDIR" && pwd)"

load_channel "$CHANNEL"

# fetch_sitemap_diff / fetch_rss / fetch_json_api は内部で TMPDIR を使う。
# rerun はステップ毎に呼ばれるため TMPDIR を一意化して衝突を避ける。
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

export FETCH_SITEMAP_READONLY="$SITEMAP_READONLY"

log "[00-fetch] ${CHANNEL_NAME} (${CHANNEL}) — readonly=${SITEMAP_READONLY}"

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

echo "$OFFICIAL_RSS"        > "${WORKDIR}/official_rss.txt"
echo "$COMMUNITY_RSS"       > "${WORKDIR}/community_rss.txt"
echo "$WEB_SEARCH_QUERIES"  > "${WORKDIR}/web_search_queries.txt"
echo "$SITEMAP_NEW_PAGES"   > "${WORKDIR}/sitemap_new_pages.txt"

log "[00-fetch] done — outputs written to ${WORKDIR}/"
