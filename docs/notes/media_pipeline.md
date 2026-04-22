# 自動メディア生成パイプライン構想（trend-system）

**ステータス**: 構想段階 / `develop` ブランチで検討中
**最終更新**: 2026-04-22

## 目的

aitrends の各 Report から**自動で動画・音声を生成**し、
YouTube Shorts / Instagram Reels に試験投稿するパイプラインを構築する。
最終ゴールは「毎朝のレポート更新と同時に自動発信」。

## 入出力

### 入力
- 既存 Report（markdown / html）
- `ranking.json`（Top 5 の構造化データ）

### 出力
- ナレーション音声（mp3 / wav）
- 動画（mp4、縦型 9:16）
- 字幕ファイル（srt / vtt）
- SNS投稿用メタデータ（タイトル / 説明 / ハッシュタグ）

## パイプライン

### (1) 台本生成
- Report → ナレーション台本に要約
- 尺の目安: 60秒以内（Shorts/Reels想定）
- 口調・ペルソナ統一（Claudeに書かせる）

### (2) TTS
候補:
- ElevenLabs（品質高・有料）
- OpenAI TTS（多言語・中品質）
- VOICEVOX（ローカル・日本語・無料）
- TBD: 最初はVOICEVOXで試すか

### (3) ビジュアル
- **スライド型で確定**
- Report の要点を1枚/数秒で切り替え
- デザインは trend-reports のトーンに寄せる
- 実装候補: Remotion / HTML→画像書き出し / ffmpeg filter_complex
- TBD: 実装ツール選定

### (4) エンコード
- ffmpeg で音声 + 画像シーケンス → mp4
- 縦型 9:16（1080x1920）

### (5) 字幕
- 台本から直接生成（TTSの前段でテキスト確定）
- 話速と同期: TTSのtimestamp取得 or whisperでforce alignment

### (6) 投稿
- YouTube Data API v3（Shorts）
- Instagram Graph API（Reels）
- 最初は手動アップ → 動作確認後に自動化
- TBD: 認証・トークン管理方針

## 実行環境

空きマシン: castor / pollux / lyra
- TTS がローカル（VOICEVOX等）ならCPUで足りる
- 生成AI系ビジュアルならGPU必要
- TBD: 役割分担

## リスク

- **著作権**: Report内で引用した研究/画像の扱い
- **AI生成表記**: YT/Instagram側でAI生成コンテンツの明示義務
- **言語**: 日本語 / 英語 / 両方？ TBD
- **縦横比**: 9:16で両プラットフォーム統一OK

## MVP定義

「**1本目が公開できる**」を最初のゴールに:
- 1 Report → 台本 → TTS → スライド動画 → 手動でShortsアップ
- 全自動化はその次のフェーズ

## 未決事項

- TBD: TTSの選定（品質 vs コスト）
- TBD: スライド実装の技術選定
- TBD: 言語戦略（日本語のみ or 英語併用）
- TBD: SNS投稿自動化の実装タイミング
- TBD: castor/pollux/lyra の割り当て
