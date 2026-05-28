# tests/

パイプラインの**決定論的な部分**だけを対象にした bats テスト。LLM 出力そのもの
(claude -p / codex exec の生成内容) は非決定的なのでテスト対象外。今回テストするのは
「LLM 出力を受け取った後の配管」= 2026-05 に実際にバグった層:

| テスト | 対象 | run.sh での使用箇所 |
| --- | --- | --- |
| `lib_transforms.bats` | `scripts/lib/strip-codex-frontmatter.awk` | Step 3.4 |
| | `scripts/lib/inject-codex-review.awk` | Step 3.5 |
| | `scripts/lib/inject-pipeline-warnings.awk` | Step 3.7 |
| | `scripts/lib/extract-codex-json.sh` | Step 3.5 |
| `qc_gate.bats` | `scripts/qc-gate.py` | Step 3.6 |

`scripts/lib/` の各ファイルは run.sh から `awk -f` / `bash` で直接呼ばれる実物なので、
テストはコピーではなく本番コードを検証する (drift しない)。

## 実行

```bash
bats tests/
```

## 依存: bats

```bash
# npm (sudo 不要、ユーザの npm-global prefix へ)
npm install -g bats

# または apt (要 sudo)
sudo apt install bats
```

`fixtures/` 配下の `.md` は判定ロジック検証用の合成データ (実レポートではない)。
日付は実データと混同しないよう 2026-06 を使用。
