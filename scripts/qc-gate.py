#!/usr/bin/env python3
"""
qc-gate.py — レポート生成直後のステイル検知ゲート (Step 3.8)

生成されたレポートの frontmatter `features` と本文を解析し、

  - 本文中の「(前回から継続)」表記の数
  - `features` の前日 / 2日前レポートとの重複数

をしきい値判定する。「実質的に新規情報なし」と判定したら理由を stdout に出力し
exit 2 を返す。run.sh はこれを pipeline_warnings に変換する (publish を止める
block ではなく、当日記事は出しつつ警告バナーで flag する warn 方式)。

背景: 2026-05 に Step 3 prompt の「重複は (前回から継続) と注記して残す」設計と
Step 1 が previous_report を見ていない問題が重なり、本文の大半が続報で埋まった
レポートが2週間量産され13件削除する事態になった。再発を生成時点で検知するための
ゲート。

Usage:
  qc-gate.py <report.md> [--reports-dir DIR]

Exit:
  0 = OK
  2 = stale (warn)
  1 = error (パース失敗等)
"""
import argparse
import re
import sys
from datetime import date, timedelta
from pathlib import Path

# ---- しきい値 (2026-05 の削除実績データから調整。健全な記事は発火させず、
#      削除対象13件は全て捕捉する水準) ----
CONT_ABS = 7              # 継続表記がこの数以上で単独ステイル
CONT_LOWFEAT = 5          # features が少ない日の継続表記しきい値
LOWFEAT_MAX = 3           # 「features が少ない」の上限
CONT_RATIO = 1.5          # 継続表記 >= features * この比率でステイル
DUP_PREV1_RATIO = 0.7     # 前日 features 重複がこの比率以上でステイル
ACADEMIA_DUP2_RATIO = 0.8 # academia 専用: 2日前 features 重複比率


def parse_report(path: Path):
    """frontmatter features + 本文を抽出。無効なら None。"""
    if not path.exists():
        return None
    text = path.read_text(encoding="utf-8", errors="replace")
    m = re.match(r"---\n(.*?)\n---\n(.*)", text, re.DOTALL)
    if not m:
        return None
    fm, body = m.group(1), m.group(2)
    feats = []
    in_feats = False
    for line in fm.split("\n"):
        if line.startswith("features:"):
            in_feats = True
            continue
        if in_feats:
            if line.startswith("  - "):
                feats.append(line[4:].strip().strip('"'))
            elif line and not line.startswith(" "):
                in_feats = False
    continuations = len(re.findall(r"[（(]前回から継続[）)]", body))
    return {"features": feats, "continuations": continuations}


def feature_match(a: str, b: str) -> bool:
    """完全一致 or 一方が他方を包含 (短いノイズ語の誤検出は長さ>5でガード)。"""
    if a == b:
        return True
    if a and b and min(len(a), len(b)) > 5:
        return a in b or b in a
    return False


def dup_count(curr_feats, prev) -> int:
    if not prev:
        return 0
    return sum(1 for f in curr_feats if any(feature_match(f, pf) for pf in prev["features"]))


def parse_slug(report_path: Path):
    """ファイル名 YYYY-MM-DD-channel.md から (date, channel) を取り出す。"""
    m = re.match(r"(\d{4})-(\d{2})-(\d{2})-(.+)\.md$", report_path.name)
    if not m:
        return None, None
    y, mo, da, channel = m.groups()
    return date(int(y), int(mo), int(da)), channel


def evaluate(report_path: Path, reports_dir: Path):
    """ステイル判定。(is_stale, reasons) を返す。"""
    r = parse_report(report_path)
    if r is None:
        raise ValueError(f"cannot parse report frontmatter: {report_path}")

    d, channel = parse_slug(report_path)
    prev1 = prev2 = None
    if d and channel:
        prev1 = parse_report(reports_dir / f"{(d - timedelta(1)).isoformat()}-{channel}.md")
        prev2 = parse_report(reports_dir / f"{(d - timedelta(2)).isoformat()}-{channel}.md")

    nf = len(r["features"])
    cont = r["continuations"]
    d1 = dup_count(r["features"], prev1)
    d2 = dup_count(r["features"], prev2)

    reasons = []
    if cont >= CONT_ABS:
        reasons.append(f"継続表記が{cont}件 (>= {CONT_ABS})")
    if nf <= LOWFEAT_MAX and cont >= CONT_LOWFEAT:
        reasons.append(f"features={nf}件と少ないのに継続表記が{cont}件 (>= {CONT_LOWFEAT})")
    if nf >= 2 and cont >= nf * CONT_RATIO:
        reasons.append(f"継続表記{cont}件が features{nf}件の{CONT_RATIO}倍以上 (本文の主体が再掲)")
    if nf >= 3 and d1 >= nf * DUP_PREV1_RATIO:
        reasons.append(f"features {nf}件中 {d1}件が前日レポートと重複 ({int(d1/nf*100)}%)")
    if channel == "academia" and nf >= 5 and d2 >= nf * ACADEMIA_DUP2_RATIO:
        reasons.append(f"academia: features {nf}件中 {d2}件が2日前と重複 (HF API が同一論文を再返却した可能性)")

    return bool(reasons), reasons


def main():
    ap = argparse.ArgumentParser(description="レポートのステイル検知ゲート (Step 3.8)")
    ap.add_argument("report", help="判定対象のレポート .md パス")
    ap.add_argument("--reports-dir", default=None,
                    help="前日比較用の content/reports ディレクトリ (省略時はレポートの親)")
    args = ap.parse_args()

    report_path = Path(args.report)
    reports_dir = Path(args.reports_dir) if args.reports_dir else report_path.parent

    try:
        is_stale, reasons = evaluate(report_path, reports_dir)
    except ValueError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)

    if is_stale:
        # run.sh が pipeline_warnings に流し込む1行メッセージ
        detail = " / ".join(reasons)
        print(f"Step 3.8 (QC) で本記事がステイル (新規情報が乏しい) と判定されました: {detail}。"
              f"本文の多くが前日以前の続報の可能性があります。")
        sys.exit(2)
    sys.exit(0)


if __name__ == "__main__":
    main()
