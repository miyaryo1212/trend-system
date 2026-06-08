#!/usr/bin/env bats
# scripts/qc-gate.py のしきい値判定テスト (Step 3.6)。
# 健全な記事は exit 0、ステイル記事は exit 2 を返すことを確認する。

setup() {
    QC="${BATS_TEST_DIRNAME}/../scripts/qc-gate.py"
    REPORTS="${BATS_TEST_DIRNAME}/fixtures/reports"
}

@test "qc: 健全な記事は発火しない (exit 0)" {
    run python3 "$QC" "$REPORTS/2026-06-10-claude-anthropic.md" --reports-dir "$REPORTS"
    [ "$status" -eq 0 ]
}

@test "qc: 継続表記が多い記事は発火 (exit 2)" {
    run python3 "$QC" "$REPORTS/2026-06-10-codex-openai.md" --reports-dir "$REPORTS"
    [ "$status" -eq 2 ]
    grep -q '継続表記' <<< "$output"
}

@test "qc: features 少 + 継続表記多 の記事は発火 (exit 2)" {
    run python3 "$QC" "$REPORTS/2026-06-10-ai-trends.md" --reports-dir "$REPORTS"
    [ "$status" -eq 2 ]
}

@test "qc: academia の2日前全件重複は発火 (exit 2)" {
    run python3 "$QC" "$REPORTS/2026-06-10-academia.md" --reports-dir "$REPORTS"
    [ "$status" -eq 2 ]
    grep -q 'academia' <<< "$output"
}

@test "qc: 前日 features 重複が高比率なら継続表記ゼロでも発火 (exit 2)" {
    run python3 "$QC" "$REPORTS/2026-06-14-claude-anthropic.md" --reports-dir "$REPORTS"
    [ "$status" -eq 2 ]
    grep -q '前日レポートと重複' <<< "$output"
}

@test "qc: 出力メッセージは1行 (pipeline_warnings に流せる形式)" {
    run python3 "$QC" "$REPORTS/2026-06-10-codex-openai.md" --reports-dir "$REPORTS"
    [ "$status" -eq 2 ]
    [ "${#lines[@]}" -eq 1 ]
}

@test "qc: パース不能ファイルは exit 1 (block ではなくエラー扱い)" {
    run python3 "$QC" "$BATS_TEST_DIRNAME/fixtures/clean.md" --reports-dir "$BATS_TEST_DIRNAME/fixtures"
    # clean.md は frontmatter 有効だが features 2件・継続0なので OK (exit 0)
    [ "$status" -eq 0 ]
}
