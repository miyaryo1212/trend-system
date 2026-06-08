# inject-pipeline-warnings.awk
# frontmatter の閉じ --- 直前に pipeline_warnings 配列を注入する。
# 各警告は YAML ダブルクォート文字列としてエスケープする (\ → \\, " → \")。
# 用途: Step 3.7 (Step 1/2/3.5/3.6 で記録された警告をまとめて frontmatter 化)。
#
# 変数:
#   wf — 警告メッセージを1行1件で並べたファイルのパス
#
# Usage: awk -v wf="$WARNINGS_FILE" -f inject-pipeline-warnings.awk input.md
BEGIN { c = 0; injected = 0 }
/^---$/ {
    c++
    if (c == 2 && !injected) {
        print "pipeline_warnings:"
        while ((getline line < wf) > 0) {
            gsub(/\\/, "\\\\", line)
            gsub(/"/, "\\\"", line)
            print "  - \"" line "\""
        }
        close(wf)
        injected = 1
    }
}
{ print }
