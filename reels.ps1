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
        return "Opened a $($state.site) login window. Reels are off while you log in. When you're done, close it and run /reels kill $($state.site)."
    }
    $status = if ($state.mode -eq 'off') { 'Reels off.' } else { "Reels on: $($state.mode) mode, $($state.site). They'll open with your next prompt." }
    "$status Options: /reels kill|pause|off|login youtube|instagram|tiktok"
}

$in = [Console]::In.ReadToEnd() | ConvertFrom-Json
switch ($Hook) {
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
    }
    'close' {
        if ($state.mode -eq 'kill') { Stop-ReelsBrowser }
        elseif ($state.mode -eq 'pause') { Set-Playing $false }
    }
}
