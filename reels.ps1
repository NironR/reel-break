param([string]$Hook)
# Hook entry point: open = prompt sent (or /reels toggle), close = Claude finished or needs you.
$ErrorActionPreference = 'SilentlyContinue'

# Fixed path, not CLAUDE_PLUGIN_DATA: that changes with how the plugin was loaded, which would split your login across sessions.
$data = "$env:USERPROFILE\.claude\reel-break"
$profileDir = Join-Path $data 'edge-profile'
$stateFile = Join-Path $data 'state.json'
$sites = @{
    youtube   = 'https://www.youtube.com/shorts'
    instagram = 'https://www.instagram.com/reels/'
    tiktok    = 'https://www.tiktok.com/foryou'
}
$logins = @{
    youtube   = 'https://accounts.google.com/ServiceLogin?service=youtube&continue=https%3A%2F%2Fwww.youtube.com%2F'
    instagram = 'https://www.instagram.com/accounts/login/'
    tiktok    = 'https://www.tiktok.com/login'
}
$state = Get-Content $stateFile -Raw | ConvertFrom-Json
if (-not $state) { $state = [pscustomobject]@{ mode = 'off'; site = 'youtube' } }

# The reels window runs in its own Edge profile so we can find and kill it without touching your normal browser.
function Get-ReelsBrowser {
    Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" | Where-Object { $_.CommandLine -like "*$profileDir*" }
}

function Stop-ReelsBrowser {
    Get-ReelsBrowser | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
}

# Pause/resume via the DevTools protocol. Only resumes the videos we paused, so preloaded reels stay quiet.
function Set-Playing([bool]$play) {
    try {
        $port = (Get-Content (Join-Path $profileDir 'DevToolsActivePort'))[0]
        $page = (Invoke-RestMethod "http://127.0.0.1:$port/json") | Where-Object type -eq 'page' | Select-Object -First 1
        $js = if ($play) {
            "document.querySelectorAll('video[data-rb]').forEach(v=>{delete v.dataset.rb;v.play()})"
        } else {
            "document.querySelectorAll('video').forEach(v=>{if(!v.paused){v.dataset.rb=1;v.pause()}})"
        }
        $msg = @{ id = 1; method = 'Runtime.evaluate'; params = @{ expression = $js } } | ConvertTo-Json -Compress
        $none = [Threading.CancellationToken]::None
        $ws = New-Object Net.WebSockets.ClientWebSocket
        $ws.ConnectAsync([uri]$page.webSocketDebuggerUrl, $none).Wait(3000) | Out-Null
        $ws.SendAsync([ArraySegment[byte]][Text.Encoding]::UTF8.GetBytes($msg), 'Text', $true, $none).Wait(3000) | Out-Null
        $ws.ReceiveAsync([ArraySegment[byte]](New-Object byte[] 4096), $none).Wait(3000) | Out-Null
        $ws.Dispose()
    } catch {}
}

# Windows won't let a background process (like this hook) pull a window to the front, so new windows open
# behind Claude. Attaching to the foreground window's input thread lifts that restriction for one call.
function Show-ReelsWindow {
    Add-Type -Namespace RB -Name W -MemberDefinition @'
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, IntPtr pid);
[DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
[DllImport("user32.dll")] public static extern bool AttachThreadInput(uint from, uint to, bool attach);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int cmd);
[DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
'@
    $h = [IntPtr]::Zero
    foreach ($i in 1..40) {
        $browser = Get-ReelsBrowser | Where-Object { $_.CommandLine -notlike '*--type=*' } | Select-Object -First 1
        if ($browser) { $h = (Get-Process -Id $browser.ProcessId).MainWindowHandle }
        if ($h -ne [IntPtr]::Zero) { break }
        Start-Sleep -Milliseconds 250
    }
    if ($h -eq [IntPtr]::Zero) { return }
    $fg = [RB.W]::GetWindowThreadProcessId([RB.W]::GetForegroundWindow(), [IntPtr]::Zero)
    $me = [RB.W]::GetCurrentThreadId()
    [RB.W]::AttachThreadInput($me, $fg, $true) | Out-Null
    if ([RB.W]::IsIconic($h)) { [RB.W]::ShowWindow($h, 9) | Out-Null }
    [RB.W]::BringWindowToTop($h) | Out-Null
    [RB.W]::SetForegroundWindow($h) | Out-Null
    [RB.W]::AttachThreadInput($me, $fg, $false) | Out-Null
}

# Waiting for the window takes a few seconds, so do it in a detached process instead of delaying your prompt.
function Start-Front {
    Start-Process powershell -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" front"
}

function Set-Mode([string[]]$words) {
    $login = $false
    foreach ($a in $words) {
        $a = $a.ToLower()
        if ($a -eq 'login') { $login = $true }
        elseif ($a -in 'kill', 'pause', 'off') { $state.mode = $a }
        elseif ($sites.ContainsKey($a)) { $state.site = $a }
    }
    # Login turns reels off so no hook closes the window mid-login.
    if ($login) { $state.mode = 'off' }
    if ($state.mode -eq 'off') { Stop-ReelsBrowser }
    New-Item -ItemType Directory -Force $data | Out-Null
    $state | ConvertTo-Json | Set-Content $stateFile
    if ($login) {
        # A normal window (address bar, no DevTools port): Google refuses sign-in when the port is open.
        Start-Sleep 1
        Start-Process msedge "--user-data-dir=`"$profileDir`" --no-first-run $($logins[$state.site])"
        Start-Front
        return "Opened a $($state.site) login window. Reels are off while you log in. When you're done, close it and run /reels kill $($state.site)."
    }
    $status = if ($state.mode -eq 'off') { 'Reels off.' } else { "Reels on: $($state.mode) mode, $($state.site). They'll open with your next prompt." }
    "$status Options: /reels kill|pause|off|login youtube|instagram|tiktok"
}

# The detached 'front' helper has no hook input on stdin; reading it would hang.
if ($Hook -ne 'front') { $in = [Console]::In.ReadToEnd() | ConvertFrom-Json }
switch ($Hook) {
    'front' { Show-ReelsWindow }
    'open' {
        # /reels isn't blocked (a block always shows a "blocked" card), so it arrives here: expanded in the app
        # (commands/reels.md writes "reels-args: <words>"), raw in headless runs. Stdout becomes context for Claude's one-line reply.
        $words = if ($in.prompt -match 'reels-args:([^\r\n]*)') { $Matches[1] } elseif ($in.prompt -match '^\s*/(reel-break:)?reels\b(.*)') { $Matches[2] }
        if ($null -ne $words) { "Reel Break status: " + (Set-Mode ($words -split '\s+' | Where-Object { $_ })); exit 0 }
        if ($state.mode -eq 'off') { exit 0 }
        if (Get-ReelsBrowser) {
            if ($state.mode -eq 'pause') { Set-Playing $true }
        } else {
            # The DevTools port lets any local program read this window's cookies, so only pause mode (which needs it) opens it.
            $debug = if ($state.mode -eq 'pause') { '--remote-debugging-port=0' } else { '' }
            Start-Process msedge "--app=$($sites[$state.site]) --user-data-dir=`"$profileDir`" $debug --no-first-run --hide-crash-restore-bubble"
        }
        Start-Front
    }
    'close' {
        if ($state.mode -eq 'kill') { Stop-ReelsBrowser }
        elseif ($state.mode -eq 'pause') { Set-Playing $false }
    }
}
