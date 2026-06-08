# strip-codex-frontmatter.awk
# frontmatter (先頭 --- 〜 2番目の --- の間) から codex_review / codex_importance
# 行を除去する。本文中に同名トークンがあっても触らない。
# 用途: Step 3.4 (Step 3 の claude -p が前回参照で複製した値を剥がす)。
#
# Usage: awk -f strip-codex-frontmatter.awk input.md
BEGIN { c = 0 }
/^---$/ { c++; print; next }
c == 1 && /^codex_review:[[:space:]]/ { next }
c == 1 && /^codex_importance:[[:space:]]/ { next }
{ print }
