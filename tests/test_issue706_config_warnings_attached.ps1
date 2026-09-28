# Issue #706: config warnings never reached the screen when psmux was started
# attached.
#
# The server binds its port, writes the port file and starts accepting before
# it reads the config, on purpose: a `run-shell` inside the config has to be
# able to connect back to the server that is running it. The detached readiness
# gate waits for `list-windows`, which only the main loop answers, so by then
# the config is loaded and `config-warnings.log` is written. The attached gate
# is connectivity alone, which the server offers long before, so the read got
# in first and found nothing.
#
# Both processes timestamp with QueryPerformanceCounter, which is system wide,
# so `PSMUX_STARTUP_TRACE` settles the order without depending on how fast
# either side happens to be on the day. Traced on master `f31103e`:
#
#     cli.server.spawn                          the client starts a server
#     srv.listen                                the port is open
#     cli.ready                                 the gate accepts it
#     cli.cfgwarn   found=0 detached=false      the client reads, too early
#     srv.config                                the server reads the config
#     srv.cfgwarn   n=3                         and only now writes the log
#
# and with the fix the last three read:
#
#     srv.config
#     srv.cfgwarn   n=3
#     cli.cfgwarn   found=3 detached=false
#
# The order check below is the one that cannot flake, because it compares two
# timestamps rather than racing them. The screen check that follows is the
# user-visible half, read from the real console of a shell that outlives the
# client (tests/conread.cs): the warnings go to the terminal rather than into a
# pane, so nothing psmux can be asked afterwards remembers them.

$ErrorActionPreference = "Continue"
$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$NS = if ($env:PSMUX_TEST_NS) { $env:PSMUX_TEST_NS } else { "i706cw" }

$script:TestsPassed = 0
$script:TestsFailed = 0
$script:TestsSkipped = 0
function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Skip($msg) { Write-Host "  [SKIP] $msg" -ForegroundColor Yellow; $script:TestsSkipped++ }
function Write-Info($msg) { Write-Host "  [INFO] $msg" -ForegroundColor Cyan }

$repoTests = Split-Path -Parent $MyInvocation.MyCommand.Path
# A shell running inside psmux hands its child the session markers, and a
# nested client refuses to start, so clear them before launching one.
foreach ($v in 'PSMUX_SESSION','PSMUX_TARGET_SESSION','PSMUX_PANE','TMUX','TMUX_PANE','PSMUX') {
    Remove-Item "env:$v" -EA SilentlyContinue
}
$savedDataDir = $env:PSMUX_DATA_DIR
$savedNoWarm  = $env:PSMUX_NO_WARM
$savedTrace   = $env:PSMUX_STARTUP_TRACE
$root = Join-Path $env:TEMP "psmux_i706_cw"
Remove-Item -Recurse -Force $root -EA SilentlyContinue
New-Item -ItemType Directory -Force $root | Out-Null
# The standby is deliberately left on. Turning it off makes the server reach
# the config load sooner and win the race on its own, which hides the bug.
Remove-Item env:PSMUX_NO_WARM -EA SilentlyContinue

Write-Host ""
Write-Host "=== Issue #706: config warnings on an attached start ===" -ForegroundColor Magenta
Write-Info "Binary: $PSMUX"

function Stop-Ns([string]$ns) { & $PSMUX -L $ns kill-server 2>&1 | Out-Null }

function Exit-Test([int]$code) {
    Remove-Item -Recurse -Force $root -EA SilentlyContinue
    if ($null -ne $savedDataDir) { $env:PSMUX_DATA_DIR = $savedDataDir } else { Remove-Item env:PSMUX_DATA_DIR -EA SilentlyContinue }
    if ($null -ne $savedNoWarm)  { $env:PSMUX_NO_WARM  = $savedNoWarm }  else { Remove-Item env:PSMUX_NO_WARM  -EA SilentlyContinue }
    if ($null -ne $savedTrace)   { $env:PSMUX_STARTUP_TRACE = $savedTrace } else { Remove-Item env:PSMUX_STARTUP_TRACE -EA SilentlyContinue }
    exit $code
}

# One config with an invented option, one with nothing wrong in it.
#
# The bad one also spawns two hundred short lived processes while it is being
# read. That is what a plugin heavy config does, and it is what makes the race
# land the same way every time: the config load is the last thing the server
# does, so a config that takes real time to load leaves the old client reading
# an empty log on every run. With a one line config the server usually wins on
# its own and the bug hides. Measured on the build without the fix: three runs
# out of three read before the write with a config like this, and three out of
# three read after it with a one line config.
$cfgBad = Join-Path $root "bad.conf"
$cfgOk = Join-Path $root "clean.conf"
$badLines = New-Object System.Collections.Generic.List[string]
$badLines.Add("set -g made-up-option-aaa on")
1..200 | ForEach-Object { $badLines.Add('run-shell "cmd /c exit"') }
Set-Content -Path $cfgBad -Encoding UTF8 -Value $badLines
Set-Content -Path $cfgOk -Encoding UTF8 -Value "set -g history-limit 1234"

function New-DataDir([string]$tag) {
    $d = Join-Path $root ("data_" + $tag)
    New-Item -ItemType Directory -Force $d | Out-Null
    $env:PSMUX_DATA_DIR = $d
}

# --- 1. the order, which is what actually broke ----------------------------
Write-Host ""
Write-Host "--- the client must read the log after the server writes it ---" -ForegroundColor Yellow
New-DataDir "order"
$traceDir = Join-Path $root "trace"
New-Item -ItemType Directory -Force $traceDir | Out-Null
$env:PSMUX_STARTUP_TRACE = Join-Path $traceDir "t"
$ns1 = "${NS}1"
Stop-Ns $ns1
Start-Sleep -Milliseconds 600
$proc = Start-Process -FilePath $PSMUX -ArgumentList "-L",$ns1,"-f",$cfgBad,"new-session","-s","s" -PassThru
Start-Sleep -Seconds 10
Stop-Ns $ns1
Start-Sleep -Seconds 2
Stop-Process -Id $proc.Id -Force -EA SilentlyContinue
Remove-Item env:PSMUX_STARTUP_TRACE -EA SilentlyContinue

$rows = @()
Get-ChildItem $traceDir -Filter "t.*" -EA SilentlyContinue | ForEach-Object {
    Get-Content $_.FullName | ForEach-Object {
        if ($_ -match '^(\d+)\s+(\S+)(.*)$') {
            $rows += [pscustomobject]@{ t = [int64]$Matches[1]; label = $Matches[2]; detail = $Matches[3].Trim() }
        }
    }
}
$read = @($rows | Where-Object { $_.label -eq 'cli.cfgwarn' } | Sort-Object t)
$write = @($rows | Where-Object { $_.label -eq 'srv.cfgwarn' } | Sort-Object t)
if ($read.Count -eq 0 -or $write.Count -eq 0) {
    Write-Skip "the trace did not record both marks (read=$($read.Count) write=$($write.Count))"
} else {
    Write-Info ("srv.cfgwarn {0}   cli.cfgwarn {1}" -f $write[0].detail, $read[0].detail)
    if ($read[0].t -gt $write[0].t) {
        Write-Pass "the read lands after the write (#706 read first and found nothing)"
    } else {
        Write-Fail ("the read is {0} ticks before the write" -f ($write[0].t - $read[0].t))
    }
    if ($read[0].detail -match 'found=(\d+)' -and [int]$Matches[1] -gt 0) {
        Write-Pass "the client found $($Matches[1]) warning(s) to print"
    } else {
        Write-Fail "the client found nothing: $($read[0].detail)"
    }
}

# --- 2. and they reach the terminal ----------------------------------------
Write-Host ""
Write-Host "--- the warning reaches the terminal ---" -ForegroundColor Yellow
$CONREAD = Join-Path $root "conread.exe"
$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (Test-Path $csc) {
    & $csc /nologo /optimize /out:$CONREAD (Join-Path $repoTests "conread.cs") 2>&1 | Out-Null
}
if (-not (Test-Path $CONREAD)) {
    Write-Skip "conread.exe could not be built, so the drawn screen cannot be read"
} else {
    New-DataDir "screen"
    $ns2 = "${NS}2"
    Stop-Ns $ns2
    Start-Sleep -Milliseconds 500
    $cmd = "& '$PSMUX' -L $ns2 -f '$cfgBad' new-session -s s"
    $shell = Start-Process -FilePath "pwsh.exe" -ArgumentList "-NoExit","-NoProfile","-Command",$cmd -PassThru
    Start-Sleep -Seconds 10
    Stop-Ns $ns2
    Start-Sleep -Seconds 3
    $screen = (& $CONREAD $shell.Id 2>&1 | Out-String)
    Stop-Process -Id $shell.Id -Force -EA SilentlyContinue
    if ($screen -match 'made-up-option-aaa') {
        Write-Pass "the warning is on the terminal after the client exits"
    } else {
        Write-Fail "nothing on the terminal"
        ($screen -split "`n") | Where-Object { $_.Trim() -ne "" } | Select-Object -First 4 | ForEach-Object { Write-Info ("screen: " + $_.TrimEnd()) }
    }
}

# --- 3. a bare start, which is how psmux is usually started ----------------
Write-Host ""
Write-Host "--- a bare psmux, with no subcommand at all ---" -ForegroundColor Yellow
# The reporting used to live only in the `new-session` arm, so the commonest
# way to start psmux went through the fall through path below it and said
# nothing. A start with no subcommand reaches the same TUI and has to report
# the same warnings.
if (-not (Test-Path $CONREAD)) {
    Write-Skip "conread.exe could not be built, so the drawn screen cannot be read"
} else {
    New-DataDir "bare"
    $nsB = "${NS}B"
    Stop-Ns $nsB
    Start-Sleep -Milliseconds 500
    $cmd = "& '$PSMUX' -L $nsB -f '$cfgBad'"
    $shell = Start-Process -FilePath "pwsh.exe" -ArgumentList "-NoExit","-NoProfile","-Command",$cmd -PassThru
    Start-Sleep -Seconds 10
    Stop-Ns $nsB
    Start-Sleep -Seconds 3
    $screen = (& $CONREAD $shell.Id 2>&1 | Out-String)
    Stop-Process -Id $shell.Id -Force -EA SilentlyContinue
    if ($screen -match 'made-up-option-aaa') {
        Write-Pass "a bare start reports too (#706 reported only from new-session)"
    } else {
        Write-Fail "a bare start said nothing"
        ($screen -split "`n") | Where-Object { $_.Trim() -ne "" } | Select-Object -First 4 | ForEach-Object { Write-Info ("screen: " + $_.TrimEnd()) }
    }
}

# --- 4. a detached start still works ---------------------------------------
Write-Host ""
Write-Host "--- a detached start, which was never broken ---" -ForegroundColor Yellow
New-DataDir "detached"
$ns3 = "${NS}3"
Stop-Ns $ns3
Start-Sleep -Milliseconds 400
$out = (& $PSMUX -L $ns3 -f $cfgBad new-session -d -s d 2>&1 | Out-String)
Stop-Ns $ns3
if ($out -match 'made-up-option-aaa') {
    Write-Pass "the detached start still prints its warning"
} else {
    Write-Fail "the detached start stopped printing: '$($out.Trim())'"
}

# --- 5. a clean config says nothing ----------------------------------------
Write-Host ""
Write-Host "--- a config with nothing wrong in it ---" -ForegroundColor Yellow
New-DataDir "clean"
$ns4 = "${NS}4"
Stop-Ns $ns4
Start-Sleep -Milliseconds 400
$out = (& $PSMUX -L $ns4 -f $cfgOk new-session -d -s d 2>&1 | Out-String)
Stop-Ns $ns4
if ($out -match 'config warning') {
    Write-Fail "a clean config produced a warning: '$($out.Trim())'"
} else {
    Write-Pass "a clean config prints nothing"
}

Write-Host ""
Write-Host "=== Results ===" -ForegroundColor Magenta
Write-Host "  Passed:  $script:TestsPassed" -ForegroundColor Green
Write-Host "  Failed:  $script:TestsFailed" -ForegroundColor $(if ($script:TestsFailed -gt 0) { 'Red' } else { 'Green' })
Write-Host "  Skipped: $script:TestsSkipped" -ForegroundColor Yellow
Exit-Test $(if ($script:TestsFailed -gt 0) { 1 } else { 0 })
