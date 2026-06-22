#!/usr/bin/env bash
##############################################################################
# check-claude-auth.sh — Claude Code (claude -p) OAuth 認証ヘルスチェック → Slack
#
# trend-system の全チャンネルは Step 1/3 で `claude -p` を使う。OAuth トークンが
# 失効しリフレッシュも切れると各チャンネルが 401 で停止する (2026-06-20→22 に
# 5チャンネルが2日間無言で停止した事故)。本スクリプトは毎朝 CH1 (06:00) の前に
# 認証を probe し、失効していれば Slack に @メンション付きで警告する。
#
# 通常は check-xai-balance.sh (05:50 timer) の末尾から呼ばれる。単体実行も可。
# 任意環境変数: SLACK_WEBHOOK_FILE (default ~/.claude/slack-webhook)
##############################################################################
set -uo pipefail
export TZ=Asia/Tokyo

WEBHOOK_FILE="${SLACK_WEBHOOK_FILE:-$HOME/.claude/slack-webhook}"
MID_FILE="$HOME/.claude/slack-member-id"
CRED="$HOME/.claude/.credentials.json"

log() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }

slack() {
    local text="$1"
    [[ -r "$WEBHOOK_FILE" ]] || { log "WARN: webhook unreadable ($WEBHOOK_FILE) — skip"; return 0; }
    local hook; hook="$(tr -d '[:space:]' < "$WEBHOOK_FILE")"
    [[ -n "$hook" ]] || { log "WARN: webhook empty — skip"; return 0; }
    curl -fsS --max-time 10 -X POST -H 'Content-Type: application/json' \
        --data "$(jq -n --arg t "$text" '{text:$t}')" "$hook" >/dev/null 2>&1 \
        || log "WARN: Slack post failed"
}

mention() {
    [[ -r "$MID_FILE" ]] || return 0
    local mid; mid="$(tr -d '[:space:]' < "$MID_FILE")"
    [[ -n "$mid" ]] && printf '<@%s> ' "$mid"
}

# claude バイナリ解決 (systemd の PATH と同じ場所も探す)
CLAUDE_BIN="$(command -v claude || true)"
[[ -z "$CLAUDE_BIN" && -x "$HOME/.local/bin/claude" ]] && CLAUDE_BIN="$HOME/.local/bin/claude"
if [[ -z "$CLAUDE_BIN" ]]; then
    log "ERROR: claude binary not found"
    slack ":warning: $(mention)Claude認証監視: claude バイナリが見つかりません (orion)。"
    exit 0
fi

# --- 認証 probe ---
PROBE="$(printf 'reply with: ok' | timeout 60 "$CLAUDE_BIN" -p 2>&1 || true)"
if printf '%s' "$PROBE" | grep -qiE 'authentication_error|Invalid authentication credentials|Failed to authenticate|\b401\b'; then
    log "AUTH FAILED: ${PROBE:0:200}"
    slack ":rotating_light: $(mention)Claude Code の認証が切れています (orion)。このままだと trend-system の全チャンネル(06:00〜)が停止します。
→ orion で \`claude\` を起動し \`/login\` で再ログインしてください。"
    exit 0
fi

# --- probe 成功: 参考までにトークン残り時間をログ (Slack には出さない) ---
if [[ -r "$CRED" ]]; then
    EXP_MS="$(jq -r '.claudeAiOauth.expiresAt // empty' "$CRED" 2>/dev/null)"
    if [[ "$EXP_MS" =~ ^[0-9]+$ ]]; then
        now_ms=$(( $(date +%s) * 1000 ))
        left_h=$(( (EXP_MS - now_ms) / 3600000 ))
        log "auth OK (probe passed; token expires in ~${left_h}h)"
    else
        log "auth OK (probe passed; expiresAt unparseable)"
    fi
else
    log "auth OK (probe passed; no credentials file)"
fi
