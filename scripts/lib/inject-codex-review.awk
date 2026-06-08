# inject-codex-review.awk
# frontmatter の閉じ --- 直前に codex_review / codex_importance を注入する。
# 用途: Step 3.5 (codex exec 成功時に本物の Codex 評価を載せる)。
#
# 変数:
#   review — codex_review の値 (呼び出し側で " を \" にエスケープ済みであること)
#   imp    — codex_importance の値 (空なら出力しない)
#
# Usage: awk -v review="$REVIEW_ESC" -v imp="$IMP" -f inject-codex-review.awk input.md
BEGIN { c = 0; injected = 0 }
/^---$/ {
    c++
    if (c == 2 && !injected) {
        print "codex_review: \"" review "\""
        if (imp != "") print "codex_importance: " imp
        injected = 1
    }
}
{ print }
