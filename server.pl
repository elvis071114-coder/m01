#!/usr/bin/perl
# M-01 Companion local helper: serves the app and reads/writes the memory folder.
# Only listens on 127.0.0.1. Uses only modules that ship with macOS Perl.
use strict; use warnings;
use IO::Socket::INET;
use File::Path qw(make_path);
use File::Basename qw(dirname);
use Cwd qw(abs_path);
use MIME::Base64 qw(encode_base64);

# ---------- web helpers (search / read page / open link) ----------
sub html_text {
  my $h = shift // '';
  $h =~ s{<(script|style|noscript|svg|head)\b.*?</\1>}{ }gis;
  $h =~ s{<br\s*/?>|</p>|</div>|</li>|</h\d>}{\n}gi;
  $h =~ s{<[^>]+>}{ }g;
  my %ent = (amp=>'&', lt=>'<', gt=>'>', quot=>'"', apos=>"'", nbsp=>' ', '#39'=>"'");
  $h =~ s/&(#?\w+);/exists $ent{$1} ? $ent{$1} : ($1 =~ m{^#(\d+)$} ? chr($1) : "&$1;")/ge;
  $h =~ s/[ \t\r\f]+/ /g; $h =~ s/\n\s*\n+/\n/g; $h =~ s/^\s+|\s+$//g;
  return $h;
}
sub parse_ddg {
  my $html = shift // ''; my @out;
  while ($html =~ m{<a[^>]*class="[^"]*result__a[^"]*"[^>]*href="([^"]+)"[^>]*>(.*?)</a>(.*?)(?=<a[^>]*class="[^"]*result__a|\z)}gs) {
    my ($href, $title, $rest) = ($1, $2, $3);
    if ($href =~ /[?&]uddg=([^&]+)/) { $href = url_decode($1); }
    $href = "https:$href" if $href =~ m{^//};
    next if $href =~ m{duckduckgo\.com/y\.js};
    my ($snip) = $rest =~ m{class="[^"]*result__snippet[^"]*"[^>]*>(.*?)</a>}s;
    push @out, { title => html_text($title), url => $href, snippet => html_text($snip // '') };
    last if @out >= 6;
  }
  return @out;
}
sub fetch_url {
  my ($url, $secs) = @_;
  return undef unless $url =~ m{^https?://}i;
  my $data = '';
  if (open(my $ph, '-|', '/usr/bin/curl', '-sL', '--compressed', '--max-time', $secs || 12, '-A',
           'Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15', $url)) {
    binmode $ph; local $/; $data = <$ph> // ''; close $ph;
  }
  return $data;
}
if ($ENV{M01_TEST_DDG}) {  # offline parser check
  my $h = slurp($ENV{M01_TEST_DDG}); for my $r (parse_ddg($h)) { print "$r->{title} | $r->{url} | $r->{snippet}\n"; } exit 0;
}

my ($WEBROOT, $DATA, $PORT, $BUNDLE) = @ARGV;
$BUNDLE //= '';
$PORT ||= 47811;
# the user can move the memory folder from inside the app; remember their choice
my $CFG = $ENV{M01_CFG} // (($ENV{HOME} // '')."/Library/Application Support/M-01 Companion/datadir.txt");
if (defined(my $saved = slurp($CFG))) { $saved =~ s/\s+$//; $DATA = $saved if length $saved && -d $saved; }
my $DATAMARK = '_資料（請勿修改）';
my $KEYF = $ENV{M01_KEYF} // (($ENV{HOME} // '')."/Library/Application Support/M-01 Companion/claude_key");
my $GKEYF = $ENV{M01_GKEYF} // (($ENV{HOME} // '')."/Library/Application Support/M-01 Companion/gemini_key");
my $FKEYF = $ENV{M01_FKEYF} // (($ENV{HOME} // '')."/Library/Application Support/M-01 Companion/fish_key");
my $GOOGF = $ENV{M01_GOOGF} // (($ENV{HOME} // '')."/Library/Application Support/M-01 Companion/google_token");
my $GCODEF = $ENV{M01_GCODEF} // (($ENV{HOME} // '')."/Library/Application Support/M-01 Companion/google_code");
my $GTOKURL = $ENV{M01_GTOKEN_URL} // 'https://oauth2.googleapis.com/token';
my $GSECRET = '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';   # desktop-app sign-in client: Google treats this one as public
my $WEBOVR = $ENV{M01_WEBOVR} // (($ENV{HOME} // '')."/Library/Application Support/M-01 Companion/web");
my $HV = 4;   # helper version: the page asks for a reinstall when a newer helper is needed
sub page_ver { my $t = shift // ''; return $t =~ /const APP_VER="(\d+)\.(\d+)\.(\d+)"/ ? $1*1000000+$2*1000+$3 : 0; }
my $FISHBASE = $ENV{M01_FISH_URL} // 'https://api.fish.audio';
my $GEMBASE = $ENV{M01_GEMINI_URL} // 'https://generativelanguage.googleapis.com';
sub shq { my $x = shift; $x =~ s/'/'\\''/g; return "'$x'"; }
die "usage: server.pl WEBROOT DATADIR [PORT]\n" unless $WEBROOT && $DATA;
make_path($DATA) unless -d $DATA;
$DATA = abs_path($DATA);

my $srv = IO::Socket::INET->new(LocalAddr=>'127.0.0.1', LocalPort=>$PORT, Listen=>16, ReuseAddr=>1, Proto=>'tcp')
  or die "cannot listen on $PORT: $!\n";
$SIG{PIPE} = 'IGNORE';

my %TYPES = (html=>'text/html; charset=utf-8', js=>'text/javascript', css=>'text/css', json=>'application/json',
             png=>'image/png', icns=>'image/x-icns', md=>'text/markdown; charset=utf-8');

sub url_decode { my $s = shift; $s =~ s/\+/ /g; $s =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge; return $s; }
sub safe_rel {   # decoded relative path inside the data folder, or undef
  my $p = url_decode(shift // '');
  $p =~ s{^/+}{};
  return undef if $p =~ /\0/;
  for my $seg (split m{/}, $p) { return undef if $seg eq '..' || $seg eq '.'; }
  return $p;
}
sub reply {
  my ($c, $code, $type, $body, $extra) = @_;
  $body //= ''; $extra //= '';
  my %msg = (200=>'OK',204=>'No Content',400=>'Bad Request',403=>'Forbidden',404=>'Not Found',405=>'Method Not Allowed');
  print $c "HTTP/1.1 $code ".($msg{$code}||'OK')."\r\nContent-Type: $type\r\nContent-Length: ".length($body).
           "\r\nCache-Control: no-store\r\nConnection: close\r\n$extra\r\n";
  print $c $body;
}
sub slurp { my $f = shift; open(my $fh, '<:raw', $f) or return undef; local $/; my $d = <$fh>; close $fh; return $d; }
sub json_str { my $s = shift; $s =~ s/(["\\])/\\$1/g; $s =~ s/\n/\\n/g; $s =~ s/\r/\\r/g; $s =~ s/\t/\\t/g; return "\"$s\""; }

while (my $c = $srv->accept) {
  binmode $c;
  local $/ = "\r\n";
  my $req = <$c>; next unless defined $req;
  my ($method, $target) = $req =~ m{^(\S+)\s+(\S+)};
  my %h;
  while (my $line = <$c>) { last if $line eq "\r\n"; $line =~ s/\r\n$//; my ($k,$v) = split /:\s*/, $line, 2; $h{lc $k} = $v if defined $v; }
  my $body = '';
  if (my $len = $h{'content-length'}) { read($c, $body, $len); }
  my ($qs) = $target =~ /\?(.*)$/; $qs //= '';
  $target =~ s/\?.*$//;

  # only our own page may use the data API (other sites cannot send this header)
  my $api = $target =~ m{^/(fs|ls|ping|pick|search|fetch|open|battery|dictate|reveal|setdata|getjson|secret|uninstall|gemini|fishtts|gtoken|selfupdate|sysinfo|music)(/|$)};
  if ($api && ($h{'x-m01'} // '') ne '1') { reply($c, 403, 'text/plain', 'forbidden'); close $c; next; }

  if ($target eq '/battery') {
    my $o = `/usr/bin/pmset -g batt 2>/dev/null`;
    if ($o =~ /(\d+)%;\s*([a-zA-Z ]+);/) { my ($lv,$st)=($1,lc $2); my $ch = ($st =~ /^(charging|charged|finishing charge)/ || $o =~ /AC Power/) ? 'true' : 'false';
      reply($c, 200, 'application/json', qq({"ok":true,"level":$lv,"charging":$ch})); }
    else { reply($c, 200, 'application/json', '{"ok":false}'); }
  }
  elsif ($target eq '/dictate') {
    my $ok = 'false';
    if ($BUNDLE =~ /^[A-Za-z0-9.\-]+$/) { system(qq(/usr/bin/osascript -e 'tell application id "$BUNDLE" to dictate()' >/dev/null 2>&1 &)); $ok = 'true'; }
    reply($c, 200, 'application/json', qq({"ok":$ok}));
  }
  elsif ($target eq '/getjson') {
    # weather data (Open-Meteo only)
    my %q = map { my ($k,$v) = split /=/, $_, 2; ($k, url_decode($v // '')) } grep { length } split /&/, $qs;
    my $u = $q{url} // '';
    # weather (Open-Meteo) and the app's own version file on GitHub
    if ($u =~ m{^https://(geocoding-api|api)\.open-meteo\.com/} || $u =~ m{^https://get\.geojs\.io/v1/ip/geo\.json$} || $u =~ m{^https://open\.spotify\.com/oembed\?url=[\w%.\-]+$} || $u =~ m{^https://itunes\.apple\.com/search\?[\w=&.%+-]*$} || $u =~ m{^https://open\.spotify\.com/oembed\?url=[\w%.-]*$} || $u =~ m{^https://api\.bigdatacloud\.net/data/reverse-geocode-client\?[\w=&.%-]*$} || $u =~ m{^https://(raw\.githubusercontent\.com|gist\.githubusercontent\.com|[A-Za-z0-9-]+\.github\.io)/[^\s]*\.json(\?[^\s]*)?$}) { my $b = fetch_url($u, 12);
      if (defined $b && length $b) { reply($c, 200, 'application/json', $b); } else { reply($c, 200, 'application/json', '{"error":true,"reason":"unreachable"}'); } }
    else { reply($c, 403, 'text/plain', 'forbidden'); }
  }
  elsif ($target eq '/secret') {
    # the Claude API key lives in a file only this helper reads, not inside the page
    my %q = map { my ($k,$v) = split /=/, $_, 2; ($k, url_decode($v // '')) } grep { length } split /&/, $qs;
    my $P = $q{p} // ''; my $KF = $P eq 'gemini' ? $GKEYF : $P eq 'fish' ? $FKEYF : $P eq 'google' ? $GOOGF : $P eq 'gcode' ? $GCODEF : $KEYF;
    $q{reveal} = '' if $P eq 'google';   # the Google sign-in token never goes back to the page
    if ($method eq 'PUT') { my $k = $body; $k =~ s/^\s+|\s+$//g;
      if ($k eq '') { unlink $KF; } else { make_path(dirname($KF)); if (open(my $o, '>:raw', $KF)) { print $o $k; close $o; chmod 0600, $KF; } }
      reply($c, 200, 'application/json', '{"ok":true}'); }
    elsif ($method eq 'DELETE') { unlink $KF; reply($c, 200, 'application/json', '{"ok":true}'); }
    else { my $k = slurp($KF) // ''; $k =~ s/\s+$//;
      if (($q{reveal} // '') eq '1') { reply($c, 200, 'application/json', '{"ok":true,"key":'.json_str($k).'}'); }
      else { reply($c, 200, 'application/json', '{"ok":true,"has":'.($k ne '' ? 'true' : 'false').',"last4":'.json_str(length $k > 4 ? substr($k, -4) : '').'}'); } }
  }
  elsif ($target eq '/oauth') {
    # Google sign-in comes back here in the browser: hand the one-time code to the app, then say done
    my %q = map { my ($k,$v) = split /=/, $_, 2; ($k, url_decode($v // '')) } grep { length } split /&/, $qs;
    my $st = $q{state} // ''; my $cd = $q{code} // ''; my $er = $q{error} // '';
    my $okk = ($st =~ /^m01g[A-Za-z0-9]+$/ && ($cd ne '' || $er ne ''));
    if ($okk) { make_path(dirname($GCODEF)); if (open(my $o, '>:raw', $GCODEF)) { print $o $st.' '.($cd ne '' ? $cd : '!'.$er); close $o; chmod 0600, $GCODEF; } }
    my $msg = !$okk ? '登入沒有完成，請回到 M-01 再試一次。<br>Sign-in didn’t finish — go back to M-01 and try again.'
            : $cd ne '' ? '登入成功！可以關掉這個分頁，回到 M-01 了。<br>Signed in! You can close this tab and go back to M-01.'
            : '你取消了登入。可以關掉這個分頁，回到 M-01。<br>Sign-in was cancelled. You can close this tab and go back to M-01.';
    reply($c, 200, 'text/html; charset=utf-8', '<!DOCTYPE html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>M-01 Companion</title><body style="margin:0;display:grid;place-items:center;min-height:100vh;background:#0b0b0e;color:#eee;font:17px/1.8 system-ui,sans-serif;text-align:center"><div><div style="color:#ff7a3d;letter-spacing:.2em;font-size:13px">M-01 COMPANION</div><p>'.$msg.'</p></div><script>setTimeout(function(){try{window.close()}catch(e){}},1500)</script></body>');
  }
  elsif ($target eq '/gtoken') {
    # Google sign-in tokens: the long-lived refresh token stays in a local file, the page only gets short access tokens
    my %q = map { my ($k,$v) = split /=/, $_, 2; ($k, url_decode($v // '')) } grep { length } split /&/, $qs;
    my $form = $body;
    if (($q{op} // '') eq 'refresh') {
      my $rt = slurp($GOOGF) // ''; $rt =~ s/\s+$//;
      if ($rt eq '') { reply($c, 200, 'application/json', '{"status":401,"body":{"error":"not_signed_in"}}'); close $c; next; }
      (my $enc = $rt) =~ s/([^A-Za-z0-9\-_.~])/sprintf("%%%02X", ord($1))/ge; $form .= '&refresh_token='.$enc;
    }
    $form .= '&client_secret='.$GSECRET unless $form =~ /(^|&)client_secret=/;
    my $tb = "/tmp/m01-gtok-$$-b.txt";
    if (open(my $o, '>:raw', $tb)) { print $o $form; close $o; chmod 0600, $tb; }
    my $out = '';
    if (open(my $ph, '-|', '/usr/bin/curl', '-sS', '--max-time', '30', '-X', 'POST', '-H', 'Content-Type: application/x-www-form-urlencoded', '--data-binary', "\@$tb", '-w', "\n%{http_code}", $GTOKURL)) { binmode $ph; local $/; $out = <$ph> // ''; close $ph; }
    unlink $tb;
    my ($resp, $code) = $out =~ /^(.*)\n(\d{3})\s*$/s;
    if (!defined $code || $code eq '000') { reply($c, 200, 'application/json', '{"status":0,"body":null}'); }
    else {
      if ($resp =~ /"refresh_token"\s*:\s*"([^"]+)"/) { my $rt = $1; make_path(dirname($GOOGF)); if (open(my $o, '>:raw', $GOOGF)) { print $o $rt; close $o; chmod 0600, $GOOGF; }
        $resp =~ s/,\s*"refresh_token"\s*:\s*"[^"]*"// or $resp =~ s/"refresh_token"\s*:\s*"[^"]*"\s*,?//; }
      $resp = 'null' unless $resp =~ /^\s*[\[{]/;
      reply($c, 200, 'application/json', '{"status":'.$code.',"body":'.$resp.'}');
    }
  }
  elsif ($target eq '/gemini') {
    # relay to Google Gemini with the key kept in a local file (the page never sees it)
    my %q = map { my ($k,$v) = split /=/, $_, 2; ($k, url_decode($v // '')) } grep { length } split /&/, $qs;
    my $model = $q{model} // 'gemini-3.8-flash'; $model =~ s/[^A-Za-z0-9.\-]//g; $model ||= 'gemini-3.8-flash';
    my $key = slurp($GKEYF) // ''; $key =~ s/\s+$//;
    if ($key eq '') { reply($c, 200, 'application/json', '{"status":401,"body":{"error":{"message":"no key"}}}'); }
    else {
      my $tb = "/tmp/m01-gem-$$-b.json"; my $th = "/tmp/m01-gem-$$-h.txt";
      if (open(my $o, '>:raw', $tb)) { print $o $body; close $o; }
      if (open(my $o, '>:raw', $th)) { print $o "x-goog-api-key: $key\nContent-Type: application/json\n"; close $o; chmod 0600, $th; }
      my $out = '';
      if (open(my $ph, '-|', '/usr/bin/curl', '-sS', '--max-time', '120', '-X', 'POST', '-H', "\@$th", '--data-binary', "\@$tb", '-w', "\n%{http_code}", "$GEMBASE/v1beta/models/$model:generateContent")) { binmode $ph; local $/; $out = <$ph> // ''; close $ph; }
      unlink $tb, $th;
      my ($resp, $code) = $out =~ /^(.*)\n(\d{3})\s*$/s;
      if (!defined $code || $code eq '000') { reply($c, 200, 'application/json', '{"status":0,"body":null}'); }
      else { $resp = 'null' unless $resp =~ /^\s*[\[{]/; reply($c, 200, 'application/json', '{"status":'.$code.',"body":'.$resp.'}'); }
    }
  }
  elsif ($target eq '/fishtts') {
    # Fish Audio voice: relay with the key kept in a local file (the page never sees it)
    my %q = map { my ($k,$v) = split /=/, $_, 2; ($k, url_decode($v // '')) } grep { length } split /&/, $qs;
    my $model = $q{model} // 's2.1-pro-free'; $model =~ s/[^A-Za-z0-9.\-]//g; $model ||= 's2.1-pro-free';
    my $key = slurp($FKEYF) // ''; $key =~ s/\s+$//;
    if ($key eq '') { reply($c, 200, 'application/json', '{"status":401,"error":"no key"}'); }
    else {
      my $tb = "/tmp/m01-fish-$$-b.json"; my $th = "/tmp/m01-fish-$$-h.txt"; my $to = "/tmp/m01-fish-$$-o.bin";
      if (open(my $o, '>:raw', $tb)) { print $o $body; close $o; }
      if (open(my $o, '>:raw', $th)) { print $o "Authorization: Bearer $key\nContent-Type: application/json\nmodel: $model\n"; close $o; chmod 0600, $th; }
      my $code = '';
      if (open(my $ph, '-|', '/usr/bin/curl', '-sS', '--max-time', '90', '-X', 'POST', '-H', "\@$th", '--data-binary', "\@$tb", '-o', $to, '-w', '%{http_code}', "$FISHBASE/v1/tts")) { local $/; $code = <$ph> // ''; close $ph; }
      my $out = slurp($to) // ''; unlink $tb, $th, $to;
      $code =~ s/\D//g;
      if ($code eq '200' && length $out > 0) { reply($c, 200, 'audio/mpeg', $out); }
      else { my $t = substr($out, 0, 400); $t =~ s/[^\x20-\x7e]//g; reply($c, 200, 'application/json', '{"status":'.(($code ne '' && $code ne '000') ? $code+0 : 0).',"error":'.json_str($t).'}'); }
    }
  }
  elsif ($target eq '/uninstall') {
    my %q = map { my ($k,$v) = split /=/, $_, 2; ($k, url_decode($v // '')) } grep { length } split /&/, $qs;
    my $moved = 'false';
    my ($dbase) = $DATA =~ m{([^/]+)$}; $dbase //= '';
    my $safe = $DATA ne ($ENV{HOME} // '') && $DATA ne '/' && ($dbase eq 'Companion' || -d "$DATA/$DATAMARK");
    if (($q{data} // '') eq '1' && $safe) {
      my $r = -x '/usr/bin/osascript' ? system('/usr/bin/osascript', '-e', qq(tell application "Finder" to delete (POSIX file "$DATA" as alias))) : 1;
      if ($r == 0) { $moved = 'true'; }
      else { my $trash = ($ENV{HOME} // '')."/.Trash"; my @t = localtime;
        my $dst = sprintf("%s/Companion %04d-%02d-%02d %02d%02d%02d", $trash, $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0]);
        $moved = 'true' if -d $trash && rename($DATA, $dst); }
    }
    reply($c, 200, 'application/json', '{"ok":true,"dataMoved":'.$moved.',"data":'.json_str($DATA).'}');
    close $c;
    my $app = abs_path("$WEBROOT/../../..") // '';
    if ($app =~ /M-01[^\/]*\.app$/ && -d $app) {
      my $home = $ENV{HOME} // '';
      my $sh = "sleep 1\n";
      $sh .= "/usr/bin/osascript -e ".shq(qq(tell application id "$BUNDLE" to quit))." >/dev/null 2>&1\n" if $BUNDLE =~ /^[A-Za-z0-9.\-]+$/;
      $sh .= "sleep 2\nrm -rf ".shq($app)."\n";
      $sh .= "if [ ! -d '/Applications/M-01 Companion.app' ] && [ ! -d ".shq("$home/Applications/M-01 Companion.app")." ]; then\n"
           . "  launchctl unload ".shq("$home/Library/LaunchAgents/local.m01.ollama-origins.plist")." >/dev/null 2>&1\n"
           . "  rm -f ".shq("$home/Library/LaunchAgents/local.m01.ollama-origins.plist")."\n"
           . "  rm -rf ".shq("$home/Library/Application Support/M-01 Companion")."\nfi\n";
      my $tmp = "/tmp/m01-uninstall-$$.sh";
      if (open(my $o, '>', $tmp)) { print $o $sh; close $o; system("nohup /bin/bash ".shq($tmp)." >/dev/null 2>&1 &"); }
    }
    exit 0;
  }
  elsif ($target eq '/reveal') {
    system('/usr/bin/open', $DATA) if -x '/usr/bin/open';
    reply($c, 200, 'application/json', '{"ok":true,"data":'.json_str($DATA).'}');
  }
  elsif ($target eq '/setdata') {
    my %q = map { my ($k,$v) = split /=/, $_, 2; ($k, url_decode($v // '')) } grep { length } split /&/, $qs;
    my $p = $q{path} // '';
    if (($q{pick} // '') eq '1') {
      my @script = ('activate', 'try', 'set f to choose folder with prompt "選擇要放記憶的資料夾（會在裡面建立 Companion 資料夾）" default location (path to documents folder)',
        'return POSIX path of f', 'on error', 'return ""', 'end try');
      my $out = ''; if (open(my $ph, '-|', '/usr/bin/osascript', map { ('-e', $_) } @script)) { local $/; $out = <$ph> // ''; close $ph; }
      $out =~ s/\s+$//; $p = $out;
    }
    if ($p eq '') { reply($c, 200, 'application/json', '{"ok":false,"cancel":true}'); }
    else {
      $p =~ s{/+$}{}; $p = '/' if $p eq '';
      my ($base) = $p =~ m{([^/]+)$}; $base //= '';
      my $target = ($base eq 'Companion' || -d "$p/$DATAMARK") ? $p : "$p/Companion";
      make_path($target) unless -d $target;
      if (!-d $target || !-w $target) { reply($c, 200, 'application/json', '{"ok":false,"error":"cannot write"}'); }
      else {
        my $abs = abs_path($target);
        if ($abs ne $DATA) {
          system('/bin/cp', '-R', "$DATA/.", "$abs/") unless -e "$abs/$DATAMARK";
          make_path(dirname($CFG)); if (open(my $o, '>:raw', $CFG)) { print $o $abs; close $o; }
          $DATA = $abs;
        }
        reply($c, 200, 'application/json', '{"ok":true,"data":'.json_str($DATA).'}');
      }
    }
  }
  elsif ($target eq '/ping') { reply($c, 200, 'application/json', '{"ok":true,"hv":'.$HV.',"data":'.json_str($DATA).'}'); }
  elsif ($target eq '/music') {
    # what Spotify is playing, and play/pause/next/previous/volume/seek (Spotify desktop app, through AppleScript)
    my %q = map { my ($k,$v) = split /=/, $_, 2; ($k, url_decode($v // '')) } grep { length } split /&/, $qs;
    my $cmd = $q{cmd} // 'get'; $cmd = 'get' unless $cmd =~ /^(get|toggle|play|pause|next|prev|vol|seek)$/;
    my $val = $q{v} // ''; $val = '' unless $val =~ /^\d+(\.\d+)?$/;
    my $OSA = $ENV{M01_OSA} // '/usr/bin/osascript';
    my $running = $ENV{M01_OSA} ? 1 : (`/usr/bin/pgrep -x Spotify 2>/dev/null` =~ /\d/);
    if (!$running) { reply($c, 200, 'application/json', '{"ok":true,"app":"spotify","running":false}'); }
    else {
      my $JS = 'function run(a){var s=Application("Spotify");var c=a[0]||"get",v=parseFloat(a[1]);'
        .'if(c=="toggle")s.playpause();else if(c=="play")s.play();else if(c=="pause")s.pause();else if(c=="next")s.nextTrack();else if(c=="prev")s.previousTrack();'
        .'else if(c=="vol"&&v>=0)s.soundVolume=Math.max(0,Math.min(100,Math.round(v)));else if(c=="seek"&&v>=0)s.playerPosition=v;'
        .'if(c!="get")delay(0.25);'
        .'var o={ok:true,app:"spotify",running:true,state:"",title:"",artist:"",album:"",art:"",dur:0,pos:0,vol:-1,id:""};'
        .'try{o.state=s.playerState()}catch(e){}try{o.vol=s.soundVolume()}catch(e){}try{o.pos=s.playerPosition()}catch(e){}'
        .'try{var t=s.currentTrack;o.title=t.name();o.artist=t.artist();o.album=t.album();o.art=t.artworkUrl();o.dur=t.duration()/1000;o.id=t.id()}catch(e){}'
        .'return JSON.stringify(o)}';
      my $out = '';
      my $pid = open(my $ph, '-|', $OSA, '-l', 'JavaScript', '-e', $JS, $cmd, $val);
      if ($pid) {
        # never let a waiting permission prompt freeze the whole app
        my $ok = eval { local $SIG{ALRM} = sub { die "timeout\n" }; alarm 5; local $/; $out = <$ph> // ''; alarm 0; 1 };
        if (!$ok) { kill 'TERM', $pid; $out = '{"ok":false,"app":"spotify","running":true,"reason":"timeout"}'; }
        close $ph;
      }
      $out =~ s/^\s+|\s+$//g;
      if ($out =~ /^\{.*\}$/s) { reply($c, 200, 'application/json', $out); }
      else { reply($c, 200, 'application/json', '{"ok":false,"app":"spotify","running":true,"reason":"denied"}'); }
    }
  }
  elsif ($target eq '/sysinfo') {
    # memory size (and chip) so the app can suggest a local AI model that fits this computer
    my $mem = $ENV{M01_TEST_RAM} // `/usr/sbin/sysctl -n hw.memsize 2>/dev/null`; $mem =~ s/\D//g; $mem ||= 0;
    my $chip = `/usr/sbin/sysctl -n machdep.cpu.brand_string 2>/dev/null` // ''; $chip =~ s/[\r\n]//g;
    reply($c, 200, 'application/json', '{"ok":true,"os":"mac","ram":'.$mem.',"chip":'.json_str($chip).',"gpu":"","vram":0}');
  }
  elsif ($target eq '/selfupdate') {
    # one-click update: download the new app page from GitHub into a local folder; it is served instead of the bundled one when newer
    my %q = map { my ($k,$v) = split /=/, $_, 2; ($k, url_decode($v // '')) } grep { length } split /&/, $qs;
    if ($method eq 'DELETE') { unlink "$WEBOVR/index.html"; reply($c, 200, 'application/json', '{"ok":true}'); }
    else {
      my $u = $q{url} // '';
      my $allowed = $u =~ m{^https://[A-Za-z0-9-]+\.github\.io/[^\s?#]*\.html$} || (defined $ENV{M01_UPD_ALLOW} && index($u, $ENV{M01_UPD_ALLOW}) == 0);
      if (!$allowed) { reply($c, 403, 'text/plain', 'forbidden'); }
      else {
        my $b = fetch_url($u, 90);
        my $v = page_ver($b);
        if ($v && length($b) > 100000 && $b =~ /<\/html>\s*$/i) {
          make_path($WEBOVR); my $tmp = "$WEBOVR/index.html.tmp$$";
          if (open(my $o, '>:raw', $tmp)) { print $o $b; close $o; rename $tmp, "$WEBOVR/index.html"; reply($c, 200, 'application/json', '{"ok":true,"v":'.$v.'}'); }
          else { reply($c, 200, 'application/json', '{"ok":false,"error":"write"}'); }
        } else { reply($c, 200, 'application/json', '{"ok":false,"error":"download"}'); }
      }
    }
  }
  elsif ($target eq '/search' || $target eq '/fetch' || $target eq '/open') {
    my %q = map { my ($k,$v) = split /=/, $_, 2; ($k, url_decode($v // '')) } grep { length } split /&/, $qs;
    if ($target eq '/search') {
      my $term = $q{q} // '';
      (my $enc = $term) =~ s/([^A-Za-z0-9\-_.~])/sprintf("%%%02X", ord($1))/ge;
      my $html = fetch_url("https://html.duckduckgo.com/html/?q=$enc&kl=tw-tzh", 12);
      if (!defined $html || $html eq '') { reply($c, 200, 'application/json', '{"ok":false,"error":"offline"}'); }
      else {
        my @r = parse_ddg($html);
        reply($c, 200, 'application/json', '{"ok":true,"results":['.join(',', map { '{"title":'.json_str($_->{title}).',"url":'.json_str($_->{url}).',"snippet":'.json_str($_->{snippet}).'}' } @r).']}');
      }
    } elsif ($target eq '/fetch') {
      my $html = fetch_url($q{url} // '', 15);
      if (!defined $html || $html eq '') { reply($c, 200, 'application/json', '{"ok":false,"error":"unreachable"}'); }
      else { my $t = html_text($html); $t = substr($t, 0, 9000); reply($c, 200, 'application/json', '{"ok":true,"text":'.json_str($t).'}'); }
    } else {
      my $u = $q{url} // '';
      if ($u =~ m{^https?://}i) { system('/usr/bin/open', $u); }
      reply($c, 204, 'text/plain', '');
    }
  }
  elsif ($target eq '/pick') {
    # native macOS file chooser (used inside the app window, where web file pickers are not available)
    my %q = map { my ($k,$v) = split /=/, $_, 2; ($k, url_decode($v // '')) } grep { length } split /&/, $qs;
    my $types = ($q{kind} // '') eq 'image' ? ' of type {"public.image"}' : ($q{kind} // '') eq 'json' ? ' of type {"public.json"}' : '';
    my $multi = $q{multi} ? ' with multiple selections allowed' : '';
    my @script = ('activate', 'try', "set picked to choose file with prompt \"選擇檔案\"$types$multi",
      'on error', 'return ""', 'end try', 'if class of picked is not list then set picked to {picked}',
      'set out to ""', 'repeat with x in picked', 'set out to out & POSIX path of x & linefeed', 'end repeat', 'return out');
    my @args = map { ('-e', $_) } @script;
    my $out = '';
    if (open(my $ph, '-|', '/usr/bin/osascript', @args)) { local $/; $out = <$ph> // ''; close $ph; }
    my @files;
    for my $path (grep { length } split /\n/, $out) {
      next unless -f $path; my $d = slurp($path); next unless defined $d;
      my ($name) = $path =~ m{([^/]+)$}; my ($ext) = $name =~ /\.(\w+)$/; $ext = lc($ext // '');
      my %mime = (png=>'image/png', jpg=>'image/jpeg', jpeg=>'image/jpeg', gif=>'image/gif', webp=>'image/webp', heic=>'image/heic',
                  pdf=>'application/pdf', json=>'application/json', txt=>'text/plain', md=>'text/markdown', csv=>'text/csv',
                  docx=>'application/vnd.openxmlformats-officedocument.wordprocessingml.document', xlsx=>'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
      push @files, '{"name":'.json_str($name).',"type":'.json_str($mime{$ext} // 'application/octet-stream').',"b64":"'.encode_base64($d, '').'"}';
    }
    reply($c, 200, 'application/json', '['.join(',', @files).']');
  }
  elsif ($target =~ m{^/fs/(.*)$}) {
    my $rel = safe_rel($1); if (!defined $rel || $rel eq '') { reply($c, 400, 'text/plain', 'bad path'); close $c; next; }
    my $f = "$DATA/$rel";
    if ($method eq 'GET')      { my $d = -f $f ? slurp($f) : undef; defined $d ? reply($c, 200, 'application/octet-stream', $d) : reply($c, 404, 'text/plain', 'not found'); }
    elsif ($method eq 'PUT')   { make_path(dirname($f)); my $tmp = "$f.tmp$$"; if (open(my $o, '>:raw', $tmp)) { print $o $body; close $o; rename $tmp, $f; reply($c, 204, 'text/plain', ''); } else { reply($c, 400, 'text/plain', "write failed: $!"); } }
    elsif ($method eq 'DELETE'){ if (-d $f) { rmdir $f; } else { unlink $f; } reply($c, 204, 'text/plain', ''); }
    else { reply($c, 405, 'text/plain', 'method'); }
  }
  elsif ($target =~ m{^/ls/?(.*)$}) {
    my $rel = safe_rel($1); if (!defined $rel) { reply($c, 400, 'text/plain', 'bad path'); close $c; next; }
    my $d = $rel eq '' ? $DATA : "$DATA/$rel";
    my @items;
    if (opendir(my $dh, $d)) { for my $n (sort grep { !/^\./ } readdir $dh) { push @items, '{"name":'.json_str($n).',"dir":'.((-d "$d/$n")?'true':'false').'}'; } closedir $dh; }
    reply($c, 200, 'application/json', '['.join(',', @items).']');
  }
  else {
    my $p = url_decode($target); $p = '/index.html' if $p eq '/';
    if ($p =~ /\.\./) { reply($c, 403, 'text/plain', 'no'); close $c; next; }
    my $f = "$WEBROOT$p"; my ($ext) = $p =~ /\.(\w+)$/;
    my $d = -f $f ? slurp($f) : undef;
    if ($p eq '/index.html' && -f "$WEBOVR/index.html") { my $o = slurp("$WEBOVR/index.html"); if (defined $o && page_ver($o) > page_ver($d)) { $d = $o; } else { unlink "$WEBOVR/index.html"; } }   # an older downloaded page is left over: remove it
    defined $d ? reply($c, 200, $TYPES{lc($ext // '')} // 'application/octet-stream', $d) : reply($c, 404, 'text/plain', 'not found');
  }
  close $c;
}
