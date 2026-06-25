#!/bin/bash
# record_stop.sh — VAD付き文字起こし → 結果を標準出力へ（コピー/貼付けはHammerspoon側）
# 幻聴(無音時の「ありがとうございました」等)対策：VAD + フレーズのブラックリスト
set -u

# ===== 設定（自分の環境に合わせて変更）=====
REC_WAV="/tmp/whisper_ptt.wav"
WHISPER_DIR="$HOME/work/desktop-app/whisper.cpp"
MODEL="$WHISPER_DIR/models/ggml-large-v3-turbo.bin"
WHISPER_BIN="$WHISPER_DIR/build/bin/whisper-cli"
VAD_MODEL="$WHISPER_DIR/models/ggml-silero-v6.2.0.bin"   # download-vad-model.sh で取得
OUT_BASE="/tmp/whisper_ptt_out"
LOG="/tmp/whisper_ptt.log"

# whisper.cpp をビルド時と別の場所へ移動すると、whisper-cli に焼き込まれた
# rpath が旧パスを指したままで libwhisper/libggml 等の dylib を読めず Abort する。
# 新しい build 配下を dyld のフォールバック検索パスに追加して解決する。
# （export せず、後段の whisper-cli 起動時のみに付与する。helper には波及させない）
WBUILD="$WHISPER_DIR/build"
DYLD_FB="$WBUILD/src:$WBUILD/ggml/src:$WBUILD/ggml/src/ggml-blas:$WBUILD/ggml/src/ggml-metal:/usr/local/lib:/usr/lib"

# ログは毎回上書き（肥大化しない）
echo "===== $(date) =====" > "$LOG"

# 0) 存在チェック
[ -x "$WHISPER_BIN" ] || { echo "ERROR: whisper-cli not found: $WHISPER_BIN" >> "$LOG"; exit 1; }
[ -f "$MODEL" ]       || { echo "ERROR: model not found: $MODEL" >> "$LOG"; exit 1; }
[ -s "$REC_WAV" ]     || { echo "ERROR: wav empty/missing: $REC_WAV" >> "$LOG"; exit 1; }
echo "OK: WAV size = $(stat -f%z "$REC_WAV") bytes" >> "$LOG"

# VADモデルがあれば使う（無ければ警告だけ出して通常実行）
VAD_OPTS=()
if [ -f "$VAD_MODEL" ]; then
  VAD_OPTS=(--vad --vad-model "$VAD_MODEL"
            --vad-min-speech-duration-ms 250
            --vad-min-silence-duration-ms 100)
else
  echo "WARN: VAD model not found ($VAD_MODEL). VADなしで実行します。" >> "$LOG"
fi

# 1) 文字起こし（出力は全部ログへ）
DYLD_FALLBACK_LIBRARY_PATH="$DYLD_FB" "$WHISPER_BIN" \
  -m "$MODEL" \
  -f "$REC_WAV" \
  -l ja \
  -nt \
  "${VAD_OPTS[@]}" \
  -otxt -of "$OUT_BASE" \
  -fa >> "$LOG" 2>&1
echo "whisper-cli rc: $?" >> "$LOG"

# 2) 出力チェック
[ -s "$OUT_BASE.txt" ] || { echo "ERROR: result empty: $OUT_BASE.txt" >> "$LOG"; exit 1; }

# 3) 整形
TEXT="$(sed -e 's/^[[:space:]]*//' "$OUT_BASE.txt" | tr -d '\r')"
# 末尾の句点・空白を除いた比較用の文字列
CMP="$(printf '%s' "$TEXT" | sed -e 's/[[:space:]。、!?！？]*$//')"

# 4) 既知の幻聴フレーズ/空なら捨てる
case "$CMP" in
  ""|"ありがとうございました"|"ご視聴ありがとうございました"|"ご清聴ありがとうございました"|\
  "おわり"|"終わり"|"バイバイ"|"はい"|"うん"|"えー"|"チャンネル登録お願いします")
    echo "SKIP: hallucination/empty -> [$TEXT]" >> "$LOG"
    exit 1
    ;;
esac

echo "RESULT -> $TEXT" >> "$LOG"

# 5) 結果テキストを標準出力へ（Hammerspoonが受け取って入力する）
printf '%s' "$TEXT"
exit 0
