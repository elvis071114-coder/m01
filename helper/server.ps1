# M-01 Companion local helper for Windows: serves the app and reads/writes the memory folder.
# Listens on 127.0.0.1 only. Uses only what ships with Windows PowerShell 5.1.
param([string]$WebRoot, [string]$DataDir, [int]$Port = 47811)
$DataDirArg = $DataDir
$HelperOvr = Join-Path $env:LOCALAPPDATA 'M-01 Companion\helper'; if ($env:M01_HELPEROVR) { $HelperOvr = $env:M01_HELPEROVR }
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'   # Windows PowerShell 5.1 downloads many times slower while it draws a (hidden) progress bar
try { [Net.ServicePointManager]::DefaultConnectionLimit = 16; [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
# the user can move the memory folder from inside the app; remember their choice
$CfgFile = Join-Path $env:LOCALAPPDATA 'M-01 Companion\datadir.txt'
if (Test-Path -LiteralPath $CfgFile) { $saved = ([IO.File]::ReadAllText($CfgFile, [Text.Encoding]::UTF8)).Trim(); if ($saved -and (Test-Path -LiteralPath $saved)) { $DataDir = $saved } }
$KeyFile = Join-Path $env:LOCALAPPDATA 'M-01 Companion\claude_key.txt'
$GemKeyFile = Join-Path $env:LOCALAPPDATA 'M-01 Companion\gemini_key.txt'
$FishKeyFile = Join-Path $env:LOCALAPPDATA 'M-01 Companion\fish_key.txt'
$GoogFile = Join-Path $env:LOCALAPPDATA 'M-01 Companion\google_token.txt'
$GCodeFile = Join-Path $env:LOCALAPPDATA 'M-01 Companion\google_code.txt'
$GTokUrl = 'https://oauth2.googleapis.com/token'; if ($env:M01_GTOKEN_URL) { $GTokUrl = $env:M01_GTOKEN_URL }
# desktop-app sign-in client secret: kept in gclient.txt next to the app (not inside this file, which is also published for self-update)
$GSecret = ''
foreach ($gf in @((Join-Path (Split-Path -Parent $WebRoot) 'gclient.txt'), (Join-Path $env:LOCALAPPDATA 'M-01 Companion\app\gclient.txt'))) { if ($gf -and (Test-Path -LiteralPath $gf)) { $GSecret = ([IO.File]::ReadAllText($gf)).Trim(); if ($GSecret) { break } } }
$WebOvr = Join-Path $env:LOCALAPPDATA 'M-01 Companion\web'
$HV = 8   # helper version: the page asks for a reinstall when a newer helper is needed
function Page-Ver([string]$t) { $m = [regex]::Match([string]$t, 'const APP_VER="(\d+)\.(\d+)\.(\d+)"'); if ($m.Success) { return ([int]$m.Groups[1].Value)*1000000 + ([int]$m.Groups[2].Value)*1000 + [int]$m.Groups[3].Value }; return 0 }
$DataMark = [regex]::Unescape('_\u8cc7\u6599\uff08\u8acb\u52ff\u4fee\u6539\uff09')
if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }
$DataDir = (Resolve-Path $DataDir).Path
$utf8 = New-Object System.Text.UTF8Encoding($false)
$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Parse('127.0.0.1'), $Port)
try { $listener.Start() } catch { exit 1 }

$Types = @{ html='text/html; charset=utf-8'; js='text/javascript'; css='text/css'; json='application/json'; png='image/png'; ico='image/x-icon'; md='text/markdown; charset=utf-8' }

function Send-Reply($stream, [int]$code, [string]$type, [byte[]]$body) {
  if ($null -eq $body) { $body = [byte[]]@() }
  $msg = @{200='OK';204='No Content';400='Bad Request';403='Forbidden';404='Not Found';405='Method Not Allowed'}[$code]
  $head = "HTTP/1.1 $code $msg`r`nContent-Type: $type`r`nContent-Length: $($body.Length)`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n"
  $hb = [System.Text.Encoding]::ASCII.GetBytes($head)
  $stream.Write($hb, 0, $hb.Length)
  if ($body.Length -gt 0) { $stream.Write($body, 0, $body.Length) }
}
function Send-Text($stream, [int]$code, [string]$type, [string]$text) { Send-Reply $stream $code $type ($utf8.GetBytes($text)) }
function Json-Str([string]$s) { return ($s | ConvertTo-Json -Compress) }
function Safe-Rel([string]$raw) {
  $p = [System.Uri]::UnescapeDataString($raw).TrimStart('/')
  foreach ($seg in $p.Split('/')) { if ($seg -eq '..' -or $seg -eq '.') { return $null } }
  if ($p -match '[\x00]') { return $null }
  return $p
}
function Html-Text([string]$h) {
  $h = [regex]::Replace($h, '(?is)<(script|style|noscript|svg|head)\b.*?</\1>', ' ')
  $h = [regex]::Replace($h, '(?i)<br\s*/?>|</p>|</div>|</li>|</h\d>', "`n")
  $h = [regex]::Replace($h, '<[^>]+>', ' ')
  $h = [System.Net.WebUtility]::HtmlDecode($h)
  $h = [regex]::Replace($h, '[ \t\r\f]+', ' ')
  $h = [regex]::Replace($h, '\n\s*\n+', "`n")
  return $h.Trim()
}
function Fetch-Url([string]$url, [int]$secs) {
  if ($url -notmatch '^https?://') { return $null }
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec $secs -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'
    return [string]$r.Content
  } catch { return $null }
}
# ---------- music: what is playing (Spotify first) through the Windows media controls, and the Spotify volume in the volume mixer ----------
$script:MediaOk = $null
function Await-Op($op, [Type]$t) {
  $task = $script:AsTaskG.MakeGenericMethod($t).Invoke($null, @($op))
  if (-not $task.Wait(3000)) { return $null }
  return $task.Result
}
function Media-Init {
  if ($null -ne $script:MediaOk) { return $script:MediaOk }
  try {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $script:AsTaskG = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
    $null = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime]
    $null = [Windows.Storage.Streams.IRandomAccessStreamWithContentType, Windows.Storage.Streams, ContentType = WindowsRuntime]
    $null = [Windows.Storage.Streams.DataReader, Windows.Storage.Streams, ContentType = WindowsRuntime]
    $script:MediaMgr = Await-Op ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])
    $script:MediaOk = ($null -ne $script:MediaMgr)
  } catch { $script:MediaOk = $false }
  return $script:MediaOk
}
# which player to show: whatever is playing right now wins (YouTube in a browser, Spotify, ...).
# When nothing plays, stay on the one shown before, so Play resumes the same thing.
$script:MediaSid = ''
function Media-Playing($x) { try { return ([string]$x.GetPlaybackInfo().PlaybackStatus -eq 'Playing') } catch { return $false } }
function Media-Session {
  $all = @($script:MediaMgr.GetSessions() | Where-Object { $_ })
  if ($all.Count -eq 0) { $script:MediaSid = ''; return $null }
  $pick = $null
  $playing = @($all | Where-Object { Media-Playing $_ })
  if ($playing.Count -gt 0) {
    $pick = $playing | Where-Object { [string]$_.SourceAppUserModelId -eq $script:MediaSid } | Select-Object -First 1
    if (-not $pick) { $cur = $script:MediaMgr.GetCurrentSession(); if ($cur -and (Media-Playing $cur)) { $pick = $cur } }
    if (-not $pick) { $pick = $playing | Where-Object { [string]$_.SourceAppUserModelId -match 'Spotify' } | Select-Object -First 1 }
    if (-not $pick) { $pick = $playing[$playing.Count - 1] }
  } else {
    if ($script:MediaSid) { $pick = $all | Where-Object { [string]$_.SourceAppUserModelId -eq $script:MediaSid } | Select-Object -First 1 }
    if (-not $pick) { $pick = $script:MediaMgr.GetCurrentSession() }
    if (-not $pick) { $pick = $all | Where-Object { [string]$_.SourceAppUserModelId -match 'Spotify' } | Select-Object -First 1 }
    if (-not $pick) { $pick = $all[0] }
  }
  if ($pick) { $script:MediaSid = [string]$pick.SourceAppUserModelId }
  return $pick
}
$script:VolReady = $null
function Vol-Init {
  if ($null -ne $script:VolReady) { return $script:VolReady }
  try {
    Add-Type -Language CSharp -TypeDefinition @"
using System; using System.Runtime.InteropServices;
namespace M01Audio {
  [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IMMDeviceEnumerator { int NotImpl1(); [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice dev); }
  [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IMMDevice { [PreserveSig] int Activate(ref Guid iid, int ctx, IntPtr p, [MarshalAs(UnmanagedType.IUnknown)] out object o); }
  [ComImport, Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IAudioSessionManager2 { int NotImpl1(); int NotImpl2(); [PreserveSig] int GetSessionEnumerator(out IAudioSessionEnumerator e); }
  [ComImport, Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IAudioSessionEnumerator { [PreserveSig] int GetCount(out int n); [PreserveSig] int GetSession(int i, out IAudioSessionControl2 s); }
  [ComImport, Guid("bfb7ff88-7239-4fc9-8fa2-07c950be9c6d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IAudioSessionControl2 { int N1(); int N2(); int N3(); int N4(); int N5(); int N6(); int N7(); int N8(); int N9(); int N10(); int N11(); [PreserveSig] int GetProcessId(out uint pid); }
  [ComImport, Guid("87CE5498-68D6-44E5-9215-6DA47EF883D8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface ISimpleAudioVolume { [PreserveSig] int SetMasterVolume(float v, ref Guid ctx); [PreserveSig] int GetMasterVolume(out float v); }
  [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumerator { }
  public static class Mixer {
    // volume (0-100) of the first audio session that belongs to one of these processes; -1 if none
    public static int Run(int[] pids, int set) {
      IMMDeviceEnumerator en = (IMMDeviceEnumerator)(new MMDeviceEnumerator());
      IMMDevice dev; if (en.GetDefaultAudioEndpoint(0, 1, out dev) != 0) return -1;
      Guid iid = typeof(IAudioSessionManager2).GUID; object o;
      if (dev.Activate(ref iid, 23, IntPtr.Zero, out o) != 0) return -1;
      IAudioSessionEnumerator list; if (((IAudioSessionManager2)o).GetSessionEnumerator(out list) != 0) return -1;
      int n; list.GetCount(out n); int found = -1;
      for (int i = 0; i < n; i++) {
        IAudioSessionControl2 s; if (list.GetSession(i, out s) != 0 || s == null) continue;
        uint pid; s.GetProcessId(out pid);
        if (Array.IndexOf(pids, (int)pid) < 0) continue;
        ISimpleAudioVolume v = s as ISimpleAudioVolume; if (v == null) continue;
        Guid g = Guid.Empty;
        if (set >= 0) v.SetMasterVolume(Math.Max(0, Math.Min(100, set)) / 100f, ref g);
        float cur; v.GetMasterVolume(out cur); if (found < 0) found = (int)Math.Round(cur * 100);
      }
      return found;
    }
  }
}
"@
    $script:VolReady = $true
  } catch { $script:VolReady = $false }
  return $script:VolReady
}
function Spotify-Volume([int]$set) {
  $pids = @(Get-Process -Name Spotify -ErrorAction SilentlyContinue | ForEach-Object { [int]$_.Id })
  if ($pids.Count -eq 0 -or -not (Vol-Init)) { return -1 }
  try { return [M01Audio.Mixer]::Run([int[]]$pids, $set) } catch { return -1 }
}
$script:ArtKey = ''; $script:ArtBytes = $null; $script:ArtTries = 0; $script:ArtVer = 0
function Media-State([string]$cmd, [string]$val) {
  if (-not (Media-Init)) { return '{"ok":false,"app":"","running":false,"reason":"unsupported"}' }
  $s = Media-Session
  if (-not $s) { return '{"ok":true,"app":"","running":false}' }
  $done = $null
  switch ($cmd) {
    'toggle' { $done = Await-Op ($s.TryTogglePlayPauseAsync()) ([bool]) }
    'play'   { $done = Await-Op ($s.TryPlayAsync()) ([bool]) }
    'pause'  { $done = Await-Op ($s.TryPauseAsync()) ([bool]) }
    'next'   { $done = Await-Op ($s.TrySkipNextAsync()) ([bool]) }
    'prev'   { $done = Await-Op ($s.TrySkipPreviousAsync()) ([bool]) }
    'seek'   { if ($val -match '^\d+(\.\d+)?$') { $done = Await-Op ($s.TryChangePlaybackPositionAsync([int64]([double]$val * 10000000))) ([bool]) } }
  }
  if ($cmd -ne 'get' -and $cmd -ne 'vol') { Start-Sleep -Milliseconds 300; $s = Media-Session; if (-not $s) { return '{"ok":true,"app":"","running":false}' } }
  $p = $null; try { $p = Await-Op ($s.TryGetMediaPropertiesAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties]) } catch { $p = $null }
  $title = ''; $artist = ''; $album = ''
  if ($p) { $title = [string]$p.Title; $artist = [string]$p.Artist; $album = [string]$p.AlbumTitle }
  $state = 'stopped'; try { $st = [string]$s.GetPlaybackInfo().PlaybackStatus; if ($st -eq 'Playing') { $state = 'playing' } elseif ($st -eq 'Paused') { $state = 'paused' } } catch { }
  $pos = 0.0; $dur = 0.0
  try {
    $tl = $s.GetTimelineProperties(); $dur = $tl.EndTime.TotalSeconds; $pos = $tl.Position.TotalSeconds
    if ($state -eq 'playing') { $pos += ([DateTimeOffset]::Now - $tl.LastUpdatedTime).TotalSeconds }
    if ($dur -gt 0 -and $pos -gt $dur) { $pos = $dur }; if ($pos -lt 0) { $pos = 0 }
  } catch { }
  $app = 'other'; if ([string]$s.SourceAppUserModelId -match 'Spotify') { $app = 'spotify' }
  $key = $title + '|' + $artist + '|' + $album + '|' + [string]$s.SourceAppUserModelId
  # read the cover again on the next two checks after a song change (Spotify often sends the new cover a moment later), and keep trying while it is missing
  if ($key -ne $script:ArtKey) { $script:ArtKey = $key; $script:ArtTries = 0; $script:ArtBytes = $null }
  if ($script:ArtTries -lt 3 -or (-not $script:ArtBytes -and $script:ArtTries -lt 15)) {   # browsers (YouTube) often send the picture a few seconds late
    $script:ArtTries++
    $nb = $null
    try {
      if ($p -and $p.Thumbnail) {
        $rs = Await-Op ($p.Thumbnail.OpenReadAsync()) ([Windows.Storage.Streams.IRandomAccessStreamWithContentType])
        if ($rs) {
          try { $ns = [System.IO.WindowsRuntimeStreamExtensions]::AsStreamForRead($rs); $ms = New-Object System.IO.MemoryStream; $ns.CopyTo($ms); $nb = $ms.ToArray(); $ns.Dispose() } catch { $nb = $null }
          if (-not $nb -or $nb.Length -eq 0) {
            try {
              $size = [uint32]$rs.Size
              $dr = [Windows.Storage.Streams.DataReader]::new($rs.GetInputStreamAt(0))
              $null = Await-Op ($dr.LoadAsync($size)) ([uint32])
              $nb = New-Object byte[] $size; $dr.ReadBytes($nb)
            } catch { $nb = $null }
          }
        }
      }
    } catch { $nb = $null }
    if ($nb -and $nb.Length -gt 200) {
      $same = $false; if ($script:ArtBytes -and $script:ArtBytes.Length -eq $nb.Length) { $same = $true }
      $script:ArtBytes = $nb; if (-not $same) { $script:ArtVer++ }
    }
  }
  $vol = -1
  if ($app -eq 'spotify') { $set = -1; if ($cmd -eq 'vol' -and $val -match '^\d+(\.\d+)?$') { $set = [int][Math]::Round([double]$val) }; $vol = Spotify-Volume $set }
  $hasArt = 'false'; if ($script:ArtBytes -and $script:ArtBytes.Length -gt 0) { $hasArt = 'true' }
  $okCmd = 'true'; if ($cmd -ne 'get' -and $cmd -ne 'vol' -and $done -ne $true) { $okCmd = 'false' }
  $inv = [Globalization.CultureInfo]::InvariantCulture
  return ('{"ok":true,"app":"' + $app + '","running":true,"state":"' + $state + '","title":' + (Json-Str $title) + ',"artist":' + (Json-Str $artist) + ',"album":' + (Json-Str $album) +
    ',"art":"","artKey":' + (Json-Str $key) + ',"artVer":' + $script:ArtVer + ',"hasArt":' + $hasArt + ',"dur":' + $dur.ToString('0.###', $inv) + ',"pos":' + $pos.ToString('0.###', $inv) + ',"vol":' + $vol + ',"cmdOk":' + $okCmd + ',"id":' + (Json-Str $key) + '}')
}
# ---------- background model download (curl talks to Ollama in its own process, so it survives the app closing) ----------
$PullDir = Join-Path $env:LOCALAPPDATA 'M-01 Companion\pull'; if ($env:M01_PULLDIR) { $PullDir = $env:M01_PULLDIR }
$script:Pull = $null
function Pull-Alive { if (-not $script:Pull -or -not $script:Pull.pid) { return $false }; $p = Get-Process -Id ([int]$script:Pull.pid) -ErrorAction SilentlyContinue; return [bool]($p -and $p.ProcessName -match 'curl') }
function Pull-Save { try { New-Item -ItemType Directory -Path $PullDir -Force | Out-Null; [IO.File]::WriteAllText((Join-Path $PullDir 'pull_state.txt'), ("{0}`t{1}`t{2}" -f $script:Pull.pid, $script:Pull.model, $script:Pull.log), $utf8) } catch { } }
function Pull-Load {
  if ($script:Pull) { return }
  $f = Join-Path $PullDir 'pull_state.txt'
  if (Test-Path -LiteralPath $f) { $a = ([IO.File]::ReadAllText($f, $utf8)) -split "`t"; if ($a.Count -ge 3 -and $a[1]) { $script:Pull = @{ pid = [int]$a[0]; model = $a[1]; log = $a[2]; total = [int64]0; done = [int64]0; t = [DateTime]::Now.AddMinutes(-1) } } }
}
function Pull-Status([bool]$alive) {
  $tail = ''
  try { if ($script:Pull.log -and (Test-Path -LiteralPath $script:Pull.log)) {
    $fs = New-Object IO.FileStream($script:Pull.log, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    $len = $fs.Length; $start = [Math]::Max([int64]0, $len - 32768); [void]$fs.Seek($start, 'Begin')
    $buf = New-Object byte[] ($len - $start); [void]$fs.Read($buf, 0, $buf.Length); $fs.Close(); $tail = $utf8.GetString($buf) } } catch { }
  $st = ''; $err = ''; $ok = $false
  foreach ($ln in ($tail -split "`n")) {
    $m = [regex]::Match($ln, '"error"\s*:\s*"((?:[^"\\]|\\.)*)"'); if ($m.Success) { $err = $m.Groups[1].Value }
    $m = [regex]::Match($ln, '"status"\s*:\s*"((?:[^"\\]|\\.)*)"'); if ($m.Success) { $st = $m.Groups[1].Value; if ($st -eq 'success') { $ok = $true } }
    $m = [regex]::Match($ln, '"total"\s*:\s*(\d+)')
    if ($m.Success) { $tt = [int64]$m.Groups[1].Value; $c2 = [regex]::Match($ln, '"completed"\s*:\s*(\d+)'); $cc = [int64]0; if ($c2.Success) { $cc = [int64]$c2.Groups[1].Value }
      if ($tt -gt $script:Pull.total) { $script:Pull.total = $tt; $script:Pull.done = $cc } elseif ($tt -eq $script:Pull.total -and $cc -gt $script:Pull.done) { $script:Pull.done = $cc } }
  }
  if (-not $alive -and -not $ok -and -not $err -and -not $tail -and (([DateTime]::Now - $script:Pull.t).TotalSeconds -gt 5)) { $err = 'curl failed' }
  $r = if ($alive) { 'true' } else { 'false' }; $s2 = if ($ok) { 'true' } else { 'false' }
  return '{"ok":true,"model":' + (Json-Str $script:Pull.model) + ',"running":' + $r + ',"total":' + $script:Pull.total + ',"completed":' + $script:Pull.done + ',"status":' + (Json-Str $st) + ',"success":' + $s2 + ',"error":' + (Json-Str $err) + '}'
}
function Parse-Query([string]$qs) {
  $q = @{}
  foreach ($pair in $qs.Split('&')) { if ($pair) { $kv = $pair.Split('=', 2); $q[$kv[0]] = if ($kv.Length -gt 1) { [System.Uri]::UnescapeDataString($kv[1].Replace('+', ' ')) } else { '' } } }
  return $q
}

# ---------- sharp taskbar icon: Edge app windows use a stretched page icon, so give the window (and the shortcuts) the app's own id and .ico ----------
$WinIconPs = @'
$ErrorActionPreference = 'SilentlyContinue'
$cs = @"
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
[StructLayout(LayoutKind.Sequential, Pack = 4)]
public struct M01PKey { public Guid fmtid; public uint pid; public M01PKey(Guid g, uint p) { fmtid = g; pid = p; } }
[StructLayout(LayoutKind.Explicit)]
public struct M01PVar { [FieldOffset(0)] public ushort vt; [FieldOffset(8)] public IntPtr p; [FieldOffset(16)] public IntPtr pad; }
[ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IM01Props {
  [PreserveSig] int GetCount(out uint c);
  [PreserveSig] int GetAt(uint i, out M01PKey k);
  [PreserveSig] int GetValue(ref M01PKey k, out M01PVar v);
  [PreserveSig] int SetValue(ref M01PKey k, ref M01PVar v);
  [PreserveSig] int Commit();
}
[ComImport, Guid("00021401-0000-0000-C000-000000000046")] public class M01ShellLink { }
public static class M01Win {
  delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder sb, int n);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder sb, int n);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr LoadImage(IntPtr hi, string name, uint type, int cx, int cy, uint flags);
  [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr h);
  [DllImport("shell32.dll")] static extern int SHGetPropertyStoreForWindow(IntPtr h, ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out IM01Props ps);
  [DllImport("ole32.dll")] static extern int PropVariantClear(ref M01PVar v);
  static Guid AppKeys = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");
  static Guid StoreIid = new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");
  static HashSet<IntPtr> done = new HashSet<IntPtr>();
  static int Put(IM01Props ps, uint pid, string val) {
    M01PKey k = new M01PKey(AppKeys, pid); M01PVar v = new M01PVar(); v.vt = 31; v.p = Marshal.StringToCoTaskMemUni(val);
    try { return ps.SetValue(ref k, ref v); } finally { Marshal.FreeCoTaskMem(v.p); }
  }
  static string Get(IM01Props ps, uint pid) {
    M01PKey k = new M01PKey(AppKeys, pid); M01PVar v;
    if (ps.GetValue(ref k, out v) != 0) return null;
    string r = (v.vt == 31 && v.p != IntPtr.Zero) ? Marshal.PtrToStringUni(v.p) : null; PropVariantClear(ref v); return r;
  }
  // the shortcut gets the same id as the window, so Windows shows the shortcut's sharp .ico on the taskbar
  public static bool LinkId(string lnk, string id) {
    try {
      object o = new M01ShellLink(); IPersistFile pf = (IPersistFile)o; pf.Load(lnk, 2);
      IM01Props ps = (IM01Props)o; if (Get(ps, 5) == id) { Marshal.ReleaseComObject(o); return true; }
      Put(ps, 5, id); ps.Commit(); pf.Save(lnk, true); Marshal.ReleaseComObject(o); return true;
    } catch { return false; }
  }
  public static int Fix(string title, string icon, string id, string cmd) {
    List<IntPtr> wins = new List<IntPtr>();
    EnumWindows(delegate (IntPtr hw, IntPtr lp) {
      if (!IsWindowVisible(hw)) return true;
      StringBuilder c = new StringBuilder(64); GetClassName(hw, c, 64); if (!c.ToString().StartsWith("Chrome_WidgetWin_")) return true;
      StringBuilder t = new StringBuilder(256); GetWindowText(hw, t, 256); if (t.ToString() == title) wins.Add(hw);
      return true;
    }, IntPtr.Zero);
    foreach (IntPtr h in wins) {
      uint dpi = 96; try { dpi = GetDpiForWindow(h); if (dpi == 0) dpi = 96; } catch { dpi = 96; }
      int sm = (int)(16 * dpi / 96), bg = (int)(32 * dpi / 96);
      IntPtr hs = LoadImage(IntPtr.Zero, icon, 1, sm, sm, 0x10), hb = LoadImage(IntPtr.Zero, icon, 1, bg, bg, 0x10);
      if (hs != IntPtr.Zero) SendMessage(h, 0x80, IntPtr.Zero, hs);
      if (hb != IntPtr.Zero) SendMessage(h, 0x80, new IntPtr(1), hb);
      if (!done.Contains(h)) {
        try {
          Guid iid = StoreIid; IM01Props ps;
          if (SHGetPropertyStoreForWindow(h, ref iid, out ps) == 0 && ps != null) {
            Put(ps, 2, cmd); Put(ps, 4, title); Put(ps, 3, icon + ",0"); Put(ps, 5, id); ps.Commit(); Marshal.ReleaseComObject(ps);
          }
        } catch { }
        done.Add(h);
      }
    }
    return wins.Count;
  }
}
"@
# compile once and keep the result, so later launches skip the compiler
$dll = Join-Path $env:LOCALAPPDATA 'M-01 Companion\helper\m01win1.dll'
if (-not (Test-Path -LiteralPath $dll)) { try { New-Item -ItemType Directory -Path (Split-Path -Parent $dll) -Force | Out-Null; Add-Type -TypeDefinition $cs -OutputAssembly $dll -OutputType Library -ErrorAction Stop } catch { } }
if (-not ('M01Win' -as [type])) { try { Add-Type -Path $dll -ErrorAction Stop } catch { } }
if (-not ('M01Win' -as [type])) { try { Add-Type -TypeDefinition $cs -ErrorAction Stop } catch { exit } }
$id = 'Elvis.M01Companion'
$cmd = '"' + $env:WINDIR + '\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $M01Launch + '"'
foreach ($l in @((Join-Path ([Environment]::GetFolderPath('Desktop')) 'M-01 Companion.lnk'), (Join-Path ([Environment]::GetFolderPath('Programs')) 'M-01 Companion.lnk'), (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\M-01 Companion.lnk'))) {
  if (Test-Path -LiteralPath $l) { [void][M01Win]::LinkId($l, $id) }
}
# wait for the window, then set it again a few times in case Edge puts its own icon back after the page loads
$seen = 0
for ($i = 0; $i -lt 120 -and $seen -lt 6; $i++) {
  if ([M01Win]::Fix('M-01 Companion', $M01Icon, $id, $cmd) -gt 0) { $seen++; Start-Sleep -Milliseconds (500 * $seen) } else { Start-Sleep -Milliseconds 250 }
}
'@
$script:IconAt = [DateTime]::MinValue
function Start-WinIcon {
  try {
    if (([DateTime]::Now - $script:IconAt).TotalSeconds -lt 20) { return }
    $script:IconAt = [DateTime]::Now
    $appDir = Split-Path -Parent $WebRoot
    $ico = Join-Path $appDir 'icon.ico'; $lp = Join-Path $appDir 'launch.ps1'
    if (-not (Test-Path -LiteralPath $ico)) { return }
    $pre = '$M01Icon = ''' + $ico.Replace("'", "''") + "'`r`n" + '$M01Launch = ''' + $lp.Replace("'", "''") + "'`r`n"
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($pre + $WinIconPs))
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $enc)
  } catch { }
}

# ---------- network calls run on their own threads, so a slow AI reply or weather lookup never freezes the rest of the app ----------
$NetJob = {
  param($client, [string]$mode, [string]$url, [string]$method, [byte[]]$body, [string]$ctype, [hashtable]$hdr, [int]$secs, [string]$tokFile)
  $ProgressPreference = 'SilentlyContinue'
  $utf8 = New-Object System.Text.UTF8Encoding($false)
  $code = 0; $bytes = $null; $resp = $null
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $rq = [Net.HttpWebRequest]::Create($url)
    $rq.Method = $method; $rq.Timeout = $secs * 1000; $rq.ReadWriteTimeout = $secs * 1000
    $rq.AutomaticDecompression = [Net.DecompressionMethods]::GZip -bor [Net.DecompressionMethods]::Deflate
    $rq.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) M-01-Companion'
    if ($hdr) { foreach ($k in @($hdr.Keys)) { $rq.Headers[[string]$k] = [string]$hdr[$k] } }
    if ($method -ne 'GET') {
      if ($null -eq $body) { $body = [byte[]]@() }
      $rq.ContentType = $ctype; $rq.ContentLength = $body.Length
      $rqs = $rq.GetRequestStream(); $rqs.Write($body, 0, $body.Length); $rqs.Close()
    }
    $resp = $rq.GetResponse()
  } catch {
    $ex = $_.Exception; while ($ex -and -not ($ex -is [Net.WebException])) { $ex = $ex.InnerException }
    if ($ex) { $resp = $ex.Response }
  }
  if ($resp) {
    try { $code = [int]$resp.StatusCode; $mem = New-Object IO.MemoryStream; $resp.GetResponseStream().CopyTo($mem); $bytes = $mem.ToArray() } catch { } finally { try { $resp.Close() } catch { } }
  }
  if ($null -eq $bytes) { $bytes = [byte[]]@() }
  $type = 'application/json'; $out = $null
  if ($mode -eq 'json') {
    if ($code -ge 200 -and $code -lt 300 -and $bytes.Length -gt 0) { $type = 'application/json; charset=utf-8'; $out = $bytes }
    else { $out = $utf8.GetBytes('{"error":true,"reason":"unreachable"}') }
  } elseif ($mode -eq 'fish') {
    if ($code -eq 200 -and $bytes.Length -gt 0) { $type = 'audio/mpeg'; $out = $bytes }
    else {
      $etxt = $utf8.GetString($bytes); if ($etxt.Length -gt 400) { $etxt = $etxt.Substring(0, 400) }; $etxt = $etxt -replace '[^\x20-\x7e]', ''
      $out = $utf8.GetBytes('{"status":' + $code + ',"error":' + ($etxt | ConvertTo-Json -Compress) + '}')
    }
  } else {
    $txt = $utf8.GetString($bytes)
    if ($mode -eq 'gtoken') {
      # the long-lived refresh token stays in a local file; the page only gets the short access token
      $m = [regex]::Match($txt, '"refresh_token"\s*:\s*"([^"]+)"')
      if ($m.Success) {
        try { New-Item -ItemType Directory -Path (Split-Path -Parent $tokFile) -Force | Out-Null; [IO.File]::WriteAllText($tokFile, $m.Groups[1].Value, $utf8) } catch { }
        $t2 = [regex]::Replace($txt, ',\s*"refresh_token"\s*:\s*"[^"]*"', '')
        if ($t2 -eq $txt) { $t2 = [regex]::Replace($txt, '"refresh_token"\s*:\s*"[^"]*"\s*,?', '') }
        $txt = $t2
      }
    }
    if ($txt -notmatch '^\s*[\[{]') { $txt = 'null' }
    $out = $utf8.GetBytes('{"status":' + $code + ',"body":' + $txt + '}')
  }
  try {
    $st = $client.GetStream()
    $hb = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: $type`r`nContent-Length: $($out.Length)`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n")
    $st.Write($hb, 0, $hb.Length); if ($out.Length -gt 0) { $st.Write($out, 0, $out.Length) }
  } catch { } finally { try { $client.Close() } catch { } }
}
$NetPool = $null; try { $NetPool = [RunspaceFactory]::CreateRunspacePool(1, 8); $NetPool.Open() } catch { $NetPool = $null }
$NetJobs = New-Object System.Collections.ArrayList
# returns $true when the request was handed to a background thread (that thread answers and closes the connection)
function Start-NetJob($client, [string]$mode, [string]$url, [string]$method, [byte[]]$body, [string]$ctype, [hashtable]$hdr, [int]$secs, [string]$tokFile) {
  if (-not $NetPool) { & $NetJob $client $mode $url $method $body $ctype $hdr $secs $tokFile; return $true }
  try {
    $ps = [PowerShell]::Create(); $ps.RunspacePool = $NetPool
    [void]$ps.AddScript($NetJob).AddArgument($client).AddArgument($mode).AddArgument($url).AddArgument($method).AddArgument($body).AddArgument($ctype).AddArgument($hdr).AddArgument($secs).AddArgument($tokFile)
    [void]$NetJobs.Add(@($ps, $ps.BeginInvoke()))
  } catch { & $NetJob $client $mode $url $method $body $ctype $hdr $secs $tokFile }
  return $true
}
function Clear-NetJobs { for ($j = $NetJobs.Count - 1; $j -ge 0; $j--) { $it = $NetJobs[$j]; if ($it[1].IsCompleted) { try { [void]$it[0].EndInvoke($it[1]) } catch { }; try { $it[0].Dispose() } catch { }; $NetJobs.RemoveAt($j) } } }

while ($true) {
  $client = $listener.AcceptTcpClient()
  $handed = $false
  Clear-NetJobs
  try {
    $client.ReceiveTimeout = 15000
    $stream = $client.GetStream()
    # read headers
    $buf = New-Object byte[] 65536; $ms = New-Object System.IO.MemoryStream; $headerEnd = -1
    while ($headerEnd -lt 0) {
      $n = $stream.Read($buf, 0, $buf.Length); if ($n -le 0) { break }
      $ms.Write($buf, 0, $n)
      $all = $ms.ToArray()
      $hx = [System.Text.Encoding]::ASCII.GetString($all).IndexOf("`r`n`r`n", [StringComparison]::Ordinal); if ($hx -ge 0) { $headerEnd = $hx + 4 }
    }
    if ($headerEnd -lt 0) { $client.Close(); continue }
    $all = $ms.ToArray()
    $headText = [System.Text.Encoding]::ASCII.GetString($all, 0, $headerEnd)
    $lines = $headText -split "`r`n"
    $parts = $lines[0].Split(' ')
    $method = $parts[0]; $target = $parts[1]
    $h = @{}
    foreach ($l in $lines[1..($lines.Length-1)]) { $ix = $l.IndexOf(':'); if ($ix -gt 0) { $h[$l.Substring(0,$ix).Trim().ToLower()] = $l.Substring($ix+1).Trim() } }
    # body
    $len = 0; if ($h.ContainsKey('content-length')) { $len = [int]$h['content-length'] }
    $body = New-Object byte[] $len
    $have = $all.Length - $headerEnd
    if ($have -gt 0) { [Array]::Copy($all, $headerEnd, $body, 0, [Math]::Min($have, $len)) }
    while ($have -lt $len) { $n = $stream.Read($body, $have, $len - $have); if ($n -le 0) { break }; $have += $n }

    $qs = ''; $qi = $target.IndexOf('?'); if ($qi -ge 0) { $qs = $target.Substring($qi+1); $target = $target.Substring(0, $qi) }
    $isApi = $target -match '^/(fs|ls|ping|search|fetch|open|battery|reveal|setdata|getjson|secret|uninstall|gemini|fishtts|gtoken|selfupdate|sysinfo|music|musicart|ollamastart|pull|ollamainstall|helperupdate|appupdate)(/|$)'
    if ($isApi -and $h['x-m01'] -ne '1') { Send-Text $stream 403 'text/plain' 'forbidden'; $client.Close(); continue }

    if ($target -eq '/battery') {
      $b = $null; try { $b = Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop | Select-Object -First 1 } catch {}
      if ($b -and $b.EstimatedChargeRemaining -ne $null) {
        $ch = 'false'; if (@(2,6,7,8,9) -contains [int]$b.BatteryStatus) { $ch = 'true' }
        Send-Text $stream 200 'application/json' ('{"ok":true,"level":' + [int]$b.EstimatedChargeRemaining + ',"charging":' + $ch + '}')
      } else { Send-Text $stream 200 'application/json' '{"ok":false}' }
    }
    elseif ($target -eq '/getjson') {
      $q = Parse-Query $qs; $u = [string]$q['url']
      if (($u -match '^https://(geocoding-api|api)\.open-meteo\.com/') -or ($u -match '^https://get\.geojs\.io/v1/ip/geo\.json$') -or ($u -match '^https://open\.spotify\.com/oembed\?url=[\w%.\-]+$') -or ($u -match '^https://itunes\.apple\.com/search\?[\w=&.%+-]*$') -or ($u -match '^https://open\.spotify\.com/oembed\?url=[\w%.-]*$') -or ($u -match '^https://api\.bigdatacloud\.net/data/reverse-geocode-client\?[\w=&.%-]*$') -or ($u -match '^https://(raw\.githubusercontent\.com|gist\.githubusercontent\.com|[A-Za-z0-9-]+\.github\.io)/\S*\.json(\?\S*)?$')) {
        $handed = Start-NetJob $client 'json' $u 'GET' $null '' $null 12 ''
      } else { Send-Text $stream 403 'text/plain' 'forbidden' }
    }
    elseif ($target -eq '/secret') {
      $qs0 = Parse-Query $qs; $KF = $KeyFile; if ($qs0['p'] -eq 'gemini') { $KF = $GemKeyFile } elseif ($qs0['p'] -eq 'fish') { $KF = $FishKeyFile } elseif ($qs0['p'] -eq 'google') { $KF = $GoogFile } elseif ($qs0['p'] -eq 'gcode') { $KF = $GCodeFile }
      if ($method -eq 'PUT') {
        $k = ''; if ($body.Length -gt 0) { $k = $utf8.GetString($body).Trim() }
        if ($k) { New-Item -ItemType Directory -Path (Split-Path -Parent $KF) -Force | Out-Null; [IO.File]::WriteAllText($KF, $k, $utf8) }
        elseif (Test-Path -LiteralPath $KF) { Remove-Item -LiteralPath $KF -Force }
        Send-Text $stream 200 'application/json' '{"ok":true}'
      }
      elseif ($method -eq 'DELETE') { if (Test-Path -LiteralPath $KF) { Remove-Item -LiteralPath $KF -Force }; Send-Text $stream 200 'application/json' '{"ok":true}' }
      else {
        $k = ''; if (Test-Path -LiteralPath $KF) { $k = ([IO.File]::ReadAllText($KF, $utf8)).Trim() }
        $q = Parse-Query $qs
        if ($q['reveal'] -eq '1' -and $qs0['p'] -ne 'google') { Send-Text $stream 200 'application/json' ('{"ok":true,"key":' + (Json-Str $k) + '}') }
        else { $l4 = ''; if ($k.Length -gt 4) { $l4 = $k.Substring($k.Length - 4) }; $has = 'false'; if ($k) { $has = 'true' }
          Send-Text $stream 200 'application/json' ('{"ok":true,"has":' + $has + ',"last4":' + (Json-Str $l4) + '}') }
      }
    }
    elseif ($target -eq '/oauth') {
      # Google sign-in comes back here in the browser: hand the one-time code to the app, then say done
      $q = Parse-Query $qs; $st = [string]$q['state']; $cd = [string]$q['code']; $er = [string]$q['error']
      $okk = ($st -match '^m01g[A-Za-z0-9]+$') -and ($cd -or $er)
      if ($okk) { $v = $cd; if (-not $cd) { $v = '!' + $er }; New-Item -ItemType Directory -Path (Split-Path -Parent $GCodeFile) -Force | Out-Null; [IO.File]::WriteAllText($GCodeFile, ($st + ' ' + $v), $utf8) }
      $msg = 'BAD'; if ($okk -and $cd) { $msg = 'OK' } elseif ($okk) { $msg = 'CANCEL' }
      $page = '<!DOCTYPE html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>M-01 Companion</title><body style="margin:0;display:grid;place-items:center;min-height:100vh;background:#0b0b0e;color:#eee;font:17px/1.8 system-ui,sans-serif;text-align:center"><div><div style="color:#ff7a3d;letter-spacing:.2em;font-size:13px">M-01 COMPANION</div><p>' + $msg + '</p></div><script>setTimeout(function(){try{window.close()}catch(e){}},1500)</script></body>'
      $page = $page.Replace('<p>OK</p>', '<p>&#30331;&#20837;&#25104;&#21151;&#65281;&#21487;&#20197;&#38364;&#25481;&#36889;&#20491;&#20998;&#38913;&#65292;&#22238;&#21040; M-01 &#20102;&#12290;<br>Signed in! You can close this tab and go back to M-01.</p>').Replace('<p>CANCEL</p>', '<p>&#20320;&#21462;&#28040;&#20102;&#30331;&#20837;&#12290;&#21487;&#20197;&#38364;&#25481;&#36889;&#20491;&#20998;&#38913;&#65292;&#22238;&#21040; M-01&#12290;<br>Sign-in was cancelled. You can close this tab and go back to M-01.</p>').Replace('<p>BAD</p>', '<p>&#30331;&#20837;&#27794;&#26377;&#23436;&#25104;&#65292;&#35531;&#22238;&#21040; M-01 &#20877;&#35430;&#19968;&#27425;&#12290;<br>Sign-in didn&#8217;t finish - go back to M-01 and try again.</p>')
      Send-Text $stream 200 'text/html; charset=utf-8' $page
    }
    elseif ($target -eq '/gtoken') {
      # Google sign-in tokens: the long-lived refresh token stays in a local file, the page only gets short access tokens
      $q = Parse-Query $qs; $form = ''; if ($body.Length -gt 0) { $form = $utf8.GetString($body) }
      if ($form -notmatch '(^|&)client_secret=') { $form = $form + '&client_secret=' + $GSecret }
      $skip = $false
      if ($q['op'] -eq 'refresh') {
        $rt = ''; if (Test-Path -LiteralPath $GoogFile) { $rt = ([IO.File]::ReadAllText($GoogFile, $utf8)).Trim() }
        if (-not $rt) { Send-Text $stream 200 'application/json' '{"status":401,"body":{"error":"not_signed_in"}}'; $skip = $true }
        else { $form = $form + '&refresh_token=' + [Uri]::EscapeDataString($rt) }
      }
      if (-not $skip) { $handed = Start-NetJob $client 'gtoken' $GTokUrl 'POST' ($utf8.GetBytes($form)) 'application/x-www-form-urlencoded' $null 30 $GoogFile }
    }
    elseif ($target -eq '/gemini') {
      $q = Parse-Query $qs
      $model = ([string]$q['model']) -replace '[^A-Za-z0-9.\-]', ''
      if (-not $model) { $model = 'gemini-3.8-flash' }
      $gk = ''; if (Test-Path -LiteralPath $GemKeyFile) { $gk = ([IO.File]::ReadAllText($GemKeyFile, $utf8)).Trim() }
      if (-not $gk) { Send-Text $stream 200 'application/json' '{"status":401,"body":{"error":{"message":"no key"}}}' }
      else {
        $gbase = 'https://generativelanguage.googleapis.com'; if ($env:M01_GEMINI_URL) { $gbase = $env:M01_GEMINI_URL }
        $handed = Start-NetJob $client 'wrap' ($gbase + '/v1beta/models/' + $model + ':generateContent') 'POST' $body 'application/json; charset=utf-8' @{ 'x-goog-api-key' = $gk } 120 ''
      }
    }
    elseif ($target -eq '/fishtts') {
      $q = Parse-Query $qs
      $model = ([string]$q['model']) -replace '[^A-Za-z0-9.\-]', ''
      if (-not $model) { $model = 's2.1-pro-free' }
      $fk = ''; if (Test-Path -LiteralPath $FishKeyFile) { $fk = ([IO.File]::ReadAllText($FishKeyFile, $utf8)).Trim() }
      if (-not $fk) { Send-Text $stream 200 'application/json' '{"status":401,"error":"no key"}' }
      else {
        $fbase = 'https://api.fish.audio'; if ($env:M01_FISH_URL) { $fbase = $env:M01_FISH_URL }
        $handed = Start-NetJob $client 'fish' ($fbase + '/v1/tts') 'POST' $body 'application/json; charset=utf-8' @{ 'Authorization' = ('Bearer ' + $fk); 'model' = $model } 90 ''
      }
    }
    elseif ($target -eq '/uninstall') {
      $q = Parse-Query $qs
      $moved = 'false'
      $safe = ((Split-Path -Leaf $DataDir) -eq 'Companion') -or (Test-Path -LiteralPath (Join-Path $DataDir $DataMark))
      if ($q['data'] -eq '1' -and $safe -and ($DataDir -ne $env:USERPROFILE)) {
        try {
          Add-Type -AssemblyName Microsoft.VisualBasic
          [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($DataDir, [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs, [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
          $moved = 'true'
        } catch { $moved = 'false' }
      }
      Send-Text $stream 200 'application/json' ('{"ok":true,"dataMoved":' + $moved + ',"data":' + (Json-Str $DataDir) + '}')
      $root = Split-Path -Parent (Split-Path -Parent $WebRoot)
      if ((Split-Path -Leaf $root) -eq 'M-01 Companion') {
        $r = $root -replace "'", "''"
        $cmd = "Start-Sleep -Seconds 2; " +
          "Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { `$_.CommandLine -and `$_.CommandLine -like '*M-01 Companion\browser*' } | ForEach-Object { Stop-Process -Id `$_.ProcessId -Force -ErrorAction SilentlyContinue }; " +
          "Start-Sleep -Seconds 1; Get-ChildItem -LiteralPath '$r' -Force -ErrorAction SilentlyContinue | Where-Object { `$_.Name -ne 'Data' } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue; " +
          "if (-not (Get-ChildItem -LiteralPath '$r' -Force -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath '$r' -Force -ErrorAction SilentlyContinue }; " +
          "Remove-Item -LiteralPath (Join-Path ([Environment]::GetFolderPath('Desktop')) 'M-01 Companion.lnk') -Force -ErrorAction SilentlyContinue; " +
          "Remove-Item -LiteralPath (Join-Path ([Environment]::GetFolderPath('Programs')) 'M-01 Companion.lnk') -Force -ErrorAction SilentlyContinue; " +
          "[Environment]::SetEnvironmentVariable('OLLAMA_ORIGINS', `$null, 'User')"
        $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
        Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $enc)
      }
      try { $client.Close() } catch {}
      $listener.Stop()
      exit
    }
    elseif ($target -eq '/reveal') {
      Start-Process explorer.exe -ArgumentList ('"' + $DataDir + '"')
      Send-Text $stream 200 'application/json' ('{"ok":true,"data":' + (Json-Str $DataDir) + '}')
    }
    elseif ($target -eq '/setdata') {
      $p = ''
      try {
        Add-Type -AssemblyName System.Windows.Forms
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'Choose where to keep the M-01 memory folder (a Companion folder will be created inside)'
        $dlg.SelectedPath = [Environment]::GetFolderPath('MyDocuments')
        $owner = New-Object System.Windows.Forms.Form
        $owner.TopMost = $true; $owner.ShowInTaskbar = $false
        if ($dlg.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK) { $p = $dlg.SelectedPath }
        $owner.Dispose()
      } catch { $p = '' }
      if (-not $p) { Send-Text $stream 200 'application/json' '{"ok":false,"cancel":true}' }
      else {
        $p = $p.TrimEnd('\')
        $newDir = $p
        if ((Split-Path -Leaf $p) -ne 'Companion' -and -not (Test-Path -LiteralPath (Join-Path $p $DataMark))) { $newDir = Join-Path $p 'Companion' }
        try {
          New-Item -ItemType Directory -Path $newDir -Force | Out-Null
          $abs = (Resolve-Path -LiteralPath $newDir).Path
          if ($abs -ne $DataDir) {
            if (-not (Test-Path -LiteralPath (Join-Path $abs $DataMark))) { Copy-Item -Path (Join-Path $DataDir '*') -Destination $abs -Recurse -Force }
            New-Item -ItemType Directory -Path (Split-Path -Parent $CfgFile) -Force | Out-Null
            [IO.File]::WriteAllText($CfgFile, $abs, $utf8)
            $DataDir = $abs
          }
          Send-Text $stream 200 'application/json' ('{"ok":true,"data":' + (Json-Str $DataDir) + '}')
        } catch { Send-Text $stream 200 'application/json' '{"ok":false,"error":"cannot write"}' }
      }
    }
    elseif ($target -eq '/ping') {
      $pk = 1; try { $pf = Join-Path (Split-Path -Parent $WebRoot) 'pkgver.txt'; if (Test-Path -LiteralPath $pf) { $pk = [int](([IO.File]::ReadAllText($pf)) -replace '\D', '') } } catch { $pk = 1 }; if ($pk -lt 1) { $pk = 1 }
      Send-Text $stream 200 'application/json' ('{"ok":true,"hv":' + $HV + ',"pkg":' + $pk + ',"data":' + (Json-Str $DataDir) + '}')
    }
    elseif ($target -eq '/music') {
      $q = Parse-Query $qs; $cmd = [string]$q['cmd']; if ($cmd -notmatch '^(get|toggle|play|pause|next|prev|vol|seek)$') { $cmd = 'get' }
      $out = '{"ok":false,"app":"","running":false,"reason":"error"}'
      try { $out = Media-State $cmd ([string]$q['v']) } catch { }
      Send-Text $stream 200 'application/json' $out
    }
    elseif ($target -eq '/musicart') {
      if ($script:ArtBytes -and $script:ArtBytes.Length -gt 0) { Send-Reply $stream 200 'image/jpeg' $script:ArtBytes } else { Send-Text $stream 404 'text/plain' 'none' }
    }
    elseif ($target -eq '/appupdate') {
      # full update from inside the app: download the new package, check its fingerprint, then run its installer (the window closes and reopens)
      $q = Parse-Query $qs; $act = [string]$q['act']; if (-not $act) { $act = 'status' }
      $UpdDir = Join-Path $env:LOCALAPPDATA 'M-01 Companion\update'; if ($env:M01_UPDDIR) { $UpdDir = $env:M01_UPDDIR }
      New-Item -ItemType Directory -Path $UpdDir -Force | Out-Null
      $stf = Join-Path $UpdDir 'state.txt'; $zip = Join-Path $UpdDir 'pkg.zip'; $pidf = Join-Path $UpdDir 'pid.txt'; $pkd = Join-Path $UpdDir 'pkg'
      $urun = $false; if (Test-Path -LiteralPath $pidf) { try { $urun = [bool](Get-Process -Id ([int]([IO.File]::ReadAllText($pidf))) -ErrorAction SilentlyContinue) } catch { } }
      $bad = $false; $sent = $false
      if ($act -eq 'start') {
        $u = [string]$q['url']; $want = ([string]$q['sha']).ToLower()
        $okUrl = ($u -match '^https://[A-Za-z0-9-]+\.github\.io/[^\s?#''"`]*\.zip$') -or ($env:M01_UPD_ALLOW -and $u.StartsWith($env:M01_UPD_ALLOW))
        if (-not $okUrl -or $want -notmatch '^[0-9a-f]{64}$') { Send-Text $stream 403 'application/json' '{"ok":false,"error":"forbidden"}'; $sent = $true }
        elseif (-not $urun) {
          Remove-Item -LiteralPath $stf, $zip -Force -ErrorAction SilentlyContinue
          if (Test-Path -LiteralPath $pkd) { Remove-Item -LiteralPath $pkd -Recurse -Force -ErrorAction SilentlyContinue }
          $curl = Join-Path $env:SystemRoot 'System32\curl.exe'; if (-not (Test-Path -LiteralPath $curl)) { $curl = 'curl.exe' }
          $qs1 = $stf -replace "'", "''"; $qz = $zip -replace "'", "''"; $qp = $pkd -replace "'", "''"; $qc = $curl -replace "'", "''"
          $job = @"
`$ErrorActionPreference = 'Continue'
`$ProgressPreference = 'SilentlyContinue'
`$t = 0; try { `$h = & '$qc' -sIL --max-time 20 '$u' 2>`$null; foreach (`$l in `$h) { if (`$l -match '^(?i)content-length:\s*(\d+)') { `$t = [int64]`$Matches[1] } } } catch { }
Set-Content -LiteralPath '$qs1' -Value ("dl " + `$t)
& '$qc' -fsSL -o '$qz' '$u'
if (`$LASTEXITCODE -ne 0) { Set-Content -LiteralPath '$qs1' -Value 'error download'; exit }
`$sha = [Security.Cryptography.SHA256]::Create(); `$fs = [IO.File]::OpenRead('$qz'); `$got = ((`$sha.ComputeHash(`$fs) | ForEach-Object { `$_.ToString('x2') }) -join ''); `$fs.Close()
if (`$got -ne '$want') { Set-Content -LiteralPath '$qs1' -Value 'error checksum'; exit }
try { Expand-Archive -LiteralPath '$qz' -DestinationPath '$qp' -Force -ErrorAction Stop } catch { Set-Content -LiteralPath '$qs1' -Value 'error unzip'; exit }
if (-not (Test-Path -LiteralPath (Join-Path '$qp' 'install.ps1'))) { Set-Content -LiteralPath '$qs1' -Value 'error unzip'; exit }
Set-Content -LiteralPath '$qs1' -Value ("ready " + `$t)
"@
          $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($job))
          try { $pp = Start-Process -FilePath 'powershell.exe' -ArgumentList ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -EncodedCommand ' + $enc) -WindowStyle Hidden -PassThru; [IO.File]::WriteAllText($pidf, [string]$pp.Id); $urun = $true } catch { }
          Start-Sleep -Milliseconds 300
        }
      }
      elseif ($act -eq 'cancel') {
        if ($urun) { try { Stop-Process -Id ([int]([IO.File]::ReadAllText($pidf))) -Force -ErrorAction SilentlyContinue } catch { } }
        Remove-Item -LiteralPath $stf, $zip, $pidf -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $pkd) { Remove-Item -LiteralPath $pkd -Recurse -Force -ErrorAction SilentlyContinue }
        $urun = $false
      }
      elseif ($act -eq 'install') {
        $ins = Join-Path $pkd 'install.ps1'; $line0 = ''; if (Test-Path -LiteralPath $stf) { $line0 = ([IO.File]::ReadAllText($stf)).Trim() }
        if ($line0 -notmatch '^ready' -or -not (Test-Path -LiteralPath $ins)) { Send-Text $stream 200 'application/json' '{"ok":false,"error":"notready"}'; $sent = $true }
        else {
          Send-Text $stream 200 'application/json' '{"ok":true}'
          try { $client.Close() } catch {}
          Set-Content -LiteralPath $stf -Value 'done'
          # the new installer closes the window, copies the new files and opens the app again; this helper steps aside first
          $qi = $ins -replace "'", "''"
          Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-Command', "Start-Sleep -Seconds 1; & '$qi'")
          $listener.Stop()
          exit
        }
      }
      if (-not $sent) {
        $line = ''; if (Test-Path -LiteralPath $stf) { $line = ([IO.File]::ReadAllText($stf)).Trim() }
        $parts = $line -split ' ', 2; $phase = [string]$parts[0]; $rest = ''; if ($parts.Count -gt 1) { $rest = [string]$parts[1] }
        $total = 0; if ($rest -match '^\d+$') { $total = [int64]$rest }
        $got = 0; if (Test-Path -LiteralPath $zip) { try { $got = (Get-Item -LiteralPath $zip).Length } catch { } }
        $err = ''; if ($phase -eq 'error') { $err = $rest }
        if (-not $phase) { if ($urun) { $phase = 'dl' } else { $phase = 'idle' } }
        if (-not $urun -and $phase -eq 'dl') { $phase = 'error'; $err = 'stopped' }
        Send-Text $stream 200 'application/json' ('{"ok":true,"phase":' + (Json-Str $phase) + ',"total":' + $total + ',"got":' + $got + ',"error":' + (Json-Str $err) + '}')
      }
    }
    elseif ($target -eq '/ollamainstall') {
      # one-click Ollama install from inside the app: download the official installer and run it silently (per-user, no admin needed)
      $q = Parse-Query $qs; $act = [string]$q['act']; if (-not $act) { $act = 'status' }
      New-Item -ItemType Directory -Path $PullDir -Force | Out-Null
      $stf = Join-Path $PullDir 'oi_state.txt'; $exe = Join-Path $PullDir 'OllamaSetup.exe'; $pidf = Join-Path $PullDir 'oi_pid.txt'
      $oiRun = $false; if (Test-Path -LiteralPath $pidf) { try { $op = Get-Process -Id ([int]([IO.File]::ReadAllText($pidf))) -ErrorAction SilentlyContinue; $oiRun = [bool]$op } catch { } }
      $appExe = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama app.exe'
      if ($act -eq 'start' -and -not $oiRun) {
        Remove-Item -LiteralPath $stf, $exe -Force -ErrorAction SilentlyContinue
        $url = 'https://ollama.com/download/OllamaSetup.exe'; if ($env:M01_OLLAMA_DL) { $url = $env:M01_OLLAMA_DL }
        $curl = Join-Path $env:SystemRoot 'System32\curl.exe'; if (-not (Test-Path -LiteralPath $curl)) { $curl = 'curl.exe' }
        $job = @"
`$ErrorActionPreference = 'Continue'
`$t = 0; try { `$h = & '$curl' -sIL --max-time 20 '$url' 2>`$null; foreach (`$l in `$h) { if (`$l -match '^(?i)content-length:\s*(\d+)') { `$t = [int64]`$Matches[1] } } } catch { }
Set-Content -LiteralPath '$stf' -Value ("dl " + `$t)
& '$curl' -fsSL -o '$exe' '$url'
if (`$LASTEXITCODE -eq 0) {
  Set-Content -LiteralPath '$stf' -Value ("inst " + `$t)
  try { Start-Process -FilePath '$exe' -ArgumentList '/VERYSILENT','/NORESTART','/SUPPRESSMSGBOXES' -Wait } catch { }
  if (Test-Path -LiteralPath '$appExe') { Start-Process -FilePath '$appExe'; Remove-Item -LiteralPath '$exe' -Force -ErrorAction SilentlyContinue; Set-Content -LiteralPath '$stf' -Value ("done " + `$t) } else { Set-Content -LiteralPath '$stf' -Value 'error install' }
} else { Set-Content -LiteralPath '$stf' -Value 'error download' }
"@
        $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($job))
        try { $pp = Start-Process -FilePath 'powershell.exe' -ArgumentList ('-NoProfile -WindowStyle Hidden -EncodedCommand ' + $enc) -WindowStyle Hidden -PassThru; [IO.File]::WriteAllText($pidf, [string]$pp.Id); $oiRun = $true } catch { }
        Start-Sleep -Milliseconds 300
      }
      $line = ''; if (Test-Path -LiteralPath $stf) { $line = ([IO.File]::ReadAllText($stf)).Trim() }
      $parts = $line -split ' ', 2; $phase = [string]$parts[0]; $rest = ''; if ($parts.Count -gt 1) { $rest = [string]$parts[1] }
      $total = 0; if ($rest -match '^\d+$') { $total = [int64]$rest }
      $got = 0; if (Test-Path -LiteralPath $exe) { try { $got = (Get-Item -LiteralPath $exe).Length } catch { } }
      $err = ''; if ($phase -eq 'error') { $err = $rest }
      if (-not $phase) { if ($oiRun) { $phase = 'dl' } else { $phase = 'idle' } }
      if (-not $oiRun -and ($phase -eq 'dl' -or $phase -eq 'inst')) { $phase = 'error'; $err = 'stopped' }
      $inst = if (Test-Path -LiteralPath $appExe) { 'true' } else { 'false' }
      Send-Text $stream 200 'application/json' ('{"ok":true,"phase":' + (Json-Str $phase) + ',"total":' + $total + ',"got":' + $got + ',"error":' + (Json-Str $err) + ',"installed":' + $inst + '}')
    }
    elseif ($target -eq '/pull') {
      # pause = stop curl (Ollama keeps what was downloaded); start again = continue from there
      $q = Parse-Query $qs; $act = [string]$q['act']; if (-not $act) { $act = 'status' }; $model = [string]$q['model']
      Pull-Load; $alive = Pull-Alive
      if ($act -eq 'start') {
        if ($model -notmatch '^[\w.\-/]+(:[\w.\-]+)?$') { Send-Text $stream 400 'application/json' '{"ok":false,"reason":"bad model"}' }
        elseif ($alive -and $script:Pull.model -eq $model) { Send-Text $stream 200 'application/json' (Pull-Status $true) }
        else {
          if ($alive) { Stop-Process -Id ([int]$script:Pull.pid) -Force -ErrorAction SilentlyContinue }
          New-Item -ItemType Directory -Path $PullDir -Force | Out-Null
          $bodyf = Join-Path $PullDir 'pull_body.json'; $log = Join-Path $PullDir 'pull_log.txt'; $elog = Join-Path $PullDir 'pull_err.txt'
          [IO.File]::WriteAllText($bodyf, ('{"model":' + (Json-Str $model) + ',"stream":true}'), $utf8)
          Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
          $ourl = 'http://127.0.0.1:11434'; if ($env:M01_OLLAMA_URL) { $ourl = $env:M01_OLLAMA_URL }
          $curl = Join-Path $env:SystemRoot 'System32\curl.exe'; if (-not (Test-Path -LiteralPath $curl)) { $curl = 'curl.exe' }
          $argStr = '-sN -X POST -H "Content-Type: application/json" --data-binary "@' + $bodyf + '" ' + $ourl + '/api/pull'
          $proc = $null
          try { $proc = Start-Process -FilePath $curl -ArgumentList $argStr -RedirectStandardOutput $log -RedirectStandardError $elog -WindowStyle Hidden -PassThru } catch { $proc = $null }
          if ($proc) {
            $script:Pull = @{ pid = $proc.Id; model = $model; log = $log; total = [int64]0; done = [int64]0; t = [DateTime]::Now }; Pull-Save
            # keep the PC from going to sleep (screen can still turn off) while the download runs
            $awake = 'Add-Type -Name P -Namespace W -MemberDefinition ''[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint f);''; [void][W.P]::SetThreadExecutionState(0x80000001); Wait-Process -Id ' + $proc.Id + ' -ErrorAction SilentlyContinue'
            try { $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($awake)); Start-Process -FilePath 'powershell.exe' -ArgumentList ('-NoProfile -WindowStyle Hidden -EncodedCommand ' + $enc) -WindowStyle Hidden } catch { }
            Send-Text $stream 200 'application/json' (Pull-Status $true)
          } else { Send-Text $stream 200 'application/json' '{"ok":false,"reason":"curl missing"}' }
        }
      }
      elseif ($act -eq 'pause' -or $act -eq 'cancel') {
        if ($alive) { Stop-Process -Id ([int]$script:Pull.pid) -Force -ErrorAction SilentlyContinue }
        if ($act -eq 'cancel') { $script:Pull = $null; Remove-Item -LiteralPath (Join-Path $PullDir 'pull_state.txt') -Force -ErrorAction SilentlyContinue }
        Send-Text $stream 200 'application/json' '{"ok":true}'
      }
      else { if ($script:Pull -and $script:Pull.model) { Send-Text $stream 200 'application/json' (Pull-Status $alive) } else { Send-Text $stream 200 'application/json' '{"ok":true,"model":""}' } }
    }
    elseif ($target -eq '/ollamastart') {
      # start the Ollama app when it isn't running (the local AI needs it)
      $okStart = $false
      try {
        $app = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama app.exe'
        $cli = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'
        if (Test-Path -LiteralPath $app) { Start-Process -FilePath $app -WindowStyle Hidden; $okStart = $true }
        elseif (Test-Path -LiteralPath $cli) { Start-Process -FilePath $cli -ArgumentList 'serve' -WindowStyle Hidden; $okStart = $true }
        else { $cmd = Get-Command ollama -ErrorAction SilentlyContinue; if ($cmd) { Start-Process -FilePath $cmd.Source -ArgumentList 'serve' -WindowStyle Hidden; $okStart = $true } }
      } catch { $okStart = $false }
      if ($okStart) { Send-Text $stream 200 'application/json' '{"ok":true}' } else { Send-Text $stream 404 'application/json' '{"ok":false,"reason":"not installed"}' }
    }
    elseif ($target -eq '/sysinfo') {
      # memory size and graphics card so the app can suggest a local AI model that fits this computer
      if (-not $script:SysInfo) {
        $ram = 0; try { $ram = [int64](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory } catch { $ram = 0 }
        $gpu = ''; $vram = 0; $smiPath = $null
        $smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
        if ($smi) { $smiPath = $smi.Source } elseif (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\nvidia-smi.exe')) { $smiPath = Join-Path $env:SystemRoot 'System32\nvidia-smi.exe' }
        if ($smiPath) { try { $o = & $smiPath --query-gpu=name,memory.total --format=csv,noheader,nounits 2>$null | Select-Object -First 1; if ($o) { $parts = ([string]$o) -split ','; $gpu = $parts[0].Trim(); $vram = [int64]([double]($parts[1].Trim())) * 1048576 } } catch { } }
        if (-not $gpu) { try { $gpu = [string]((Get-CimInstance Win32_VideoController -ErrorAction Stop | Select-Object -First 1).Name) } catch { $gpu = '' } }
        $script:SysInfo = '{"ok":true,"os":"win","ram":' + $ram + ',"chip":"","gpu":' + (Json-Str $gpu) + ',"vram":' + $vram + '}'
      }
      Send-Text $stream 200 'application/json' $script:SysInfo
    }
    elseif ($target -eq '/helperupdate') {
      # one-click helper update: download the new helper from GitHub, check its fingerprint and syntax, save it and restart on it
      $q = Parse-Query $qs; $u = [string]$q['url']; $want = ([string]$q['sha']).ToLower()
      $okUrl = ($u -match '^https://[A-Za-z0-9-]+\.github\.io/[^\s?#]*server\.ps1$') -or ($env:M01_UPD_ALLOW -and $u.StartsWith($env:M01_UPD_ALLOW))
      if (-not $okUrl -or $want -notmatch '^[0-9a-f]{64}$') { Send-Text $stream 403 'application/json' '{"ok":false,"error":"forbidden"}' }
      else {
        $bytes = $null
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; $resp = Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 60; $bytes = $resp.RawContentStream.ToArray() } catch { $bytes = $null }
        $got = ''; if ($bytes) { $sha = [Security.Cryptography.SHA256]::Create(); $got = (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '') }
        $txt = ''; if ($bytes) { $txt = $utf8.GetString($bytes) }
        $nm = [regex]::Match($txt, '\$HV = (\d+)'); $nhv = 0; if ($nm.Success) { $nhv = [int]$nm.Groups[1].Value }
        $errs = $null; if ($txt) { [void][System.Management.Automation.Language.Parser]::ParseInput($txt, [ref]$null, [ref]$errs) }
        if (-not $bytes -or $got -ne $want) { Send-Text $stream 200 'application/json' '{"ok":false,"error":"checksum"}' }
        elseif ($nhv -le $HV) { Send-Text $stream 200 'application/json' '{"ok":false,"error":"notnewer"}' }
        elseif ($errs -and $errs.Count -gt 0) { Send-Text $stream 200 'application/json' '{"ok":false,"error":"invalid"}' }
        else {
          New-Item -ItemType Directory -Path $HelperOvr -Force | Out-Null
          $nf = Join-Path $HelperOvr 'server.ps1'; $tmp = $nf + '.tmp'
          [IO.File]::WriteAllBytes($tmp, $bytes); Move-Item -LiteralPath $tmp -Destination $nf -Force
          Send-Text $stream 200 'application/json' ('{"ok":true,"hv":' + $nhv + '}')
          try { $client.Close() } catch {}
          # start the new helper once this one has let go of the port, then stop this one
          $q1 = $nf -replace "'", "''"; $q2 = $WebRoot -replace "'", "''"; $q3 = $DataDirArg -replace "'", "''"
          $cmd = "Start-Sleep -Seconds 1; & '$q1' -WebRoot '$q2' -DataDir '$q3' -Port $Port"
          Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-Command', $cmd)
          $listener.Stop()
          exit
        }
      }
    }
    elseif ($target -eq '/selfupdate') {
      # one-click update: download the new app page from GitHub into a local folder; it is served instead of the bundled one when newer
      $q = Parse-Query $qs; $u = [string]$q['url']; $ovf = Join-Path $WebOvr 'index.html'
      if ($method -eq 'DELETE') { if (Test-Path -LiteralPath $ovf) { Remove-Item -LiteralPath $ovf -Force }; Send-Text $stream 200 'application/json' '{"ok":true}' }
      elseif (($u -notmatch '^https://[A-Za-z0-9-]+\.github\.io/[^\s?#]*\.html$') -and -not ($env:M01_UPD_ALLOW -and $u.StartsWith($env:M01_UPD_ALLOW))) { Send-Text $stream 403 'text/plain' 'forbidden' }
      else {
        $bytes = $null
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; $resp = Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 90; $bytes = $resp.RawContentStream.ToArray() } catch { $bytes = $null }
        $txt = ''; if ($bytes) { $txt = $utf8.GetString($bytes) }
        $v = Page-Ver $txt
        if ($v -gt 0 -and $bytes.Length -gt 100000 -and $txt -match '</html>\s*$') {
          New-Item -ItemType Directory -Path $WebOvr -Force | Out-Null; $tmp = $ovf + '.tmp'
          [IO.File]::WriteAllBytes($tmp, $bytes); Move-Item -LiteralPath $tmp -Destination $ovf -Force
          Send-Text $stream 200 'application/json' ('{"ok":true,"v":' + $v + '}')
        } else { Send-Text $stream 200 'application/json' '{"ok":false,"error":"download"}' }
      }
    }
    elseif ($target -like '/fs/*') {
      $rel = Safe-Rel $target.Substring(4)
      if (-not $rel) { Send-Text $stream 400 'text/plain' 'bad path' }
      else {
        $f = Join-Path $DataDir ($rel -replace '/', '\')
        if ($method -eq 'GET') { if (Test-Path -LiteralPath $f -PathType Leaf) { Send-Reply $stream 200 'application/octet-stream' ([System.IO.File]::ReadAllBytes($f)) } else { Send-Text $stream 404 'text/plain' 'not found' } }
        elseif ($method -eq 'PUT') {
          $dir = Split-Path -Parent $f; if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
          $tmp = "$f.tmp"; [System.IO.File]::WriteAllBytes($tmp, $body); Move-Item -LiteralPath $tmp -Destination $f -Force
          Send-Reply $stream 204 'text/plain' $null
        }
        elseif ($method -eq 'DELETE') {
          if (Test-Path -LiteralPath $f -PathType Container) { if (@(Get-ChildItem -LiteralPath $f -Force).Count -eq 0) { Remove-Item -LiteralPath $f -Force } }
          elseif (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force }
          Send-Reply $stream 204 'text/plain' $null
        }
        else { Send-Text $stream 405 'text/plain' 'method' }
      }
    }
    elseif ($target -like '/ls*') {
      $rel = Safe-Rel ($target -replace '^/ls/?', '')
      if ($null -eq $rel) { Send-Text $stream 400 'text/plain' 'bad path' }
      else {
        $d = if ($rel -eq '') { $DataDir } else { Join-Path $DataDir ($rel -replace '/', '\') }
        $items = @()
        if (Test-Path -LiteralPath $d -PathType Container) {
          foreach ($e in (Get-ChildItem -LiteralPath $d -Force | Where-Object { -not $_.Name.StartsWith('.') } | Sort-Object Name)) {
            $items += ('{"name":' + (Json-Str $e.Name) + ',"dir":' + ($(if ($e.PSIsContainer) {'true'} else {'false'})) + '}')
          }
        }
        Send-Text $stream 200 'application/json' ('[' + ($items -join ',') + ']')
      }
    }
    elseif ($target -eq '/search') {
      $q = Parse-Query $qs
      $html = Fetch-Url ('https://html.duckduckgo.com/html/?kl=tw-tzh&q=' + [System.Uri]::EscapeDataString([string]$q['q'])) 12
      if (-not $html) { Send-Text $stream 200 'application/json' '{"ok":false,"error":"offline"}' }
      else {
        $out = @()
        $ms2 = [regex]::Matches($html, '(?s)<a[^>]*class="[^"]*result__a[^"]*"[^>]*href="([^"]+)"[^>]*>(.*?)</a>(.*?)(?=<a[^>]*class="[^"]*result__a|\z)')
        foreach ($m in $ms2) {
          $href = $m.Groups[1].Value
          $u = [regex]::Match($href, '[?&]uddg=([^&]+)'); if ($u.Success) { $href = [System.Uri]::UnescapeDataString($u.Groups[1].Value) }
          if ($href.StartsWith('//')) { $href = 'https:' + $href }
          if ($href -match 'duckduckgo\.com/y\.js') { continue }
          $sn = [regex]::Match($m.Groups[3].Value, '(?s)class="[^"]*result__snippet[^"]*"[^>]*>(.*?)</a>')
          $out += ('{"title":' + (Json-Str (Html-Text $m.Groups[2].Value)) + ',"url":' + (Json-Str $href) + ',"snippet":' + (Json-Str (Html-Text $sn.Groups[1].Value)) + '}')
          if ($out.Count -ge 6) { break }
        }
        Send-Text $stream 200 'application/json' ('{"ok":true,"results":[' + ($out -join ',') + ']}')
      }
    }
    elseif ($target -eq '/fetch') {
      $q = Parse-Query $qs
      $html = Fetch-Url ([string]$q['url']) 15
      if (-not $html) { Send-Text $stream 200 'application/json' '{"ok":false,"error":"unreachable"}' }
      else { $t = Html-Text $html; if ($t.Length -gt 9000) { $t = $t.Substring(0, 9000) }; Send-Text $stream 200 'application/json' ('{"ok":true,"text":' + (Json-Str $t) + '}') }
    }
    elseif ($target -eq '/open') {
      $q = Parse-Query $qs
      if ([string]$q['url'] -match '^https?://') { Start-Process ([string]$q['url']) }
      Send-Reply $stream 204 'text/plain' $null
    }
    else {
      $p = [System.Uri]::UnescapeDataString($target); if ($p -eq '/') { $p = '/index.html' }
      if ($p -match '\.\.') { Send-Text $stream 403 'text/plain' 'no' }
      else {
        $f = Join-Path $WebRoot ($p.TrimStart('/') -replace '/', '\')
        $ext = [System.IO.Path]::GetExtension($f).TrimStart('.').ToLower()
        $ovf = Join-Path $WebOvr 'index.html'
        if ($p -eq '/index.html' -and $env:M01_NOICON -ne '1') { Start-WinIcon }
        if ($p -eq '/index.html' -and (Test-Path -LiteralPath $ovf -PathType Leaf) -and (Test-Path -LiteralPath $f -PathType Leaf) -and ((Page-Ver ([IO.File]::ReadAllText($ovf, $utf8))) -le (Page-Ver ([IO.File]::ReadAllText($f, $utf8))))) { try { Remove-Item -LiteralPath $ovf -Force } catch { } }   # an older downloaded page is left over: remove it
        if ($p -eq '/index.html' -and (Test-Path -LiteralPath $ovf -PathType Leaf) -and (Test-Path -LiteralPath $f -PathType Leaf) -and ((Page-Ver ([IO.File]::ReadAllText($ovf, $utf8))) -gt (Page-Ver ([IO.File]::ReadAllText($f, $utf8))))) { Send-Reply $stream 200 $Types['html'] ([System.IO.File]::ReadAllBytes($ovf)) }
        elseif (Test-Path -LiteralPath $f -PathType Leaf) { $t = $Types[$ext]; if (-not $t) { $t = 'application/octet-stream' }; Send-Reply $stream 200 $t ([System.IO.File]::ReadAllBytes($f)) }
        else { Send-Text $stream 404 'text/plain' 'not found' }
      }
    }
  } catch {
    try { Send-Text $stream 400 'text/plain' 'error' } catch {}
  } finally {
    if (-not $handed) { try { $client.Close() } catch {} }
  }
}
