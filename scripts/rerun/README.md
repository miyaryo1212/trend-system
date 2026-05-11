# rerun/ — トレンドレポート手動再生成パイプライン

`run.sh` (cron自動実行) が `pipeline_warnings` を出した日のレポートを、人間が
監督しながら部分的に作り直すための薄いスクリプト群。**cronから呼ばれない**こと
を前提とした分離 (無限ループ事故の予防)。

`run.sh` をモノリスのまま残し、ここの各ステップは run.sh と同等のロジックを
スタンドアロンで再現する。コードは重複するが、cronパスを触らないので安全性が
上がる代わりに drift しないよう注意。

## 全体像

```
00-fetch.sh         Step 0   RSS / sitemap / web_search を取得 → workdir
[ user edits        Step 1   workdir/features.txt を手書き ]
02-xsearch.sh       Step 2   features.txt の各機能でX検索 → x_search_results.txt
03-report.sh        Step 3   claude -p で最終レポート Markdown 生成
04-codex-review.sh  Step 3.5 codex_review / codex_importance を frontmatter に注入
05-validate.sh      Step 3.6 frontmatter の型/構文検査 (+ 任意で claude -p 修復)
06-publish.sh       Step 4   trend-reports リポへ commit + push
```

Step 1 は意図的にスクリプト化していない (rerun の主目的が「人間が選んだ features
で再走させる」ことなので、ここを再自動化すると元の不具合を再現するだけ)。
Step 3.4 (pipeline_warnings 注入) は rerun では不要なため割愛 (再生成して品質が
直ったことを意味する)。

## 使い方 (典型例: 2026-05-08 ai-trends を再生成)

```bash
cd ~/project/personal/trend-research/trend-system

# 1) 作業ディレクトリを切る (workdir は使い捨て)
WORKDIR="$(mktemp -d /tmp/rerun-ai-trends-2026-05-08.XXXX)"

# 2) Step 0: RSS と sitemap を取得
#    --sitemap-readonly を付けないと本番cronのキャッシュ差分を消費してしまう
./scripts/rerun/00-fetch.sh \
    --channel ai-trends \
    --workdir "$WORKDIR" \
    --sitemap-readonly

# 3) Step 1: features を手書きする
#    "- 機能名: 簡潔な説明" 形式の箇条書き 1 行 = 1 機能
$EDITOR "$WORKDIR/features.txt"

# 4) Step 2: X検索 (基準日を指定するとそこから -7 日が from_date)
./scripts/rerun/02-xsearch.sh \
    --channel ai-trends \
    --workdir "$WORKDIR" \
    --date 2026-05-08

# 5) Step 3: claude -p で最終レポート生成
#    出力先は ${REPORTS_DIR}/src/content/reports/2026-05-08-ai-trends.md (既存上書き)
./scripts/rerun/03-report.sh \
    --channel ai-trends \
    --workdir "$WORKDIR" \
    --date 2026-05-08

REPORT=~/deploy/trend-reports/src/content/reports/2026-05-08-ai-trends.md
# REPORT のパスは環境依存 (TREND_REPORTS_DIR / .env.local)

# 6) Step 3.5: codex_review を入れ直す (既存値は事前に剥がす)
./scripts/rerun/04-codex-review.sh --report "$REPORT"

# 7) Step 3.6: 検証 (失敗時に claude -p で自動修復させる場合は --repair)
./scripts/rerun/05-validate.sh --report "$REPORT" --repair

# 8) ローカルで内容を目視確認
git -C "$(dirname "$REPORT")/../../.." diff -- "src/content/reports/2026-05-08-ai-trends.md"

# 9) Step 4: 確認した上で publish (--confirm 必須)
./scripts/rerun/06-publish.sh --channel ai-trends --date 2026-05-08 --confirm

# 10) workdir 掃除
rm -rf "$WORKDIR"
```

## 引数の規約

すべてのスクリプトに共通:

| フラグ              | 役割                                                                   |
| ------------------- | ---------------------------------------------------------------------- |
| `--channel <id>`    | `config/keywords.yml` の `channels.*` のキー                           |
| `--workdir <path>`  | ステップ間で共有する作業ディレクトリ (Step 0/2/3)                      |
| `--date YYYY-MM-DD` | 対象日付 (Step 2/3/6)                                                  |
| `--report <path>`   | 完成済みレポートのパス (Step 3.5/3.6 が直接操作)                       |

workdir の中身 (Step 0 + Step 1 を経た時点):

```
official_rss.txt          Step 0
community_rss.txt         Step 0
web_search_queries.txt    Step 0
sitemap_new_pages.txt     Step 0
features.txt              Step 1 (人間が書く)
x_search_results.txt      Step 2
previous_report.txt       Step 3 (中で生成)
```

## ログ

`LOG_FILE=/path/to/log` を export してから各スクリプトを呼ぶと、`log` の出力が
そのファイルにも tee される。一連の rerun を1ファイルに集約したいときに使う:

```bash
export LOG_FILE="${SYSTEM_DIR}/logs/2026-05-08-ai-trends-rerun.log"
./scripts/rerun/00-fetch.sh ...
./scripts/rerun/02-xsearch.sh ...
# ...
```

## なぜ run.sh と分けたか

- **無限ループ予防**: rerun が自分自身を呼ぶ事故、または cron が rerun を発火させ
  る事故をハード分離するため、エントリポイントを物理的に別にした。
- **冪等性**: Step 3.5/3.6 は既存 frontmatter フィールドを剥がしてから注入する
  ので何度走らせても安定する (run.sh は1日1回前提で書かれている)。
- **Step 4 のガード**: rerun は事故影響が大きいので、`06-publish.sh` は `--confirm`
  必須・コミットメッセージに "(manual rerun)" を含める。
