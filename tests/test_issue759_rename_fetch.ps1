# Issue #759: a rename overlay opens on a copy of the last frame's name, so a
# rename made anywhere else leaves it editing a name the session or window no
# longer has.
#
# tmux reaches both renames through `command-prompt`: `,` is
# `command-prompt -I'#W' { rename-window -- '%%' }` and `$` is
# `command-prompt -I'#S' { rename-session -- '%%' }` (key-bindings.c:368 and
# :361, tag 3.7c). `-I` puts the current name in, the status prompt draws a
# cursor, and prompt.c gives it the whole line editor. psmux draws its own
# overlay instead, which until this change started empty, showed no cursor and
# took only Backspace.
#
# GROUND TRUTH: the text of the attached client's console (tests\conread.cs)
# for what the overlay holds, and its console cursor
# (GetConsoleScreenBufferInfo through tests\cursorprobe.cs) for where typing
# will land. Keys go in through tests\injector.cs.
#
# Set PSMUX_TEST_BIN to test a binary that is not on PATH.

$ErrorActionPreference = "Continue"
$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$psmuxDir = if ($env:PSMUX_DATA_DIR) { $env:PSMUX_DATA_DIR } else { "$env:USERPROFILE\.psmux" }
$script:TestsPassed = 0; $script:TestsFailed = 0
$script:Opened = @()

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Info($msg) { Write-Host "  [INFO] $msg" -ForegroundColor DarkCyan }
function Write-Head($msg) { Write-Host "`n--- $msg ---" -ForegroundColor Yellow }
function Check($ok, $pass, $fail) { if ($ok) { Write-Pass $pass } else { Write-Fail $fail } }

Write-Host "binary: $PSMUX" -ForegroundColor Cyan

$env:PSMUX_SESSION_NAME = $null
$env:PSMUX_SESSION      = $null
$env:PSMUX_PANE         = $null
$env:TMUX               = $null
$env:TMUX_PANE          = $null
# NO_COLOR makes the client draw without colour, and then no highlight can be
# seen in the console attributes at all.
Remove-Item Env:NO_COLOR -EA SilentlyContinue

$NS   = "rp-" + [guid]::NewGuid().ToString('N').Substring(0, 6)
$SESS = "rp"
$TMP  = Join-Path ([System.IO.Path]::GetTempPath()) ("psmux_cr_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $TMP | Out-Null

function P { & $PSMUX -L $NS @args 2>&1 }
function D($f) { ((P display-message -t $SESS -p $f) -join '').Trim() }

$csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe"
if (-not (Test-Path $csc)) {
    $csc = Get-ChildItem "C:\Windows\Microsoft.NET\Framework64\v4*\csc.exe" -EA SilentlyContinue |
           Select-Object -First 1 -ExpandProperty FullName
}
foreach ($tool in "conread", "injector", "cursorprobe") {
    $exe = Join-Path $TMP "$tool.exe"
    if ($csc -and (Test-Path $csc)) {
        & $csc /nologo /optimize /out:$exe (Join-Path $PSScriptRoot "$tool.cs") 2>&1 | Out-Null
    }
    if (-not (Test-Path $exe)) {
        Write-Fail "could not build tests\$tool.cs (csc.exe unavailable)"
        Remove-Item $TMP -Recurse -Force -EA SilentlyContinue
        exit 1
    }
}
$RD  = Join-Path $TMP "conread.exe"
$INJ = Join-Path $TMP "injector.exe"
$CUR = Join-Path $TMP "cursorprobe.exe"

function Stop-Opened {
    foreach ($id in $script:Opened) { try { Stop-Process -Id $id -Force -EA SilentlyContinue } catch {} }
    $script:Opened = @()
}

function Kill-Rig {
    & $PSMUX -L $NS kill-server 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800
    Stop-Opened
    Get-ChildItem "$psmuxDir\${NS}__*" -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue
}

$CONF = Join-Path $TMP "cr.conf"
$POWERSHELL = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
@(
    "set -g default-shell $POWERSHELL",
    "set -g mode-keys vi",
    "set -g history-limit 2000",
    "set -g status-left ''"
) | Set-Content -Path $CONF -Encoding ASCII

function Start-Attached {
    $p = Start-Process -FilePath $PSMUX `
        -ArgumentList "-f",$CONF,"-L",$NS,"new-session","-s",$SESS,"-x","100","-y","30" -PassThru
    $script:Opened += $p.Id
    $portFile = Join-Path $psmuxDir "${NS}__${SESS}.port"
    for ($i = 0; $i -lt 80; $i++) {
        Start-Sleep -Milliseconds 250
        if (Test-Path $portFile) {
            $port = (Get-Content $portFile -Raw).Trim()
            try {
                $t = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port); $t.Close()
                Start-Sleep -Milliseconds 2500
                return $p
            } catch {}
        }
    }
    return $null
}

function Inj($keys) { & $INJ $script:cpid $keys | Out-Null; Start-Sleep -Milliseconds 450 }

function Screen([switch]$Attr) {
    $o = Join-Path $TMP "screen.txt"
    $a = @("$script:cpid"); if ($Attr) { $a += "-a" }
    Start-Process -FilePath $RD -ArgumentList $a -Wait -WindowStyle Hidden -RedirectStandardOutput $o | Out-Null
    if (Test-Path $o) { return @(Get-Content $o) }
    return @()
}

# The overlay row: the one that reads "name: ...". Returns the row, the column
# the typed text starts at, and the line.
function Find-Name($screen) {
    for ($i = 0; $i -lt $screen.Count; $i++) {
        $line = [string]$screen[$i]
        $at = $line.IndexOf("name: ")
        if ($at -ge 0) { return @{ Row = $i; After = $at + 6; Line = $line } }
    }
    return $null
}

# What the overlay HOLDS, exactly. The box border comes back from the screen
# reader as non ASCII, so it is dropped before the trim. Compared with -eq, not
# -match: `name: rp` matches `name: rp-4f2a1c__rp` too, and that is the bug
# issue #759 is about.
function Name-Value($nm) {
    if (-not $nm) { return $null }
    $tail = [string]$nm.Line
    if ($nm.After -ge $tail.Length) { return "" }
    return ($tail.Substring($nm.After) -replace '[^ -~]', ' ').Trim()
}

function Overlay-Title($screen) {
    foreach ($l in $screen) {
        $s = [string]$l
        if ($s -match 'rename (session|window)') { return $Matches[0] }
    }
    return ""
}

function Cursor {
    $o = Join-Path $TMP ("cur_" + [guid]::NewGuid().ToString('N').Substring(0, 6) + ".json")
    Start-Process -FilePath $CUR -ArgumentList "$($script:cpid)", "`"$o`"", "3", "60", "1" `
        -Wait -WindowStyle Hidden | Out-Null
    if (-not (Test-Path $o)) { return $null }
    $j = Get-Content $o -Raw -Encoding UTF8 | ConvertFrom-Json
    Remove-Item $o -Force -EA SilentlyContinue
    return $j
}

# ── Rig ──

Kill-Rig
$proc = Start-Attached
if (-not $proc) {
    Write-Fail "the attached client never came up"
    Kill-Rig
    Remove-Item $TMP -Recurse -Force -EA SilentlyContinue
    exit 1
}
$script:cpid = $proc.Id
Start-Sleep -Milliseconds 800
& $PSMUX -L $NS rename-window -t $SESS "alpha" 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Write-Info "the window is called [$((( & $PSMUX -L $NS list-windows -a -F '#{window_name}') -join '').Trim())]"

# ── 1. a rename-session from the CLI reaches the overlay ──
#
# The client draws the session name from the `session_name` in the last frame
# it parsed. The status line re-reads that on every repaint, so it catches up on
# its own; an overlay keeps the copy it took when it opened. The gap between the
# two is visible on one screen: the status line carries the new name while the
# overlay still offers the old one to edit.
#
# How wide the gap is depends on when the next frame lands, and after a
# rename-session that is not bounded: the server answers dump-state with "NC"
# because RenameWindow sets meta_dirty and RenameSession does not, and
# combined_data_version has no term for the name. On a busy pane the pane
# counters move it along within about a second. On an idle pane, as here, no
# frame comes at all, which is what makes this check deterministic.

Write-Head "1. the overlay opens on the name the CLI set"
& $PSMUX -L $NS rename-session -t $SESS "sesK" 2>&1 | Out-Null
$now = ((P list-sessions -F '#{session_name}') -join ' ').Trim()
Check ($now -eq 'sesK') "the CLI renamed the session to sesK" "list-sessions reads [$now]"

Inj "^b{SLEEP:300}`$"
$pr = Screen; $nm = Find-Name $pr
Write-Info "the overlay reads [$(Name-Value $nm)]"
Check ((Name-Value $nm) -eq 'sesK') "the overlay opens on sesK" `
    "it reads [$(Name-Value $nm)], the name before the CLI rename"
Check ((Overlay-Title $pr) -eq "rename session") "the title is rename session" `
    "the title reads [$(Overlay-Title $pr)]"
Inj "{ESC}"

# ── 2. and the same for a window ──

Write-Head "2. the overlay opens on the window name the CLI set"
& $PSMUX -L $NS rename-window -t sesK "winK" 2>&1 | Out-Null
$now = ((P list-windows -a -F '#{window_name}') -join ' ').Trim()
Check ($now -eq 'winK') "the CLI renamed the window to winK" "list-windows reads [$now]"

Inj "^b{SLEEP:300},"
$pr = Screen; $nm = Find-Name $pr
Write-Info "the overlay reads [$(Name-Value $nm)]"
Check ((Name-Value $nm) -eq 'winK') "the overlay opens on winK" `
    "it reads [$(Name-Value $nm)], the name before the CLI rename"
Inj "{ESC}"

# ── 3. editing the fetched name renames the right thing ──

# Typing on the end of what the overlay opened with, so the name that lands is
# the fetched one plus the keystroke. If the overlay had opened on the stale
# copy the session would come out `rpZ`, not `sesKZ`.

Write-Head "3. the name taken from the server is what gets edited"
Inj "^b{SLEEP:300}`$"
Inj "Z"
$pr = Screen; $nm = Find-Name $pr
Check ((Name-Value $nm) -eq 'sesKZ') "the field reads sesKZ" "it reads [$(Name-Value $nm)]"
Inj "{ENTER}"
Start-Sleep -Milliseconds 1200
$now = ((P list-sessions -F '#{session_name}') -join ' ').Trim()
Check ($now -eq 'sesKZ') "the session is sesKZ" "list-sessions reads [$now]"

# ── 4. the fall back still works when the server cannot answer ──
#
# Nothing simulates a dead server here, which would take the session with it.
# What is checked instead is that the overlay still opens at all and still
# holds a name, so a slow answer cannot leave it empty.

Write-Head "4. the overlay always holds a name"
Inj "^b{SLEEP:300}`$"
$pr = Screen; $nm = Find-Name $pr
Check ($nm -and (Name-Value $nm).Length -gt 0) "the overlay is not empty" "it reads []"
Inj "{ESC}"

# ── Cleanup ──

Kill-Rig
Remove-Item $TMP -Recurse -Force -EA SilentlyContinue

Write-Host "`n=== Results: $($script:TestsPassed) passed, $($script:TestsFailed) failed, $($script:Skipped) skipped ===" `
    -ForegroundColor $(if ($script:TestsFailed) { 'Red' } else { 'Green' })
exit $script:TestsFailed
