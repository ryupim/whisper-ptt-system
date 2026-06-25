#!/bin/bash
REC_WAV="/tmp/whisper_ptt.wav"
PIDFILE="/tmp/whisper_ptt.pid"
AUDIO_DEV=":1"   # ← さきほど確認したマイク番号に合わせる

# バックグラウンドで録音開始（nohup で親終了後も継続させる）
nohup ffmpeg -y -f avfoundation -i "$AUDIO_DEV" \
  -ar 16000 -ac 1 -loglevel quiet "$REC_WAV" >/dev/null 2>&1 &

echo $! > "$PIDFILE"   # ffmpeg の PID を保存（停止時に使う）
