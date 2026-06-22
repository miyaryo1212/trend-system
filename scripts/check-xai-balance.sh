#!/usr/bin/env bash
##############################################################################
# check-xai-balance.sh — xAI prepaid クレジット残高の監視 → Slack 通知
#
# trend-system は Step 2 (X検索) で xAI Grok API (grok-4-1-fast / x_search) を
# 従量で消費する。クレジットが尽きると x_search が静かに失敗し、レポートから
# SNS反応が欠落する。本スクリプトは毎朝 prepaid 残高を取得し、
#   - 通常時: 残高1行を Slack に通知 (ハートビート)
#   - 閾値未満: @メンション付きで警告
# を行う。
#
# 必要な環境変数 (~/.env.agent):
#   XAI_MANAGEMENT_KEY   … xAI Management API キー (推論用 XAI_API_KEY とは別物)
#                          console.x.ai → Settings → Management Keys で発行
# 任意:
#   XAI_TEAM_ID                … 未設定なら management key から自動解決
#   XAI_BALANCE_THRESHOLD_USD  … 警告閾値 (デフォルト 3)
#   SLACK_WEBHOOK_FILE         … デフォルト ~/.claude/slack-webhook
##############################################################################
set -uo pipefail
export TZ=Asia/Tokyo

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYSTEM_DIR="$(dirname "$SCRIPT_DIR")"

# --- 環境設定の読み込み (.env.local > ~/.env.agent) ---
if [[ -f "${SYSTEM_DIR}/.env.local" ]]; then
    # shellcheck disable=SC1091
    source "${SYSTEM_DIR}/.env.local"
elif [[ -f "${HOME}/.env.agent" ]]; then
    # shellcheck disable=SC1090
    source "${HOME}/.env.agent"
fi

THRESHOLD_USD="${XAI_BALANCE_THRESHOLD_USD:-3}"
MGMT_BASE="https://management-api.x.ai"
WEBHOOK_FILE="${SLACK_WEBHOOK_FILE:-$HOME/.claude/slack-webhook}"
MID_FILE="$HOME/.claude/slack-member-id"

log() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }

# --- Slack 投稿 ---
slack() {
    local text="$1"
    if [[ ! -r "$WEBHOOK_FILE" ]]; then
        log "WARN: Slack webhook が読めません ($WEBHOOK_FILE) — 通知スキップ"
        return 0
    fi
    local hook
    hook="$(tr -d '[:space:]' < "$WEBHOOK_FILE")"
    [[ -n "$hook" ]] || { log "WARN: webhook が空 — 通知スキップ"; return 0; }
    curl -fsS --max-time 10 -X POST -H 'Content-Type: application/json' \
        --data "$(jq -n --arg t "$text" '{text:$t}')" "$hook" >/dev/null 2>&1 \
        || log "WARN: Slack 投稿に失敗"
}

mention() {
    [[ -r "$MID_FILE" ]] || return 0
    local mid
    mid="$(tr -d '[:space:]' < "$MID_FILE")"
    [[ -n "$mid" ]] && printf '<@%s> ' "$mid"
}

# --- 前提チェック ---
if [[ -z "${XAI_MANAGEMENT_KEY:-}" ]]; then
    log "ERROR: XAI_MANAGEMENT_KEY が未設定です"
    slack ":warning: xAI残高監視: XAI_MANAGEMENT_KEY が未設定です（~/.env.agent を確認）"
    exit 1
fi

AUTH_HEADER="Authorization: Bearer ${XAI_MANAGEMENT_KEY}"

# --- 1. team_id の解決 (環境変数優先、無ければ management key から取得) ---
TEAM_ID="${XAI_TEAM_ID:-}"
if [[ -z "$TEAM_ID" ]]; then
    val_resp="$(curl -fsS --max-time 20 -H "$AUTH_HEADER" \
        "${MGMT_BASE}/auth/management-keys/validation" 2>/dev/null || true)"
    TEAM_ID="$(jq -r '.teamId // .team_id // .scopeId // empty' <<<"$val_resp" 2>/dev/null)"
fi
if [[ -z "$TEAM_ID" ]]; then
    log "ERROR: team_id を解決できませんでした。validation resp: ${val_resp:-<none>}"
    slack ":warning: xAI残高監視: team_id を取得できませんでした（management key を確認してください）"
    exit 1
fi
log "team_id=${TEAM_ID}"

# --- 2. 残高の取得 ---
# xAI の符号規約: prepaid クレジット(=残高)は「負の cents」で記録され、消費すると
# 0 に近づく(0 以上 = 枯渇)。よって プール(cents) = -1 * val。
#
# リアルタイム残高 = invoice/preview のプール (coreInvoice.prepaidCredits) から
# 当サイクル(今月)消費 (coreInvoice.prepaidCreditsUsed) を差し引いて求める。
#   - prepaidCredits 単体は月次でしか動かない (SPEND 計上がサイクル締めのため)。
#     これだけ見ると月内ずっと不動で実消費を取りこぼす (2026-06 の不具合: $12.82 に固着)。
#   - prepaid/balance.total も月次確定でラグするためフォールバック専用。
prev_resp="$(curl -fsS --max-time 20 -H "$AUTH_HEADER" \
    "${MGMT_BASE}/v1/billing/teams/${TEAM_ID}/postpaid/invoice/preview" 2>/dev/null || true)"
pc="$(jq -r '.coreInvoice.prepaidCredits.val // .prepaidCredits.val // empty' \
    <<<"$prev_resp" 2>/dev/null)"
# 当サイクル消費 (負値; 例 -535 = $5.35 消費)。欠落時は 0 扱い。
used="$(jq -r '.coreInvoice.prepaidCreditsUsed.val // 0' <<<"$prev_resp" 2>/dev/null)"
[[ "$used" =~ ^-?[0-9]+$ ]] || used=0

# フォールバック用に台帳合計も取得 (ラグあり、ログ表示にも使う)
bal_resp="$(curl -fsS --max-time 20 -H "$AUTH_HEADER" \
    "${MGMT_BASE}/v1/billing/teams/${TEAM_ID}/prepaid/balance" 2>/dev/null || true)"
ledger="$(jq -r '.total.val // empty' <<<"$bal_resp" 2>/dev/null)"
# 直近のオートチャージ(PURCHASE)が失敗していないか (枯渇の予兆検知)
last_topup="$(jq -r '[.changes[]? | select(.changeOrigin=="PURCHASE")] | sort_by(.createTs) | last | .topupStatus // empty' <<<"$bal_resp" 2>/dev/null)"

src="invoice/preview"
raw="$pc"
if ! [[ "$raw" =~ ^-?[0-9]+$ ]]; then
    src="prepaid/balance(total,lagging)"
    raw="$ledger"
    used=0   # フォールバックの台帳合計は当サイクル消費を含まないため差し引かない
fi
if ! [[ "$raw" =~ ^-?[0-9]+$ ]]; then
    log "ERROR: 残高をパースできませんでした。preview=${prev_resp:-<none>} balance=${bal_resp:-<none>}"
    slack ":warning: xAI残高監視: 残高のパースに失敗しました（APIレスポンス形式が変わった可能性）"
    exit 1
fi

# 残高 = プール(-1*raw) + 当サイクル消費(used は負値)  例: -1*(-1282) + (-535) = 747 = $7.47
remaining_cents=$(( -1 * raw + used ))
usd="$(awk "BEGIN{printf \"%.2f\", ${remaining_cents}/100}")"
log "remaining=\$${usd} (${remaining_cents}c via ${src}; pool.pc=${pc:-NA} used=${used} ledger.total=${ledger:-NA} last_topup=${last_topup:-NA}), threshold=\$${THRESHOLD_USD}"

# --- 3. 通知 (Both: 通常はハートビート、閾値未満で警告) ---
if awk "BEGIN{exit !(${remaining_cents} < ${THRESHOLD_USD}*100)}"; then
    slack ":rotating_light: $(mention)xAIクレジット残高が少なくなっています: *\$${usd}* (閾値 \$${THRESHOLD_USD})
→ console.x.ai でチャージしてください"
    log "LOW balance alert sent"
else
    slack ":white_check_mark: xAIクレジット残高: *\$${usd}*"
    log "heartbeat sent"
fi

# --- 4. オートチャージ失敗の警告 (残高とは独立した予兆アラート) ---
if [[ "$last_topup" == "FAILED_TO_CHARGE" ]]; then
    slack ":warning: $(mention)xAI: 直近のクレジット自動チャージが失敗しています (topupStatus=FAILED_TO_CHARGE)
→ console.x.ai の支払い方法を確認してください"
    log "WARN: last auto top-up FAILED_TO_CHARGE"
fi
