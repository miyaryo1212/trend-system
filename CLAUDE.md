# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## プロジェクト概要

Ubuntu Server上でClaude Code (`claude -p`) をsystemd timerで定期実行し、生成AI関連のトレンド情報を収集→Markdownレポート化→Astro + Cloudflare Pagesで公開するシステム。

- **trend-system** (このリポジトリ, public): 実行スクリプト、プロンプト、設定
- **trend-reports** (別リポジトリ, public): Astroプロジェクト。生成されたMarkdownレポートを格納し、push を Cloudflare Pages が検知してビルド・デプロイ

公開URL: `https://aitrends.miyaryo1212.com` (Cloudflare経由)

両リポジトリとも public。秘密情報 (APIキー・Webhook 等) は `.env.local` / `~/.env.agent` に置き、コミットしないこと。
main は ruleset `protect-main` で保護 (削除・force push 禁止、PR 必須)。repo admin は常に bypass できるため、本人と denebola のパイプラインからの直接 push はそのまま通る。

## アーキテクチャ

### 2段階パイプライン

コスト効率のため、情報収集を「事実の把握」と「反応の収集」に分離している。

```
systemd timer → scripts/run.sh <channel-id>
  ├→ [Step 0] RSSフィード取得 (curl)
  │    - config/keywords.yml の official_sources / community_sources
  │    - web_search 型ソースはクエリとしてStep 1に渡す
  │    - json_api 型ソースはJSONを整形して取得 (HF Daily Papers等)
  │
  ├→ [Step 1] 新機能・トピック抽出 (claude -p, Max Plan枠内)
  │    - prompts/feature-extraction.md + RSSデータ
  │    → features.txt (箇条書き)
  │
  ├→ [Step 2] 機能ごとにX検索 (xAI Grok API, ~$0.04/機能)
  │    - features.txt の上位 x_search.max_features 件 (既定6) に対して x_search
  │    - 1機能あたり「検索1回・6件以下」に制限 (post 数課金, #8)
  │    - 新機能なしの日はスキップ ($0)
  │    - x_search.enabled: false のチャネルはスキップ (CH5等)
  │    → x_search_results.txt
  │
  ├→ [Step 3] 最終レポート生成 (claude -p, Max Plan枠内)
  │    - prompts/trend-research[-{channel}].md + 全データ
  │    - チャネル専用テンプレートがあればそちらを優先
  │    → trend-reports/src/content/reports/YYYY-MM-DD-channel.md
  │
  ├→ [Step 3.4] 前回レポートから複製された codex_review/codex_importance を剥がす
  ├→ [Step 3.5] Codex レビュー注入 (codex exec, サブスク枠内, codex 未導入ならスキップ)
  ├→ [Step 3.6] QC ゲート (継続表記・前日重複がしきい値超で警告, scripts/qc-gate.py)
  ├→ [Step 3.7] pipeline_warnings 注入 (Step 1/2/3.5/3.6 のフォールバック検出時のみ)
  ├→ [Step 3.8] frontmatter YAML 検証 (scripts/validate-frontmatter.py, 失敗時 claude -p で修正)
  │
  └→ [Step 4] git push → Cloudflare Pages (Astro build → deploy)
```

### チャネル構成

| CH  | コマンド                  | テーマ             | スケジュール |
| --- | ------------------------- | ------------------ | ------------ |
| CH1 | `run.sh claude-anthropic` | Claude / Anthropic | 毎日 6:00    |
| CH2 | `run.sh codex-openai`     | Codex / OpenAI     | 毎日 6:30    |
| CH3 | `run.sh ai-trends`        | 生成AIトレンド総合 | 毎日 7:00    |
| CH4 | `run.sh github-trending`  | GitHub急成長リポ   | 月曜 8:00    |
| CH5 | `run.sh academia`         | LLM/NLP最新論文    | 毎日 7:30    |

CH1-CH4は2層構造: **公式アップデート(ファクト)** + **コミュニティの反応(オピニオン)**
CH5は学術論文特化: **注目論文サマリー** + **分野別の動向** (X検索なし、専用テンプレート使用)

チャネル以外の定期実行:

| タイマー            | 実行内容                                                        | スケジュール |
| ------------------- | --------------------------------------------------------------- | ------------ |
| `trend-xai-balance` | `check-xai-balance.sh` (xAI 残高監視) + `check-claude-auth.sh` (claude -p 認証チェック) → Slack | 毎日 5:50    |
| `trend-ranking`     | `generate-ranking.sh` (直近4週間 Top 5 を選定 → trend-reports/src/data/ranking.json) | 毎日 8:00    |

### X/Twitter検索

xAI Grok API (`grok-4-1-fast`) の `x_search` をcurl直接方式で使用。Step 1で抽出した機能名をピンポイントでクエリに含め、検索回数を安定させる。

2026-09-21 から x_search は「取得した post 数」課金 ($5/1k posts, 親・引用 post も含み重複排除なし)。
指示なしだと Grok が1機能あたり2-3回検索して10-20 post 取得するため、プロンプト末尾で「検索1回・6件以下」に縛っている。
リクエスト毎の `x_posts_fetched` / `cost_in_usd_ticks` (1e-10 USD 単位) はログに出る。

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
│   ├── lib/                 ← run.sh の変換処理 (codex JSON抽出・注入awk等)
│   ├── qc-gate.py           ← Step 3.6: QC ゲート
│   ├── validate-frontmatter.py ← Step 3.8: frontmatter 検証
│   ├── generate-ranking.sh  ← 4週間ランキング生成
│   ├── check-xai-balance.sh ← xAI 残高監視
│   ├── check-claude-auth.sh ← claude -p 認証チェック
│   ├── backfill-codex-reviews.sh ← 過去レポートへの Codex レビュー後付け
│   ├── rerun/               ← 手動再生成パイプライン (cron からは呼ばない, rerun/README.md)
│   └── setup-systemd.sh     ← systemdユニットインストーラ
├── prompts/
│   ├── feature-extraction.md          ← Step 1: 機能名抽出プロンプト
│   ├── trend-research.md              ← Step 3: 最終レポート生成プロンプト (デフォルト)
│   ├── trend-research-academia.md     ← Step 3: 学術論文レポート生成プロンプト (CH5用)
│   ├── codex-review.md                ← Step 3.5: Codex レビュープロンプト
│   └── ranking-selection.md           ← ランキング選定プロンプト
├── config/
│   └── keywords.yml          ← チャネル・ソース・プロンプト定義
├── systemd/                  ← timer/service定義 (CH1-CH5, ranking, xai-balance)
├── tests/                    ← bats / QC ゲートのテスト (tests/README.md)
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
TREND_SYSTEM_DIR="${HOME}/project/personal/trend-research/trend-system"  # 開発環境
TREND_REPORTS_DIR="${HOME}/project/personal/trend-research/trend-reports" # 開発環境
# 本番: ${HOME}/deploy/trend-system, ${HOME}/deploy/trend-reports
XAI_API_KEY="xai-..."
```

### サーバー環境

- 本番ホスト: denebola (leo 上の deploy 用 VM) / Ubuntu Server 24.04 LTS / Ryzen 5 PRO 5650GE 4コア / 11GB
- 本番の環境変数は `~/.env.agent` (systemd の EnvironmentFile。`.env.local` があればそちらが優先)
- Claude Max 5x Plan (OAuth認証)
- 必須パッケージ: git, curl, jq, yq (mikefarah v4), codex CLI (Step 3.5 用)
- Astroビルドは Cloudflare Pages 側で実行 (サーバーではビルドしない)

## 開発上の注意

- レート制限回避のため、チャネル間は30分ずらして実行
- `claude -p` の `--allowedTools` でツール制限: Step 1/3 は Read, Write, Bash(curl:*), WebSearch, WebFetch / Step 3.8 は Read, Edit / ランキングは Read のみ
- Markdownレポートは trend-reports の `src/content/reports/` に出力。このリポにはレポート成果物を含めない
- Anthropic Blog の RSS は廃止済み。web_search 型に切り替え済み (keywords.yml)
- Grok x_search のコストは取得 post 数に比例。汎用プロンプトは避け、機能名をピンポイントで指定する。run.sh の Step 2 を変えたら `scripts/rerun/02-xsearch.sh` も追従させる (#10)
- systemd `TimeoutStartSec`: 1800秒 (30分)
