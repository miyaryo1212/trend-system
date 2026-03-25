# タスク1: トレンド調査レポート — 引き継ぎ書

## プロジェクト概要

専用Ubuntu Serverマシン上でClaude Codeを定期実行し、生成AI関連の情報を収集・HTMLレポートとしてGitHub Pagesで公開するシステム。

---

## 経緯

1. 常時稼働マシン(Ryzen 7 PRO 6850H/32GB/Ubuntu Server)でClaude Codeを自動実行したい
2. Claude Code最新機能を調査 → `claude -p`(headless) + systemd timerが最も堅牢と判断
3. `/loop`は3日で自動期限切れ、`--channels`はresearch preview → 外部cronの方が確実
4. 課金: Max 5x Plan($100/月固定)に決定。OAuth認証、`--bare`/`--max-budget-usd`は不要
5. レポートの成果物(public)とシステム(private)はgit logの関心が混ざるため別リポジトリに分離

---

## マシン・認証

| 項目 | 内容 |
|------|------|
| マシン | Ryzen 7 PRO 6850H / 32GB DDR5 / 512GB SSD |
| OS | Ubuntu Server 24.04 LTS |
| プラン | Claude Max 5x ($100/月) |
| 認証 | OAuth。初回SSHでURL認証、以降自動リフレッシュ(~/.claude/) |
| レート制限 | 5時間あたり約225メッセージ。タスク2と実行時間をずらして運用 |

---

## リポジトリ構成

```
├── trend-reports (public)       ← 成果物のみ。GitHub Pages
│   ├── index.html               ← レポート一覧ページ
│   ├── reports/
│   │   ├── 2026-03-24-claude-code.html
│   │   └── ...
│   ├── assets/
│   │   └── style.css
│   └── README.md
│
└── trend-system (private)       ← システム
    ├── scripts/
    │   └── run.sh               ← メイン実行スクリプト
    ├── prompts/
    │   └── trend-research.md    ← 調査用プロンプトテンプレート
    ├── config/
    │   └── keywords.yml         ← チャネル・フィード定義
    ├── templates/
    │   ├── report.html          ← レポートHTMLテンプレート
    │   └── index.html           ← 一覧ページテンプレート
    ├── systemd/
    │   ├── trend-report.timer
    │   └── trend-report.service
    ├── logs/                    ← .gitignore
    └── README.md
```

### サーバー側の共通設定 (リポジトリ外)

```
/home/<user>/
├── .env.agent               ← 環境変数（xAI API key等）chmod 600
├── .local/bin/
│   └── agent-common.sh      ← 共通関数（ログ、ロック、通知）
├── trend-system/             ← clone
└── trend-reports/            ← clone
```

---

## 実行フロー

```
systemd timer (毎日、チャネルごとに時間をずらす)
  └→ trend-system/scripts/run.sh
       ├→ config/keywords.yml からチャネル定義を読み込み
       ├→ 各チャネルについて:
       │    ├→ RSSフィードをcurlで事前取得
       │    ├→ claude -p \
       │    │     --max-turns 15 \
       │    │     --allowedTools "Read" "Write" "Bash(curl:*)" \
       │    │     "{プロンプト + RSSデータ + 前回レポート}"
       │    │   ※ Grok MCP設定済みならx_searchも自動利用
       │    └→ 生成HTMLを trend-reports/reports/ に配置
       ├→ index.html 再生成
       ├→ git add, commit, push (trend-reports repo)
       └→ ログ記録
```

---

## チャネル構成 (4チャネル)

### レポートの2層構造

各チャネル共通で、レポートは以下の2層で構成する:

1. **公式アップデート (ファクト)** — 何がリリースされたか、何が変わったか。公式ブログ、GitHub Releases、Changelogから。淡々と事実を並べる。
2. **コミュニティの反応 (オピニオン)** — 実際に使ってみてどうか、活用法。X/Twitter、Qiita、Zennから。温度感やトーンも拾う。

### CH1: Claude Code (毎日 6:00)

| 層 | ソース | 取得方法 |
|----|--------|---------|
| 公式 | Anthropic Blog | RSS `https://www.anthropic.com/rss.xml` |
| 公式 | Claude Code Releases | RSS `https://github.com/anthropics/claude-code/releases.atom` |
| 反応 | X/Twitter | Grok MCP `x_search` — クエリ: `"Claude Code"` |
| 反応 | Zenn | RSS `https://zenn.dev/topics/claudecode/feed` |
| 反応 | Qiita | RSS `https://qiita.com/tags/ClaudeCode/feed` |
| 補完 | Web検索 | Claude Code自身のweb search |

### CH2: Codex / OpenAI (毎日 6:30)

| 層 | ソース | 取得方法 |
|----|--------|---------|
| 公式 | OpenAI Blog | web search（RSSなし） |
| 反応 | X/Twitter | Grok MCP — クエリ: `"Codex CLI" OR "OpenAI agent"` |
| 反応 | Zenn | RSS `https://zenn.dev/topics/openai/feed` |
| 反応 | Qiita | RSS `https://qiita.com/tags/OpenAI/feed` |

### CH3: 生成AIトレンド総合 (毎日 7:00)

| 層 | ソース | 取得方法 |
|----|--------|---------|
| 公式 | Anthropic / OpenAI | RSS + web search |
| 反応 | X/Twitter | Grok MCP — クエリ: `"生成AI" OR "LLM" 新サービス` |
| 反応 | Zenn トレンド | RSS `https://zenn.dev/feed` |
| 反応 | Qiita トレンド | RSS `https://qiita.com/popular-items/feed.atom` |
| 話題 | Skills/Agents | Grok MCP + web search `"MCP server" OR "Claude skill" trending` |

### CH4: GitHub急成長リポ (日曜のみ、安定後に追加)

| ソース | 取得方法 |
|--------|---------|
| GitHub Trending 全言語 | RSS `https://mshibanami.github.io/GitHubTrendingRSS/daily/all.xml` |
| GitHub Trending Python | RSS `.../daily/python.xml` |
| GitHub Trending TypeScript | RSS `.../daily/typescript.xml` |
| X/Twitter | Grok MCP — `"GitHub" AI agent OR LLM stars` |

---

## Grok MCP / xAI API

### 用途

X/Twitter検索。Twitter APIは高額・制限が厳しいため、xAIのGrok APIを経由してX上の投稿を検索・分析する。

### API仕様

- エンドポイント: Responses API (`/v1/responses`)
- ツール: `x_search` (X検索) + `web_search` (一般Web検索)
- 旧Live Search API (Chat Completions) は2026年1月に廃止済み
- 両ツールを1リクエストで同時に渡せる。モデルが自律的に選択

### モデル・料金

| モデル | 入力 | 出力 | 備考 |
|--------|------|------|------|
| `grok-4-1-fast` | $0.20/1M | $0.50/1M | 推奨。安価・高速・2Mコンテキスト |
| `grok-4` | $3.00/1M | $15.00/1M | 最高精度。通常不要 |

- ツール呼び出し: x_search/web_search とも $5/1,000コール
- 月間見積もり: 約$3〜5 (3チャネル×毎日×3-5コール)

### x_searchのフィルタオプション

| パラメータ | 用途 |
|-----------|------|
| `allowed_x_handles` | 特定ユーザーの投稿のみに絞る |
| `excluded_x_handles` | 特定ユーザーを除外 (最大5) |
| `from_date` / `to_date` | 日付範囲 (ISO8601: YYYY-MM-DD) |
| `enable_image_understanding` | 投稿内の画像も分析 |

### APIキー取得

1. `console.x.ai` でアカウント作成
2. 新規ユーザーは$25の無料クレジット
3. Data Sharingプログラム有効化で追加$150/月クレジット
4. API Keysセクションで `xai-` で始まるキーを発行

### MCP設定 (Claude Code用)

推奨: `toocheap/x-search-mcp` (日本語ドキュメント充実、Responses API + x_search対応)

```json
{
  "mcpServers": {
    "x_search": {
      "command": "python3",
      "args": ["/path/to/x-search-mcp/x_search_mcp.py"],
      "env": { "XAI_API_KEY": "xai-xxxx" }
    }
  }
}
```

### フォールバック: curl直接方式

MCPが `claude -p` (headless) で動作しない場合のフォールバック。スクリプト内でxAI APIを直接叩き、結果をプロンプトに含める。

```bash
curl -s https://api.x.ai/v1/responses \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $XAI_API_KEY" \
  -d '{
    "model": "grok-4-1-fast",
    "input": [{"role": "user", "content": "Claude Codeの最新の反応を要約して"}],
    "tools": [{"type": "x_search", "from_date": "'$(date -d yesterday +%Y-%m-%d)'"}]
  }'
```

---

## systemd設定

### timer

```ini
# /etc/systemd/system/trend-report.timer
[Unit]
Description=Daily trend research report

[Timer]
OnCalendar=*-*-* 06:00:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
```

### service

```ini
# /etc/systemd/system/trend-report.service
[Unit]
Description=Run trend research report
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=<user>
WorkingDirectory=/home/<user>/trend-system
EnvironmentFile=/home/<user>/.env.agent
ExecStart=/home/<user>/trend-system/scripts/run.sh
StandardOutput=append:/home/<user>/trend-system/logs/trend-report.log
StandardError=append:/home/<user>/trend-system/logs/trend-report.log
TimeoutStartSec=1800
```

---

## セットアップ手順

### Phase 1: サーバー基盤

1. Ubuntu Server 24.04 LTS インストール
2. 基本パッケージ: `git`, `curl`, `jq`, `yq`
3. Node.js (v20 LTS) インストール
4. Claude Code: `npm install -g @anthropic-ai/claude-code`
5. Claude Code認証: `claude` 起動 → URLを手元ブラウザで開いてOAuthログイン
6. GitHub CLI: `gh auth login`
7. SSH鍵生成 → GitHubに登録

### Phase 2: リポジトリ・MCP準備

1. `trend-reports` (public) リポジトリ作成、GitHub Pages有効化
2. `trend-system` (private) リポジトリ作成
3. 両リポジトリをサーバーにclone
4. `~/.local/bin/agent-common.sh` 配置
5. `~/.env.agent` 作成 (xAI APIキー)
6. Grok MCP (`toocheap/x-search-mcp`) セットアップ・動作確認

### Phase 3: 実装・テスト

1. `config/keywords.yml` 初期設定
2. プロンプトテンプレート作成
3. `scripts/run.sh` 作成
4. HTML/CSSテンプレート初期配置
5. CH1 (Claude Code) で手動実行テスト
6. systemd timer 設定・有効化
7. 1週間の試験運用 → プロンプト・スケジュール調整

---

## 未解決・要確認事項

- [ ] MCP (`x_search`) が `claude -p` (headless) で動作するか検証。不可ならcurl直接方式に
- [ ] Qiita/Zennのタグ名の正確な確認 (`ClaudeCode` vs `claude-code` vs `claudecode`)
- [ ] GitHub Trending RSSフィード (`mshibanami.github.io`) の稼働状況確認
- [ ] OpenAIブログのRSS代替手段 (web searchのみで十分か)
- [ ] レポートHTMLテンプレートのデザイン決定
- [ ] プロンプトテンプレートの具体的な内容設計
- [ ] systemd `TimeoutStartSec` の適切な値 (1チャネルあたりの処理時間見積もり)
- [ ] 前回レポートとの差分検出ロジックの詳細設計
