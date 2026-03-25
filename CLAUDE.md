# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## プロジェクト概要

Ubuntu Server上でClaude Code (`claude -p`) をsystemd timerで定期実行し、生成AI関連のトレンド情報を収集→Markdownレポート化→Astro + Netlifyで公開するシステム。

- **trend-system** (このリポジトリ, private): 実行スクリプト、プロンプト、設定
- **trend-reports** (別リポジトリ, private): Astroプロジェクト。生成されたMarkdownレポートを格納し、GitHub Actions → Netlifyでデプロイ

公開URL: `https://aitrends.miyaryo1212.com` (Cloudflare経由)

## アーキテクチャ

### 2段階パイプライン

コスト効率のため、情報収集を「事実の把握」と「反応の収集」に分離している。

```
systemd timer → scripts/run.sh <channel-id>
  ├→ [Step 0] RSSフィード取得 (curl)
  │    - config/keywords.yml の official_sources / community_sources
  │    - web_search 型ソースはクエリとしてStep 1に渡す
  │
  ├→ [Step 1] 新機能・トピック抽出 (claude -p, Max Plan枠内)
  │    - prompts/feature-extraction.md + RSSデータ
  │    → features.txt (箇条書き)
  │
  ├→ [Step 2] 機能ごとにX検索 (xAI Grok API, ~$0.02/機能)
  │    - features.txt の各行に対して x_search
  │    - 新機能なしの日はスキップ ($0)
  │    → x_search_results.txt
  │
  ├→ [Step 3] 最終レポート生成 (claude -p, Max Plan枠内)
  │    - prompts/trend-research.md + 全データ
  │    → trend-reports/src/content/reports/YYYY-MM-DD-channel.md
  │
  └→ [Step 4] git push → GitHub Actions → Astro build → Netlify deploy
```

### チャネル構成

| CH  | コマンド                 | テーマ             | スケジュール |
| --- | ------------------------ | ------------------ | ------------ |
| CH1 | `run.sh claude-code`     | Claude Code        | 毎日 6:00    |
| CH2 | `run.sh codex-openai`    | Codex / OpenAI     | 毎日 6:30    |
| CH3 | `run.sh ai-trends`       | 生成AIトレンド総合 | 毎日 7:00    |
| CH4 | `run.sh github-trending` | GitHub急成長リポ   | 日曜 8:00    |

各レポートは2層構造: **公式アップデート(ファクト)** + **コミュニティの反応(オピニオン)**

### X/Twitter検索

xAI Grok API (`grok-4-1-fast`) の `x_search` をcurl直接方式で使用。Step 1で抽出した機能名をピンポイントでクエリに含め、検索回数を安定させる。

### デプロイフロー

```
run.sh が Markdown を push
  → Cloudflare Pages (push検知 → npm install → astro build → デプロイ)
```

Cloudflare Pagesがビルドからホスティングまで一貫して担当。GitHub Actionsは不要。

## ディレクトリ構成

```
trend-system/
├── scripts/
│   ├── run.sh               ← メイン実行スクリプト (2段階パイプライン)
│   └── setup-systemd.sh     ← systemdユニットインストーラ
├── prompts/
│   ├── feature-extraction.md ← Step 1: 機能名抽出プロンプト
│   └── trend-research.md    ← Step 3: 最終レポート生成プロンプト
├── config/
│   └── keywords.yml          ← チャネル・ソース・プロンプト定義
├── systemd/                  ← timer/service定義 (CH1-CH3)
├── docs/                     ← 設計ドキュメント
├── logs/                     ← 実行ログ (.gitignore)
└── .env.local                ← 環境変数 (.gitignore)

trend-reports/ (別リポジトリ)
├── src/
│   ├── content/reports/      ← Claudeが生成するMarkdownレポート
│   ├── content.config.ts     ← Content Collection定義
│   ├── layouts/              ← Base.astro, Report.astro
│   ├── pages/                ← index.astro, reports/[...slug].astro
│   └── styles/global.css     ← ダーク/ライトモード対応CSS
├── astro.config.mjs
└── public/_headers           ← キャッシュヘッダー
```

## 環境設定

### .env.local (このリポ直下、git管理外)

```bash
TREND_SYSTEM_DIR="${HOME}/project/work/tamago/trend-system"  # 開発環境
TREND_REPORTS_DIR="${HOME}/project/work/tamago/trend-reports" # 開発環境
# 本番: ${HOME}/repo/trend-system, ${HOME}/repo/trend-reports
XAI_API_KEY="xai-..."
```

### サーバー環境

- Ubuntu Server 24.04 LTS / Ryzen 7 PRO 6850H / 32GB
- Claude Max 5x Plan (OAuth認証)
- 必須パッケージ: git, curl, jq, yq, Node.js v20 LTS
- Node.js 22はGitHub Actions上のみ (Astroビルド用)

## 開発上の注意

- レート制限: 5時間あたり約225メッセージ。チャネル間は30分ずらして実行
- `claude -p` の `--allowedTools` でツール制限: Read, Write, Bash(curl:*) のみ
- Markdownレポートは trend-reports の `src/content/reports/` に出力。このリポにはレポート成果物を含めない
- Anthropic Blog の RSS は廃止済み。web_search 型に切り替え済み (keywords.yml)
- Grok x_search のコストは機能数に比例。汎用プロンプトは避け、機能名をピンポイントで指定する
- systemd `TimeoutStartSec`: 1800秒 (30分)
