#!/usr/bin/env bats
# scripts/lib/ の決定論的テキスト変換のテスト。
# これらは run.sh の Step 3.4 / 3.5 / 3.7 で実際に呼ばれる awk/sh と同一ファイル。

setup() {
    LIB="${BATS_TEST_DIRNAME}/../scripts/lib"
    FIX="${BATS_TEST_DIRNAME}/fixtures"
    TMP="$(mktemp -d)"
}

teardown() {
    rm -rf "$TMP"
}

# ---- strip-codex-frontmatter.awk (Step 3.4) ----

@test "strip: frontmatter の codex_review / codex_importance を除去する" {
    run awk -f "$LIB/strip-codex-frontmatter.awk" "$FIX/with-codex.md"
    [ "$status" -eq 0 ]
    ! grep -q '^codex_review:' <<< "$output"
    ! grep -q '^codex_importance:' <<< "$output"
}

@test "strip: 本文中の codex_review トークンは保持する" {
    run awk -f "$LIB/strip-codex-frontmatter.awk" "$FIX/with-codex.md"
    [ "$status" -eq 0 ]
    grep -q 'codex_review: この行は本文なので残るべき' <<< "$output"
}

@test "strip: codex フィールドが無い記事は素通し (冪等)" {
    run awk -f "$LIB/strip-codex-frontmatter.awk" "$FIX/clean.md"
    [ "$status" -eq 0 ]
    # clean.md と完全一致するはず
    diff <(printf '%s\n' "$output") "$FIX/clean.md"
}

# ---- inject-codex-review.awk (Step 3.5) ----

@test "inject-codex: codex_review と codex_importance を閉じ --- 直前に注入" {
    run awk -v review="テストレビュー" -v imp="3" \
        -f "$LIB/inject-codex-review.awk" "$FIX/clean.md"
    [ "$status" -eq 0 ]
    grep -q '^codex_review: "テストレビュー"' <<< "$output"
    grep -q '^codex_importance: 3' <<< "$output"
}

@test "inject-codex: imp が空なら codex_importance を出さない" {
    run awk -v review="レビューのみ" -v imp="" \
        -f "$LIB/inject-codex-review.awk" "$FIX/clean.md"
    [ "$status" -eq 0 ]
    grep -q '^codex_review: "レビューのみ"' <<< "$output"
    ! grep -q '^codex_importance:' <<< "$output"
}

@test "inject-codex: codex_review は frontmatter 内 (閉じ --- より前) に入る" {
    awk -v review="位置確認" -v imp="2" \
        -f "$LIB/inject-codex-review.awk" "$FIX/clean.md" > "$TMP/out.md"
    # 2番目の --- の行番号より codex_review の行番号が小さいこと
    cr_line=$(grep -n '^codex_review:' "$TMP/out.md" | head -1 | cut -d: -f1)
    close_line=$(grep -n '^---$' "$TMP/out.md" | sed -n 2p | cut -d: -f1)
    [ "$cr_line" -lt "$close_line" ]
}

# ---- inject-pipeline-warnings.awk (Step 3.7) ----

@test "inject-warnings: pipeline_warnings 配列を注入する" {
    printf 'warning one\nwarning two\n' > "$TMP/warn.txt"
    run awk -v wf="$TMP/warn.txt" \
        -f "$LIB/inject-pipeline-warnings.awk" "$FIX/clean.md"
    [ "$status" -eq 0 ]
    grep -q '^pipeline_warnings:' <<< "$output"
    grep -q '^  - "warning one"' <<< "$output"
    grep -q '^  - "warning two"' <<< "$output"
}

@test "inject-warnings: ダブルクォートとバックスラッシュをエスケープする" {
    printf 'has "quote" and back\\slash\n' > "$TMP/warn.txt"
    run awk -v wf="$TMP/warn.txt" \
        -f "$LIB/inject-pipeline-warnings.awk" "$FIX/clean.md"
    [ "$status" -eq 0 ]
    grep -q '\\"quote\\"' <<< "$output"
    grep -q 'back\\\\slash' <<< "$output"
}

# ---- extract-codex-json.sh (Step 3.5) ----

@test "extract-json: ANSI コード除去 + 外側 JSON 抽出" {
    printf '\033[32msome log line\033[0m\n{\n  "review": "x",\n  "importance": 4\n}\ntrailing noise\n' > "$TMP/raw.txt"
    run bash "$LIB/extract-codex-json.sh" "$TMP/raw.txt"
    [ "$status" -eq 0 ]
    # 出力が valid JSON であること
    echo "$output" | jq empty
    [ "$(echo "$output" | jq -r '.review')" = "x" ]
    [ "$(echo "$output" | jq -r '.importance')" = "4" ]
}

@test "extract-json: ANSI まみれの行も除去される" {
    printf '\033[1;31m{\033[0m\n\033[33m  "review": "y"\033[0m\n\033[31m}\033[0m\n' > "$TMP/raw.txt"
    run bash "$LIB/extract-codex-json.sh" "$TMP/raw.txt"
    [ "$status" -eq 0 ]
    echo "$output" | jq empty
    [ "$(echo "$output" | jq -r '.review')" = "y" ]
}
