-- ============================================================
-- Whisper Push-To-Talk (Fn キーで押し話し → 文字起こし → コピー)
-- ============================================================

-- ===== 設定（自分の環境に合わせて変更）=====
local FFMPEG    = "/opt/homebrew/bin/ffmpeg"   -- ターミナルで `which ffmpeg` を実行して確認。
                                               -- Intel Mac なら多くは /usr/local/bin/ffmpeg
local REC_WAV   = "/tmp/whisper_ptt.wav"
local scriptDir = os.getenv("HOME") .. "/work/desktop-app/whisper-ptt-system/whisper-ptt"
local AUDIO_DEV = ":1"                          -- マイク番号。ffmpeg -f avfoundation -list_devices true -i "" で確認

-- ===== メニューバー =====
local mic = hs.menubar.new()

-- 画面左下に小さく出るトースト通知（数秒で自動的に消える）
local function notify(text)
  local f = hs.screen.mainScreen():frame()   -- Dock/メニューバーを除いた表示領域
  local w, h, margin = 280, 30, 16
  local c = hs.canvas.new({
    x = f.x + margin,
    y = f.y + f.h - h - margin,               -- 左下に配置
    w = w, h = h,
  })
  c[1] = { type = "rectangle", action = "fill",
           fillColor = { red = 0, green = 0, blue = 0, alpha = 0.78 },
           roundedRectRadii = { xRadius = 6, yRadius = 6 } }
  c[2] = { type = "text", text = text,
           textColor = { white = 1 }, textSize = 13,
           frame = { x = 10, y = 6, w = w - 20, h = h - 10 } }
  c:level(hs.canvas.windowLevels.overlay)     -- 他のウィンドウより前面に
  c:show()
  hs.timer.doAfter(2.5, function() c:delete() end)  -- 2.5秒後に消す
end

local STATES = {
  idle = { title = "🎙️" },
  rec  = { title = "🔴" },
  busy = { title = "⏳" },
  done = { title = "✅" },
}

local function setState(name)
  local s = STATES[name] or STATES.idle
  mic:setTitle(s.title)
end

setState("idle")  -- 起動時の表示

-- ===== ドロップダウンメニュー =====
mic:setMenu({
  { title = "🎙️ Whisper 音声入力", disabled = true },
  { title = "-" },
  { title = "テスト録音（3秒）", fn = function()
      hs.task.new(FFMPEG, nil,
        {"-y", "-f", "avfoundation", "-i", AUDIO_DEV,
         "-t", "3", "/tmp/mictest.wav"}):start()
    end },
  { title = "設定を再読み込み", fn = function() hs.reload() end },
  { title = "-" },
  { title = "終了", fn = function() hs.application.get("Hammerspoon"):kill() end },
})

-- ===== 録音制御 =====
local recTask  = nil    -- ★ local 宣言（グローバル化を防ぐ）
local stopping = false  -- ★ 停止要求フラグ。ffmpeg 終了コールバックで文字起こしを起動する

-- 文字起こし＋クリップボードコピー＋自動入力。
-- ★ 必ず ffmpeg が完全終了し WAV がディスクへ flush された後に呼ぶこと。
local function transcribe()
  hs.task.new("/bin/bash", function(code, out, err)
    if code == 0 and out and #out > 0 then
      hs.pasteboard.setContents(out)   -- ★ pbcopy ではなく Hammerspoon が直接コピー
      setState("done")
      hs.eventtap.keyStrokes(out)        -- ★ 認識テキストを直接入力
      hs.timer.doAfter(1.2, function() setState("idle") end)  -- ✅ を 1.2秒後に元へ戻す
    else
      notify("out is empty")
      setState("idle")                   -- 失敗時は即 idle（戻し用タイマー不要）
    end
  end, {scriptDir .. "/record_stop.sh"}):start()
end

local function startRec()
  if recTask then return end
  setState("rec")
  stopping = false
  -- ★ ffmpeg は録音データを内部バッファに保持し、プロセス終了（close）時に
  --    初めて WAV をディスクへ flush する。そのため「terminate 後に固定時間
  --    待ってから文字起こし」だと WAV がまだ空でレースし「out is empty」になる。
  --    完了コールバック（＝ffmpeg が実際に終了し flush 済みの時点）で起動して確実にする。
  recTask = hs.task.new(FFMPEG, function(code, out, err)
    recTask = nil
    if stopping then
      stopping = false
      transcribe()        -- ffmpeg 終了＝WAV flush 済み。ここで初めて文字起こし
    else
      setState("idle")    -- 想定外の終了（録音中に ffmpeg が落ちた等）
    end
  end, {"-y", "-f", "avfoundation", "-i", AUDIO_DEV,
        "-ar", "16000", "-ac", "1", "-loglevel", "quiet", REC_WAV})

  -- ★ ffmpeg のパスが間違っていると hs.task.new が nil を返す。
  --    その場合に黙って 🔴 のまま固まらないよう、ここで気づけるようにする。
  if not recTask then
    hs.alert.show("⚠️ ffmpeg が見つかりません:\n" .. tostring(FFMPEG))
    setState("idle")
    return
  end
  recTask:start()
end

local function stopRec()
  if not recTask then return end
  stopping = true
  setState("busy")
  recTask:terminate()   -- ffmpeg を停止。終了コールバックで transcribe() が走る
end

-- ===== Fn キーの押下/解放を flagsChanged で監視 =====
-- ===== Fn キーの押下/解放を監視（GC・スリープ対策込み）=====
-- ★ local をやめてグローバルにし、GC による回収を防ぐ
fnDown = false
fnTap = hs.eventtap.new({hs.eventtap.event.types.flagsChanged}, function(e)
  local flags = e:getFlags()
  if flags.fn and not fnDown then
    fnDown = true
    startRec()
  elseif not flags.fn and fnDown then
    fnDown = false
    stopRec()
  end
  return false
end)
fnTap:start()

-- ★ ウォッチドッグ：5秒ごとに tap が有効か確認し、無効なら再起動
fnWatchdog = hs.timer.doEvery(5, function()
  if fnTap and not fnTap:isEnabled() then
    fnTap:start()
    notify("入力監視を再起動しました")
  end
end)

-- ★ スリープ復帰時に tap を確実に再起動
caffeineWatcher = hs.caffeinate.watcher.new(function(eventType)
  if eventType == hs.caffeinate.watcher.systemDidWake
     or eventType == hs.caffeinate.watcher.screensDidWake then
    if fnTap then fnTap:start() end
  end
end)
caffeineWatcher:start()

