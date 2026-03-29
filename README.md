# AI Trend System

生成AIトレンド情報の自動収集パイプライン。RSS/Web検索で公式情報を取得し、Claude CodeとGrok APIでレポートを生成して [trend-reports](https://github.com/miyaryo1212/trend-reports) に自動公開します。

## アーキテクチャ

```
systemd timer → run.sh <channel-id>
  │
  ├─ Step 0: RSSフィード / Web検索で公式情報を取得 (curl)
  ├─ Step 1: 新機能・トピック名を抽出 (claude -p)
  ├─ Step 2: 機能ごとにX上の反応を検索 (xAI Grok API x_search)
  ├─ Step 3: 最終Markdownレポートを生成 (claude -p)
  └─ Step 4: git push → Cloudflare Pages 自動デプロイ
```

各レポートは **公式アップデート（ファクト）** + **コミュニティの反応（オピニオン）** の2層構造。

## チャンネル

| ID | テーマ | スケジュール |
|---|---|---|
| `claude-anthropic` | Claude / Anthropic | 毎日 6:00 |
| `codex-openai` | Codex / OpenAI | 毎日 6:30 |
| `ai-trends` | 生成AIトレンド総合 | 毎日 7:00 |
| `github-trending` | GitHub急成長リポ | 毎週月曜 8:00 |

## ディレクトリ構成

```
scripts/
  run.sh               # メイン実行スクリプト (2段階パイプライン)
  setup-systemd.sh     # systemdユニットインストーラ
prompts/
  feature-extraction.md # Step 1: 機能名抽出プロンプト
  trend-research.md    # Step 3: 最終レポート生成プロンプト
config/
  keywords.yml         # チャネル・ソース・プロンプト定義
systemd/               # timer/service定義
```

## 必要環境

- Ubuntu Server (systemd)
- Claude Max Plan (OAuth認証済み)
- xAI API Key (Grok x_search用)
- git, curl, jq, yq

## セットアップ

```bash
# 1. .env.local を作成
cp .env.local.example .env.local
# TREND_SYSTEM_DIR, TREND_REPORTS_DIR, XAI_API_KEY を設定

# 2. systemd timerをインストール
bash scripts/setup-systemd.sh

# 3. 手動実行テスト
bash scripts/run.sh claude-anthropic
```

## 関連リポジトリ

- [trend-reports](https://github.com/miyaryo1212/trend-reports) - Astro静的サイト（レポート公開）
