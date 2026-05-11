#!/usr/bin/env bash
##############################################################################
# _lib.sh — rerun/ 配下の各ステップスクリプトが source する共通ライブラリ。
#
# 提供するもの:
#   - 環境変数の読み込み (.env.local / ~/.env.agent)
#   - REPO 配下のパス定数 (SYSTEM_DIR, CONFIG_FILE, REPORTS_DIR)
#   - log() / die()
#   - load_channel <channel-id>  — keywords.yml の存在チェック + CHANNEL_NAME 取得
#   - fetch_rss / fetch_json_api / fetch_sitemap_diff — run.sh と同等
#   - render_template — Step 1/3 プロンプト構築用
#
# 各ステップスクリプトは「workdir」を引数で受け取り、入出力ファイルを
# その配下の固定名 (official_rss.txt, features.txt, x_search_results.txt 等)
# に置く。workdir 経由でステップ間の状態を引き渡す。
##############################################################################

set -euo pipefail

# 日時表記の混乱を避けるため、すべての date を JST に固定 (run.sh と同じ)
export TZ=Asia/Tokyo

# このファイルがある場所から system_dir を引く: <SYSTEM_DIR>/scripts/rerun/_lib.sh
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYSTEM_DIR="$(cd "${LIB_DIR}/../.." && pwd)"

# 環境設定ファイルの読み込み
if [[ -f "${SYSTEM_DIR}/.env.local" ]]; then
    # shellcheck disable=SC1091
    source "${SYSTEM_DIR}/.env.local"
elif [[ -f "${HOME}/.env.agent" ]]; then
    # shellcheck disable=SC1091
    source "${HOME}/.env.agent"
fi

REPORTS_DIR="${TREND_REPORTS_DIR:-$(dirname "$SYSTEM_DIR")/trend-reports}"
CONFIG_FILE="${SYSTEM_DIR}/config/keywords.yml"
LOG_DIR="${SYSTEM_DIR}/logs"

mkdir -p "$LOG_DIR"

# ロギング先は呼び出し側で LOG_FILE を export しておけばそこに tee される。
# 未設定なら stdout のみ。
log() {
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    if [[ -n "${LOG_FILE:-}" ]]; then
        echo "[${ts}] $*" | tee -a "$LOG_FILE"
    else
        echo "[${ts}] $*"
    fi
}

die() {
    log "ERROR: $*"
    exit 1
}

load_channel() {
    local channel="$1"
    if ! yq -e ".channels.${channel}" "$CONFIG_FILE" > /dev/null 2>&1; then
        die "Channel '${channel}' not found in ${CONFIG_FILE}"
    fi
    CHANNEL_NAME="$(yq -r ".channels.${channel}.name" "$CONFIG_FILE")"
    export CHANNEL_NAME
}

##############################################################################
# RSS/JSON/sitemap 取得ヘルパ — run.sh から流用 (動作も互換)
##############################################################################

# sitemap キャッシュは run.sh と同じ場所を共有するため、cron 経由の通常
# 実行で差分検出した URL を rerun 側が再消費してしまうことが起きる。
# rerun は基本的に過去日に対する手動再生成なので、cache を更新しない
# 「読み取りだけ」モードを足す。フラグ FETCH_SITEMAP_READONLY=1 を尊重。
fetch_sitemap_diff() {
    local name="$1"
    local urls="$2"
    local exclude="$3"

    local cache_dir="${SYSTEM_DIR}/cache/sitemap"
    local cache_file="${cache_dir}/${name}.tsv"
    local scratch_dir
    scratch_dir="${TMPDIR:-/tmp}"
    local current_file="${scratch_dir}/sitemap_${name}_current.tsv"

    mkdir -p "$cache_dir"

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

    grep -vE '/[a-z]{2}-[A-Z]{2}/' "$current_file" > "${current_file}.tmp" 2>/dev/null \
        && mv "${current_file}.tmp" "$current_file" || true

    if [[ -n "$exclude" ]]; then
        grep -vE "$exclude" "$current_file" > "${current_file}.tmp" 2>/dev/null \
            && mv "${current_file}.tmp" "$current_file" || true
    fi

    local new_urls=""
    if [[ -f "$cache_file" ]]; then
        new_urls="$(comm -23 <(sort "$current_file") <(sort "$cache_file") | cut -f1)"
    else
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

    if [[ "${FETCH_SITEMAP_READONLY:-0}" != "1" ]]; then
        cp "$current_file" "$cache_file"
    fi

    echo "$new_urls"
}

fetch_rss() {
    local url="$1"
    local name="$2"
    local max_size="${3:-50000}"

    log "  RSS: ${name}"
    local tmpfile
    tmpfile="${TMPDIR:-/tmp}/rss_$(date +%s%N).xml"
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
    local tmpfile
    tmpfile="${TMPDIR:-/tmp}/api_$(date +%s%N).json"
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
    jq -r '.[] | "Title: \(.paper.title)\nAuthors: \(.paper.authors // [] | map(.name // .user // "") | join(", "))\nSummary: \(.paper.summary // "N/A" | .[0:300])\nUpvotes: \(.paper.upvotes // 0)\n"' \
        "$tmpfile" 2>/dev/null | head -c "$max_size" || head -c "$max_size" "$tmpfile"
}

render_template() {
    local template_file="$1"
    local output_file="$2"
    shift 2
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
# CLI 引数のパース: 各スクリプトで共通使用する `--workdir <path>` を取り出す
##############################################################################
parse_workdir() {
    # in: 全引数を $@ で渡す。out: stdout に workdir の絶対パス。
    # それ以外のオプションは無視。見つからなければ exit 1。
    local prev=""
    local found=""
    for arg in "$@"; do
        if [[ "$prev" == "--workdir" ]]; then
            found="$arg"
            break
        fi
        prev="$arg"
    done
    if [[ -z "$found" ]]; then
        die "missing required --workdir <path>"
    fi
    mkdir -p "$found"
    (cd "$found" && pwd)
}
