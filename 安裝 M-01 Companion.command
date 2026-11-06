#!/bin/bash
# M-01 Companion 安裝程式
SRC="$(cd "$(dirname "$0")"; pwd)"
# builds the native app window ($1 = app path, $2 = port, $3 = bundle id suffix)
build_app(){
  local APP="$1" PORT="$2" SUF="$3" TMPJS
  TMPJS="$(mktemp -t m01shell).js"
  sed -e "s|__PORT__|$PORT|" -e "s|__DATA__|~/Documents/Companion|" "$SRC/shell.js" > "$TMPJS"
  rm -rf "$APP"
  /usr/bin/osacompile -l JavaScript -s -o "$APP" "$TMPJS" || { echo "建立 App 失敗"; exit 1; }
  rm -f "$TMPJS"
  mkdir -p "$APP/Contents/Resources/web"
  cp "$SRC/index.html" "$APP/Contents/Resources/web/index.html"
  cp "$SRC/server.pl" "$APP/Contents/Resources/server.pl"
  cp "$SRC/AppIcon.icns" "$APP/Contents/Resources/applet.icns"
  # newer macOS applets take their icon from Assets.car; drop it so our icon is used
  rm -f "$APP/Contents/Resources/Assets.car"
  local PL="$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier local.m01.companion$SUF" "$PL" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string local.m01.companion$SUF" "$PL"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName M-01 Companion" "$PL" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" "$PL" 2>/dev/null || true
  # allow the microphone and speech recognition inside the app window
  /usr/libexec/PlistBuddy -c "Delete :NSMicrophoneUsageDescription" "$PL" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :NSMicrophoneUsageDescription string 用麥克風讓你直接用說的跟她聊天" "$PL"
  /usr/libexec/PlistBuddy -c "Delete :NSSpeechRecognitionUsageDescription" "$PL" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :NSSpeechRecognitionUsageDescription string 把你說的話轉成文字" "$PL"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile applet" "$PL" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string applet" "$PL"
  /usr/bin/codesign --force --deep -s - "$APP" >/dev/null 2>&1 || true
  touch "$APP"
  # refresh the Finder / Dock icon cache for this app
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true
  # restart the helper so it serves the files of this build
  pkill -f "server.pl.* $PORT\$" >/dev/null 2>&1 || true
}
echo "== 安裝 M-01 Companion =="
# local AI (Ollama) is optional: without it the app uses Gemini or Claude
HAS_OLLAMA=0; { [ -d "/Applications/Ollama.app" ] || [ -d "$HOME/Applications/Ollama.app" ] || command -v ollama >/dev/null 2>&1; } && HAS_OLLAMA=1
DEST="/Applications"; [ -w "$DEST" ] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }
mkdir -p "$HOME/Documents/Companion"
# if Ollama is installed, make sure it is running and see whether a model is already there
OLL="$(command -v ollama || echo /Applications/Ollama.app/Contents/Resources/ollama)"
HAVE_MODEL=0
if [ "$HAS_OLLAMA" = "1" ]; then
  if ! curl -s -m 2 http://localhost:11434/api/tags >/dev/null 2>&1; then
    open -a Ollama >/dev/null 2>&1
    for i in $(seq 1 40); do curl -s -m 2 http://localhost:11434/api/tags >/dev/null 2>&1 && break; sleep 1; done
  fi
  curl -s -m 5 http://localhost:11434/api/tags | grep -qE '"qwen3\.5:(4b|9b|27b)"|"qwen2\.5:(7b|3b)"' && HAVE_MODEL=1
fi
if [ "$HAVE_MODEL" = "1" ]; then
  echo "已經有本地 AI 模型，跳過下載。"
else
  echo ""
  RAMGB=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 ))
  REC=1; [ "$RAMGB" -gt 0 ] && [ "$RAMGB" -lt 14 ] && REC=2
  echo "要不要安裝本地 AI？（免費、不用網路，但要佔硬碟空間）"
  echo "  1) 標準版 qwen3.5:9b — 約 6.6GB，適合 16GB 以上的 Mac"
  echo "  2) 輕量版 qwen3.5:4b — 約 3.3GB，適合 8GB 的 Mac，但比較容易答錯"
  echo "  3) 不要本地 AI — 只用 Gemini（免費金鑰）或 Claude，最省空間"
  [ "$RAMGB" -gt 0 ] && echo "你的 Mac 有 ${RAMGB}GB 記憶體，建議選 $REC。（32GB 以上的 Mac 可以之後在 App 的「設定 → AI」下載強力版）"
  CH=""; read -r -p "輸入 1、2 或 3 再按 Enter（直接按 Enter 就是 $REC）： " CH </dev/tty || true
  [ -z "$CH" ] && CH=$REC
  if [ "$CH" = "3" ]; then
    echo "好，不安裝本地 AI。打開 App 後貼上免費的 Gemini 金鑰就能開始；之後想要本地 AI，可以在「設定 → AI」下載。"
  else
    MODEL="qwen3.5:9b"; [ "$CH" = "2" ] && MODEL="qwen3.5:4b"
    if [ "$HAS_OLLAMA" = "1" ]; then
      echo "正在下載 $MODEL（第一次需要幾分鐘）..."
      "$OLL" pull "$MODEL" || echo "⚠️ 模型下載沒有完成。可能是 Ollama 版本太舊：到 https://ollama.com/download 更新後，在 App 的「設定 → AI」再下載就好。"
    else
      echo "本地 AI 需要先安裝 Ollama，正在打開下載頁面。"
      echo "裝好並打開 Ollama 後，到 App 的「設定 → AI」按「下載」就好，不用重新安裝 App。"
      open "https://ollama.com/download"
    fi
  fi
fi
build_app "$DEST/M-01 Companion.app" 47811 ""
# keep Ollama accepting this app after every restart
AGENT="$HOME/Library/LaunchAgents/local.m01.ollama-origins.plist"; mkdir -p "$HOME/Library/LaunchAgents"
cat > "$AGENT" <<'AG'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Label</key><string>local.m01.ollama-origins</string>
<key>ProgramArguments</key><array><string>/bin/launchctl</string><string>setenv</string><string>OLLAMA_ORIGINS</string><string>*</string></array>
<key>RunAtLoad</key><true/></dict></plist>
AG
launchctl unload "$AGENT" >/dev/null 2>&1; launchctl load "$AGENT" >/dev/null 2>&1
rm -rf "$HOME/Library/Application Support/M-01 Companion/browser"
echo "已安裝版本：$(grep -o 'APP_VER="[0-9.]*"' "$SRC/index.html" | head -1 | cut -d\" -f2)（打開 App 後點右上角 ⓘ 應該也是這個版本）"
echo "✅ 安裝完成：$DEST/M-01 Companion.app"
open "$DEST/M-01 Companion.app"
