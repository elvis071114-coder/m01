// M-01 Companion native window (JavaScript for Automation, compiled into a stay-open applet).
// Shows the app in its own window with its own Dock icon; no Chrome needed.
ObjC.import('Cocoa');
ObjC.import('WebKit');

var PORT = __PORT__;
var DATA_DIR = '__DATA__';
var sys = Application.currentApplication();
sys.includeStandardAdditions = true;
var win = null, web = null;

function sh(cmd) { try { return sys.doShellScript(cmd); } catch (e) { return ''; } }
function q(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'"; }

function startServices() {
  var res = $.NSBundle.mainBundle.resourcePath.js;
  var data = DATA_DIR.replace(/^~/, sh('echo $HOME'));
  sh('mkdir -p ' + q(data));
  // local helper that serves the app and reads/writes the memory folder
  if (sh('curl -s -m 1 -H "X-M01: 1" http://127.0.0.1:' + PORT + '/ping') === '') {
    sh('nohup /usr/bin/perl ' + q(res + '/server.pl') + ' ' + q(res + '/web') + ' ' + q(data) + ' ' + PORT + ' ' + q(String($.NSBundle.mainBundle.bundleIdentifier.js || '')) + ' >/dev/null 2>&1 &');
    for (var i = 0; i < 30; i++) { if (sh('curl -s -m 1 -H "X-M01: 1" http://127.0.0.1:' + PORT + '/ping') !== '') break; delay(0.3); }
  }
  // Ollama: start it and make sure it accepts requests from this window
  sh('launchctl setenv OLLAMA_ORIGINS "*"');
  var up = function () { return sh('curl -s -m 2 http://localhost:11434/api/tags') !== ''; };
  // local AI is optional: only start / wait for Ollama when it is installed
  var hasOllama = sh('{ [ -d /Applications/Ollama.app ] || [ -d "$HOME/Applications/Ollama.app" ] || command -v ollama >/dev/null 2>&1; } && echo y') === 'y';
  if (!hasOllama) return;
  if (!up()) { sh('open -a Ollama'); for (var j = 0; j < 30 && !up(); j++) delay(1); }
  if (!up()) return;
  var code = sh('curl -s -m 2 -o /dev/null -w "%{http_code}" -H "Origin: http://127.0.0.1:' + PORT + '" http://localhost:11434/api/tags');
  if (code === '403') {
    sh('osascript -e \'quit app "Ollama"\''); delay(2); sh('open -a Ollama');
    for (var k = 0; k < 30 && !up(); k++) delay(1);
  }
}

function openWindow() {
  if (win) { win.makeKeyAndOrderFront(null); $.NSApp.activateIgnoringOtherApps(true); return; }
  var rect = $.NSMakeRect(0, 0, 1440, 900);
  // titled | closable | miniaturizable | resizable
  win = $.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer(rect, 15, 2, false);
  win.releasedWhenClosed = false;
  win.title = 'M-01 Companion';
  win.minSize = $.NSMakeSize(900, 600);
  win.backgroundColor = $.NSColor.colorWithSRGBRedGreenBlueAlpha(0.035, 0.035, 0.043, 1);
  var conf = $.WKWebViewConfiguration.alloc.init;
  conf.mediaTypesRequiringUserActionForPlayback = 0;   // allow boot / button sounds
  web = $.WKWebView.alloc.initWithFrameConfiguration(rect, conf);
  web.autoresizingMask = 18;                            // width + height sizable
  win.contentView = web;
  win.center;
  win.makeKeyAndOrderFront(null);
  $.NSApp.activateIgnoringOtherApps(true);
  web.loadRequest($.NSURLRequest.requestWithURL($.NSURL.URLWithString('http://127.0.0.1:' + PORT + '/?app=1')));
}

// called by the helper (/dictate): opens macOS dictation for the focused text box
function dictate() {
  if (win) { win.makeKeyAndOrderFront(null); $.NSApp.activateIgnoringOtherApps(true); }
  $.NSApp.sendActionToFrom('startDictation:', $(), $());
  return 'ok';
}

function run() { startServices(); openWindow(); }
function reopen() { openWindow(); }
