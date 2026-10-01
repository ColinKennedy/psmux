# A large paste must not stop the server.
#
# THE DEFECT (found while investigating #719)
# -------------------------------------------
# write_paste_bytes (src/input.rs) wrote 512 bytes and slept 5 ms after each
# slice ON THE SERVER THREAD, a pacing added in 96f3e89 for #74.  Every paste
# that takes that path, `paste-buffer -p` and the `send-paste` an attached
# client sends for Ctrl+V, froze every pane, every client and every CLI call
# for the length of the paste.  Measured on e3b942c, display-message every
# 50 ms against the server while pasting into a pane that reads promptly:
#
#   16 KB    longest gap between answers   ~0.2 s
#   132 KB                                 ~1.4 s
#   1.3 MB                                 ~14.3 s, four CLI calls answered
#                                          "no response from server (timed out)"
#
# tmux writes a paste into the pane's non blocking bufferevent and returns
# (cmd-paste-buffer.c, window.c window_pane_paste); libevent drains it as the
# pty accepts it.  psmux already has the same shape, a queued writer per pane
# drained by its own thread (78cebea), so the fix hands the whole paste to that
# queue and returns.
#
# WHAT THIS SUITE PROVES, on the bytes a pane child reads (tests\paste_drain_probe.cs)
#   1. paste-buffer -p of 1.3 MB: the server keeps answering (longest
#      display-message round trip under the threshold, no timeout), keys typed
#      into ANOTHER pane during the paste arrive promptly and only there, and
#      the paste arrives complete and byte exact (length + FNV-1a 64).
#   2. The same through send-paste on the server's TCP port, the command an
#      attached client sends for a Ctrl+V (no 32 KB command line cap).
#   3. Keys sent to the pasted pane right after the paste land after ESC[201~,
#      never inside the brackets.
#   4. synchronize-panes: the client paste reaches both panes byte exact.
#   5. kill-pane, respawn-pane -k and kill-server while a 1.3 MB paste is still
#      queued for a child that never reads: the server stays up and answers
#      (or, for kill-server, exits promptly).
#
# Numbers go to $env:USERPROFILE\.psmux-test-data\metrics\large_paste_stall-*.json
#
# Run: pwsh -NoProfile -ExecutionPolicy Bypass -File tests\test_large_paste_no_server_stall.ps1
$ErrorActionPreference = "Continue"
. "$PSScriptRoot\perf_metrics_common.ps1"
$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$NS = if ($env:PSMUX_TEST_NS) { $env:PSMUX_TEST_NS } else { "lpstall$PID" }
$MaxRttMs = if ($env:PSMUX_PASTE_STALL_MAX_MS) { [int]$env:PSMUX_PASTE_STALL_MAX_MS } else { 250 }
$script:Pass = 0; $script:Fail = 0; $script:Skip = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }
function Write-Info($m) { Write-Host "  [INFO] $m" -ForegroundColor DarkGray }

foreach ($v in 'PSMUX_SESSION_NAME','PSMUX_SESSION','PSMUX_PANE','TMUX','TMUX_PANE') { Remove-Item "Env:\$v" -EA SilentlyContinue }
$savedDataDir = $env:PSMUX_DATA_DIR
$savedNoWarm  = $env:PSMUX_NO_WARM
$root = Join-Path $env:TEMP "psmux_lpstall_$PID"
Remove-Item -Recurse -Force $root -EA SilentlyContinue
New-Item -ItemType Directory -Force $root | Out-Null
$env:PSMUX_DATA_DIR = Join-Path $root "data"
New-Item -ItemType Directory -Force $env:PSMUX_DATA_DIR | Out-Null
$env:PSMUX_NO_WARM = "1"

$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { $csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe" }
$probe = Join-Path $root "paste_drain_probe.exe"
& $csc /nologo /optimize /platform:x64 /out:$probe (Join-Path $PSScriptRoot "paste_drain_probe.cs") 2>&1 | Out-Null
if (-not (Test-Path $probe)) { Write-Host "FATAL: could not compile tests\paste_drain_probe.cs" -ForegroundColor Red; exit 1 }
Write-Info ("psmux: {0}  ({1})  ns={2}  threshold={3} ms" -f $PSMUX, ((& $PSMUX -V) -join ' '), $NS, $MaxRttMs)

Add-Type -TypeDefinition @'
public static class LpFnv {
    public static string Hash(byte[] b) {
        ulong h = 14695981039346656037UL;
        foreach (var x in b) { h ^= x; h *= 1099511628211UL; }
        return h.ToString("x16");
    }
}
'@
$freq = [Diagnostics.Stopwatch]::Frequency
function QpcMs($a, $b) { return [double]($b - $a) * 1000.0 / $freq }

# 1.3 MB of printable lines, LF separated.  paste-buffer turns each LF into CR
# (cmd-paste-buffer.c:93) and so does a client paste (CRLF/LF to CR).
$size = 1300 * 1024
$sb = New-Object System.Text.StringBuilder
$n = 0
while ($sb.Length -lt $size) { [void]$sb.Append(('L{0:D6} abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ-0123456789' -f $n)).Append("`n"); $n++ }
$text = $sb.ToString().Substring(0, $size - 1) + "`n"
$bufFile = Join-Path $root "big.txt"
[IO.File]::WriteAllBytes($bufFile, [Text.Encoding]::ASCII.GetBytes($text))
$expect = [Text.Encoding]::ASCII.GetBytes("`e[200~" + $text.Replace("`n", "`r") + "`e[201~")
$expectFnv = [LpFnv]::Hash($expect)

function Read-Probe([string]$log) {
    $h = @{}
    foreach ($l in (Get-Content $log -EA SilentlyContinue)) { $i = $l.IndexOf(' '); if ($i -gt 0) { $h[$l.Substring(0, $i)] = $l.Substring($i + 1) } }
    return $h
}
function Wait-Ready([string]$target) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 15000) {
        if (((& $PSMUX -L $NS capture-pane -p -t $target) -join "`n") -match 'paste_drain_probe .* ready') { return $true }
        Start-Sleep -Milliseconds 100
    }
    return $false
}
function New-ProbeSession([string]$Sess, [string]$ModeB = 'read', [string]$BpB = 'off') {
    $a = Join-Path $root "$Sess.A.log"; $b = Join-Path $root "$Sess.B.log"; $stop = Join-Path $root "$Sess.stop"
    & $PSMUX -L $NS new-session -d -s $Sess -x 120 -y 30 -- $probe $a on $stop read 2>&1 | Out-Null
    & $PSMUX -L $NS split-window -d -t $Sess -- $probe $b $BpB $stop $ModeB 2>&1 | Out-Null
    [void](Wait-Ready "${Sess}:0.0"); [void](Wait-Ready "${Sess}:0.1")
    # Buffers live in the session's server; one probe session exists at a time.
    & $PSMUX -L $NS load-buffer -b big $bufFile 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    return @{ Sess = $Sess; A = $a; B = $b; Stop = $stop; PaneA = "${Sess}:0.0"; PaneB = "${Sess}:0.1" }
}
function Stop-ProbeSession($s) {
    New-Item -ItemType File -Force $s.Stop | Out-Null
    Start-Sleep -Milliseconds 500
    & $PSMUX -L $NS kill-session -t $s.Sess 2>&1 | Out-Null
}

# display-message every 50 ms from a second thread; logs start qpc, ms, ok.
function Start-Monitor([string]$Sess) {
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript({
        param($psmux, $ns, $sess, $dataDir, $flag)
        $env:PSMUX_DATA_DIR = $dataDir
        $out = New-Object System.Collections.Generic.List[object]
        $sw = [Diagnostics.Stopwatch]::new()
        $pidFile = Join-Path $dataDir "${ns}__$sess.pid"
        $spid = 0; try { $spid = [int](((Get-Content $pidFile -Raw).Trim() -split ':')[0]) } catch { }
        while (-not $flag.Stop) {
            $q = [Diagnostics.Stopwatch]::GetTimestamp(); $sw.Restart()
            $r = (& $psmux -L $ns display-message -p x 2>&1) -join ' '
            $ms = $sw.Elapsed.TotalMilliseconds
            $priv = 0; if ($spid) { try { $priv = (Get-Process -Id $spid -EA Stop).PrivateMemorySize64 } catch { } }
            $out.Add([pscustomobject]@{ q = $q; ms = $ms; ok = ($r.Trim() -eq 'x'); err = $r; priv = $priv })
            $rest = 50 - [int]$ms; if ($rest -gt 0) { Start-Sleep -Milliseconds $rest }
        }
        return $out
    }).AddArgument($PSMUX).AddArgument($NS).AddArgument($Sess).AddArgument($env:PSMUX_DATA_DIR).AddArgument($script:MonFlag)
    return @{ PS = $ps; H = $ps.BeginInvoke() }
}
$script:MonFlag = [hashtable]::Synchronized(@{ Stop = $false })
function Stop-Monitor($m) {
    $script:MonFlag.Stop = $true
    $r = $m.PS.EndInvoke($m.H); $m.PS.Dispose(); $script:MonFlag.Stop = $false
    return @($r)
}

function Send-PasteTcp([string]$Sess, [string]$File) {
    $base = Join-Path $env:PSMUX_DATA_DIR "${NS}__$Sess"
    $port = [int](Get-Content "$base.port" -Raw).Trim(); $key = (Get-Content "$base.key" -Raw).Trim()
    $tcp = [Net.Sockets.TcpClient]::new(); $tcp.NoDelay = $true; $tcp.Connect('127.0.0.1', $port)
    $st = $tcp.GetStream(); $w = [IO.StreamWriter]::new($st, [Text.UTF8Encoding]::new($false)); $w.NewLine = "`n"
    $w.WriteLine("AUTH $key"); $w.Flush()
    $hello = [IO.StreamReader]::new($st).ReadLine()
    $w.WriteLine("send-paste " + [Convert]::ToBase64String([IO.File]::ReadAllBytes($File))); $w.Flush()
    Start-Sleep -Milliseconds 300
    $tcp.Close()
    return $hello
}

# One paste while another thread measures the server and this one types into
# pane B every 100 ms.  Returns the numbers.
function Measure-Paste($s, [scriptblock]$Paste, [int]$ExpectLen, [string]$Label) {
    $mon = Start-Monitor $s.Sess
    Start-Sleep -Milliseconds 800
    $t0 = [Diagnostics.Stopwatch]::GetTimestamp()
    & $Paste
    $pasteReturnMs = QpcMs $t0 ([Diagnostics.Stopwatch]::GetTimestamp())
    $keys = New-Object System.Collections.Generic.List[long]
    $done = $false; $doneQ = 0; $k = 0
    while ((QpcMs $t0 ([Diagnostics.Stopwatch]::GetTimestamp())) -lt 60000) {
        $k++
        $keys.Add([Diagnostics.Stopwatch]::GetTimestamp())
        & $PSMUX -L $NS send-keys -t $s.PaneB -l ([string][char](97 + $k % 26)) 2>&1 | Out-Null
        $pa = Read-Probe $s.A
        if ([int64]$pa['TOTAL'] -ge $ExpectLen) { $done = $true; $doneQ = [int64]$pa['LAST']; break }
        Start-Sleep -Milliseconds 100
    }
    Start-Sleep -Milliseconds 600
    $rows = Stop-Monitor $mon
    $pa = Read-Probe $s.A; $pb = Read-Probe $s.B
    $arr = @(($pb['KEYS'] -split ' ') | Where-Object { $_ -match ':' })
    $klat = @(); for ($i = 0; $i -lt [Math]::Min($arr.Count, $keys.Count); $i++) { $klat += (QpcMs $keys[$i] ([int64]($arr[$i].Split(':')[0]))) }
    $during = @($rows | Where-Object { $_.q -ge $t0 })
    $before = @($rows | Where-Object { $_.q -lt $t0 })
    return [ordered]@{
        label = $Label
        paste_call_ms = [Math]::Round($pasteReturnMs, 1)
        paste_complete_ms = if ($done) { [Math]::Round((QpcMs $t0 $doneQ), 1) } else { $null }
        bytes_expected = $ExpectLen; bytes_got = [int64]$pa['TOTAL']; fnv_ok = ($pa['FNV'] -eq $expectFnv)
        rtt_idle = Get-PerfStats @($before | ForEach-Object { $_.ms })
        rtt_during = Get-PerfStats @($during | ForEach-Object { $_.ms })
        cli_errors = @($rows | Where-Object { -not $_.ok }).Count
        cli_error_sample = (@($rows | Where-Object { -not $_.ok } | Select-Object -First 1 | ForEach-Object { $_.err }) -join '')
        keys_sent = $keys.Count; keys_got_in_b = $arr.Count
        key_latency_ms = Get-PerfStats $klat
        server_private_mb = Get-PerfStats @($rows | Where-Object { $_.priv -gt 0 } | ForEach-Object { $_.priv / 1MB })
    }
}

$results = [ordered]@{}
try {
    & $PSMUX -L $NS kill-server 2>&1 | Out-Null
    Add-PerfLoadSample "start" | Out-Null

    foreach ($case in @(
        @{ name = 'paste-buffer -p'; key = 'paste_buffer_p'; sess = 'pb' },
        @{ name = 'client send-paste over TCP (Ctrl+V path)'; key = 'client_send_paste'; sess = 'cv' }
    )) {
        Write-Host "`n=== 1.3 MB $($case.name) into a reading pane, while pane B is typed into ===" -ForegroundColor Yellow
        $s = New-ProbeSession $case.sess
        if ($case.key -eq 'paste_buffer_p') {
            $paste = { & $PSMUX -L $NS paste-buffer -p -b big -t $s.PaneA 2>&1 | Out-Null }
        } else {
            & $PSMUX -L $NS select-pane -t $s.PaneA 2>&1 | Out-Null
            $paste = { [void](Send-PasteTcp $s.Sess $bufFile) }
        }
        $r = Measure-Paste $s $paste $expect.Length $case.name
        $results[$case.key] = $r
        Write-Info ("paste call {0} ms, complete {1} ms; display-message during: p50 {2} max {3} ms (idle p50 {4}); key into B: max {5} ms; server private MB max {6}" -f $r.paste_call_ms, $r.paste_complete_ms, $r.rtt_during.p50, $r.rtt_during.max, $r.rtt_idle.p50, $r.key_latency_ms.max, $r.server_private_mb.max)
        if ($r.cli_errors -eq 0) { Write-Pass "no CLI call failed during the paste" } else { Write-Fail "$($r.cli_errors) CLI calls failed during the paste: $($r.cli_error_sample)" }
        if ($null -ne $r.rtt_during.max -and $r.rtt_during.max -lt $MaxRttMs) { Write-Pass "longest display-message round trip during the paste $($r.rtt_during.max) ms < $MaxRttMs ms" }
        else { Write-Fail "longest display-message round trip during the paste $($r.rtt_during.max) ms (threshold $MaxRttMs ms)" }
        if ($r.keys_got_in_b -eq $r.keys_sent -and $r.key_latency_ms.max -lt $MaxRttMs) { Write-Pass "all $($r.keys_sent) keys typed into pane B arrived there, slowest $($r.key_latency_ms.max) ms" }
        else { Write-Fail "keys into pane B: $($r.keys_got_in_b) of $($r.keys_sent) arrived, slowest $($r.key_latency_ms.max) ms" }
        if ($r.bytes_got -eq $r.bytes_expected -and $r.fnv_ok) { Write-Pass "the paste arrived complete and byte exact ($($r.bytes_got) bytes, FNV match)" }
        else { Write-Fail "the paste arrived as $($r.bytes_got) of $($r.bytes_expected) bytes, FNV match $($r.fnv_ok)" }
        Stop-ProbeSession $s
    }

    Write-Host "`n=== keys sent to the pasted pane right after the paste land after ESC[201~ ===" -ForegroundColor Yellow
    $s = New-ProbeSession 'ord'
    & $PSMUX -L $NS paste-buffer -p -b big -t $s.PaneA 2>&1 | Out-Null
    & $PSMUX -L $NS send-keys -t $s.PaneA -l 'AFTER-719' 2>&1 | Out-Null
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 30000 -and [int64](Read-Probe $s.A)['TOTAL'] -lt $expect.Length + 9) { Start-Sleep -Milliseconds 200 }
    New-Item -ItemType File -Force $s.Stop | Out-Null; Start-Sleep -Milliseconds 800
    $bin = [IO.File]::ReadAllBytes("$($s.A).bin")
    $want = $expect + [Text.Encoding]::ASCII.GetBytes('AFTER-719')
    if ($bin.Length -eq $want.Length -and [LpFnv]::Hash($bin) -eq [LpFnv]::Hash($want)) { Write-Pass "pane A read ESC[200~ + 1.3 MB + ESC[201~ then AFTER-719, nothing interleaved" }
    else { Write-Fail "pane A read $($bin.Length) bytes, wanted $($want.Length) ending in ESC[201~AFTER-719" }
    & $PSMUX -L $NS kill-session -t $s.Sess 2>&1 | Out-Null

    Write-Host "`n=== synchronize-panes: a client paste reaches both panes byte exact ===" -ForegroundColor Yellow
    $s = New-ProbeSession 'syn' -BpB 'on'
    & $PSMUX -L $NS set-option -w -t $s.Sess synchronize-panes on 2>&1 | Out-Null
    [void](Send-PasteTcp $s.Sess $bufFile)
    $sw.Restart()
    while ($sw.ElapsedMilliseconds -lt 30000 -and ([int64](Read-Probe $s.A)['TOTAL'] -lt $expect.Length -or [int64](Read-Probe $s.B)['TOTAL'] -lt $expect.Length)) { Start-Sleep -Milliseconds 200 }
    $ra = Read-Probe $s.A; $rb = Read-Probe $s.B
    if ($ra['FNV'] -eq $expectFnv -and $rb['FNV'] -eq $expectFnv) { Write-Pass "both panes read the paste byte exact ($($ra['TOTAL']) and $($rb['TOTAL']) bytes)" }
    else { Write-Fail "pane A $($ra['TOTAL']) bytes FNV ok $($ra['FNV'] -eq $expectFnv), pane B $($rb['TOTAL']) bytes FNV ok $($rb['FNV'] -eq $expectFnv)" }
    Stop-ProbeSession $s

    Write-Host "`n=== a pane killed or respawned while a 1.3 MB paste is queued for it ===" -ForegroundColor Yellow
    foreach ($act in @('kill-pane', 'respawn-pane')) {
        $s = New-ProbeSession "die$($act.Length)" -ModeB 'noread' -BpB 'on'
        & $PSMUX -L $NS paste-buffer -p -b big -t $s.PaneB 2>&1 | Out-Null
        & $PSMUX -L $NS paste-buffer -p -b big -t $s.PaneB 2>&1 | Out-Null
        if ($act -eq 'kill-pane') { & $PSMUX -L $NS kill-pane -t $s.PaneB 2>&1 | Out-Null }
        else { & $PSMUX -L $NS respawn-pane -k -t $s.PaneB -- $probe (Join-Path $root "respawned.log") off $s.Stop read 2>&1 | Out-Null }
        $sw.Restart(); $okAll = $true
        for ($i = 0; $i -lt 10; $i++) { if (((& $PSMUX -L $NS display-message -t $s.PaneA -p x 2>&1) -join '').Trim() -ne 'x') { $okAll = $false } }
        $panes = ((& $PSMUX -L $NS list-panes -t $s.Sess -F '#{pane_index}' 2>&1) -join ',')
        $want = if ($act -eq 'kill-pane') { '0' } else { '0,1' }
        if ($okAll -and $panes -eq $want) { Write-Pass "$act during a queued paste: server answered 10 of 10 queries in $($sw.ElapsedMilliseconds) ms, panes $panes" }
        else { Write-Fail "$act during a queued paste: answered all=$okAll, panes '$panes' (want '$want')" }
        Stop-ProbeSession $s
    }

    Write-Host "`n=== kill-server while a 1.3 MB paste is queued ===" -ForegroundColor Yellow
    $s = New-ProbeSession 'ks' -ModeB 'noread' -BpB 'on'
    $spid = Get-PerfServerPid -Ns $NS -Session $s.Sess
    & $PSMUX -L $NS paste-buffer -p -b big -t $s.PaneB 2>&1 | Out-Null
    New-Item -ItemType File -Force $s.Stop | Out-Null
    $sw.Restart()
    & $PSMUX -L $NS kill-server 2>&1 | Out-Null
    $gone = $false
    while ($sw.ElapsedMilliseconds -lt 10000) { if (-not $spid -or -not (Get-Process -Id $spid -EA SilentlyContinue)) { $gone = $true; break }; Start-Sleep -Milliseconds 100 }
    if ($gone) { Write-Pass "the server of that session exited $($sw.ElapsedMilliseconds) ms after kill-server" }
    else { Write-Fail "the server (pid $spid) was still running 10 s after kill-server" }
} finally {
    & $PSMUX -L $NS kill-server 2>&1 | Out-Null
    Add-PerfLoadSample "end" | Out-Null
    $results['threshold_ms'] = $MaxRttMs
    $results['paste_bytes'] = $expect.Length
    $results['passed'] = $script:Pass; $results['failed'] = $script:Fail
    $mp = Write-PerfMetrics -Suite "large_paste_stall" -Binary $PSMUX -Data $results
    if ($mp) { Write-Info "metrics: $mp" }
    $env:PSMUX_DATA_DIR = $savedDataDir
    $env:PSMUX_NO_WARM = $savedNoWarm
    Start-Sleep -Milliseconds 500
    Remove-Item -Recurse -Force $root -EA SilentlyContinue
}

Write-Host ("`nResults: {0} passed, {1} failed, {2} skipped" -f $script:Pass, $script:Fail, $script:Skip)
exit $script:Fail
