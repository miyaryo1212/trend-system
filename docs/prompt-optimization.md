# Grok x_search プロンプト改善レポート

## 背景

トレンド調査システムのX/Twitter情報収集において、Grok APIの`x_search`をテストした結果、プロンプト設計に改善が必要であることが判明した。

## 問題

### 試行1: 汎用プロンプト

```
Claude Codeの最新の評判を教えて
```

- **結果**: x_search 5回呼び出し、コスト $0.27
- **問題点**: Grokが製品説明から始めてしまい、事実の説明にトークンを浪費。公式ブログで取得済みの情報と重複。

### 試行2: 役割を絞ったプロンプト

公式発表の要約は不要と明示し、ポジティブ/ネガティブ/Tipsの3カテゴリ分類、最大10件制限、エンゲージメントフィルタ（いいね10以上）を追加。

- **結果**: コスト $0.02 に削減（93%減）
- **問題点**: 「Claude Code」という広いキーワードでは、ふわっとした感想（「Claude Codeすごい」等）や関連性の低い投稿が多く、具体的な機能へのフィードバックが拾えない

### 試行3: 試行2と同じプロンプトを再実行

- **結果**: x_search 6回呼び出し、コスト $0.36
- **問題点**: Grokが十分な結果を得るために追加検索を繰り返す。結果の質もキーワード検索3回+セマンティック検索2回+追加キーワード検索1回と非効率。拾える投稿も一般的な感想が中心で、機能単位の具体的なフィードバックではない。

### 根本的な課題

「Claude Code」で広く検索すると:

- 公式情報と個人の感想が混在する
- 特定の機能への具体的なフィードバックが埋もれる
- Grokが「もっと探さなきゃ」と検索回数を増やしがち
- コストが不安定（$0.02〜$0.36と振れ幅が大きい）

## 解決策: 2段階パイプライン

情報収集を「事実の把握」と「反応の収集」に分離し、Step 1の出力をStep 2の入力にする。

### Step 1: 公式ソースから新機能名を抽出 (Claude Code)

Claude Code（`claude -p`）がRSS/Changelogを読み、直近のアップデートで登場した機能名・変更点を抽出する。

```
入力:
  - Anthropic Blog RSS
  - GitHub Releases Atom feed
  - Claude Code Changelog

処理:
  claude -p "以下のRSSフィードから、直近24時間以内に
  発表されたClaude Codeの新機能・アップデート名を
  箇条書きで抽出してください。機能の説明は不要です。"

出力例:
  - Channels (Telegram/Discord連携)
  - Computer Use (macOSデスクトップ操作)
  - --bare flag
  - Dispatch (スマホ連携)
```

このステップではGrok APIは使わない。Claude Codeのweb search + RSS取得（curl）で完結。追加コストなし（Max Plan枠内）。

### Step 2: 機能名でピンポイントにX検索 (Grok)

Step 1で抽出した各機能名をクエリに含め、Grokで機能単位の反応を収集する。

```
入力: Step 1の機能名リスト

各機能について:
  Grok x_search → 機能名を含むX投稿を検索
  → ポジティブ/ネガティブ/Tipsに分類

出力: 機能ごとのユーザー反応レポート
```

### Step 2 用 Grokプロンプトテンプレート

```
"Claude Code {{FEATURE_NAME}}" ({{FEATURE_DESCRIPTION}})
に関する個人ユーザーのX投稿を検索してください。

除外: 公式アカウント(@claudeai, @AnthropicAI)、企業宣伝・アフィリエイト
品質: いいね10以上またはリポスト3以上を優先
期間: 過去7日間
言語: 日本語

分類:
1. ポジティブ — 実際に使って便利だった点
2. ネガティブ — 不具合、制限、不満
3. Tips — セットアップ方法、活用例

出力フォーマット:
- 各投稿は「要旨（1〜2文）」+「投稿URL」の形式
- 最大5件
- 該当なしの場合は「該当なし」と記載
```

### 実行フロー（改訂版）

```
systemd timer
  └→ run.sh
       ├→ [Step 0] RSSフィードをcurlで取得
       │    - Anthropic Blog RSS
       │    - GitHub Releases Atom
       │
       ├→ [Step 1] 新機能名抽出 (Claude Code, コスト: $0)
       │    claude -p "以下のフィードから新機能名を抽出..."
       │    → features=["Channels", "Computer Use", ...]
       │
       ├→ [Step 2] 機能ごとにX検索 (Grok, コスト: ~$0.02/機能)
       │    for feature in features:
       │      curl xAI API → x_search(feature)
       │    → 機能ごとのposi/nega/tips
       │
       ├→ [Step 3] 最終レポート生成 (Claude Code, コスト: $0)
       │    claude -p "以下のデータからHTMLレポートを生成..."
       │    入力: Step 0のRSS + Step 2のX反応
       │    → report.html
       │
       ├→ [Step 4] 公開
       │    git push → GitHub Pages
       └→ ログ記録
```

## コスト比較

| 方式 | 1回あたり | 月 (3チャネル×30日) |
|------|----------|-------------------|
| 旧: 汎用プロンプト | $0.27 | ~$24 |
| 改善1: 役割絞り | $0.02〜0.36 (不安定) | ~$2〜$32 |
| 改善2: 2段階パイプライン | ~$0.02×機能数 | ~$2〜$6 (安定) |

2段階パイプラインでは機能数に比例するため予測可能。新機能が0件の日はStep 2がスキップされ、コストは$0。

## keywords.yml への反映

```yaml
channels:
  - name: "Claude Code"
    schedule: "daily"
    pipeline: "two-stage"  # 2段階パイプラインを使用

    # Step 0: 公式ソース（事実の把握）
    official_sources:
      - type: rss
        url: "https://www.anthropic.com/rss.xml"
        label: "Anthropic Blog"
      - type: rss
        url: "https://github.com/anthropics/claude-code/releases.atom"
        label: "Claude Code Releases"

    # Step 1: 新機能名の抽出（claude -pで処理）
    feature_extraction:
      prompt: |
        以下のRSSフィードから、直近24時間以内に発表された
        Claude Codeの新機能・アップデート名を箇条書きで抽出してください。
        機能の説明は1行以内で簡潔に。該当なしの場合は「なし」。

    # Step 2: X検索（Grok x_searchで処理）
    x_search:
      prompt_template: |
        "Claude Code {{FEATURE_NAME}}" ({{FEATURE_DESCRIPTION}})
        に関する個人ユーザーのX投稿を検索してください。
        除外: 公式アカウント(@claudeai, @AnthropicAI)、企業宣伝
        品質: いいね10以上優先
        期間: 過去7日間
        言語: 日本語
        分類: ポジティブ/ネガティブ/Tips
        各投稿は要旨+URL。最大5件。該当なしは「該当なし」。

    # 補完: Qiita/Zenn（RSでS取得、claude -pで分析）
    community_sources:
      - type: rss
        url: "https://zenn.dev/topics/claudecode/feed"
        label: "Zenn"
      - type: rss
        url: "https://qiita.com/tags/ClaudeCode/feed"
        label: "Qiita"
```

## 他チャネルへの展開

同じ2段階パイプラインをCH2 (Codex)、CH3 (生成AIトレンド) にも適用可能。

- **CH2**: OpenAIブログ(web search) → 機能名抽出 → X検索
- **CH3**: 複数公式ソース → トピック抽出 → X検索。ただしCH3は特定機能よりも大きなトレンドが対象なので、Step 1の抽出粒度を「機能名」ではなく「話題・トピック」に変える。

## 注意事項

- Grokのx_search呼び出し回数はプロンプトの曖昧さに比例する。具体的な機能名をクエリに含めることで呼び出し回数を安定させる
- `max_tool_calls`パラメータでGrokの検索回数に上限を設定することも検討可能（API側でサポートされている場合）
- 新機能が0件の日はStep 2をスキップし、Qiita/ZennのRSS + 過去レポートとの差分のみでレポート生成する
- x_searchのコストは実行ごとに振れがあるため、月次でusageを確認し、必要に応じてクレジットを追加する
