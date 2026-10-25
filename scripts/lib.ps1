# Shared helpers for the autobuilder scripts. Dot-source this file.

$Root = Split-Path -Parent $PSScriptRoot
$ProjectsDir = Join-Path $Root 'projects'
$LogsDir = Join-Path $Root 'logs'
$StateDir = Join-Path $Root 'state'
$Utf8 = New-Object System.Text.UTF8Encoding($false)

function Get-Config {
    $cfg = Get-Content (Join-Path $Root 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    # inboxDir may be absolute (e.g. a OneDrive folder your phone syncs to) or relative to the repo root.
    if (-not $cfg.PSObject.Properties['inboxDir'] -or -not $cfg.inboxDir) {
        $cfg | Add-Member -NotePropertyName inboxDir -NotePropertyValue 'inbox' -Force
    }
    if (-not [System.IO.Path]::IsPathRooted($cfg.inboxDir)) {
        $cfg.inboxDir = Join-Path $Root $cfg.inboxDir
    }
    return $cfg
}

function Write-Log([string]$Message) {
    New-Item -ItemType Directory -Force $LogsDir | Out-Null
    $file = Join-Path $LogsDir ((Get-Date -Format 'yyyy-MM-dd') + '.md')
    $line = '- `' + (Get-Date -Format 'HH:mm') + '` ' + $Message
    [System.IO.File]::AppendAllText($file, $line + "`r`n", $Utf8)
    Write-Host $line
}

function Get-Slug([string]$Name) {
    $s = ($Name.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
    if (-not $s) { $s = 'idea-' + (Get-Date -Format 'yyyyMMdd-HHmm') }
    if ($s.Length -gt 40) { $s = $s.Substring(0, 40).Trim('-') }
    return $s
}

# Runs git in a project folder and returns stdout lines; stderr is discarded.
function Invoke-Git([string]$Dir, [string[]]$GitArgs) {
    $out = & git -C $Dir @GitArgs 2>$null
    return $out
}

function Get-PlanPath([string]$Dir) { Join-Path $Dir 'PLAN.md' }

function Get-PlanField([string]$Dir, [string]$Field) {
    $plan = Get-PlanPath $Dir
    if (-not (Test-Path $plan)) { return $null }
    $text = [System.IO.File]::ReadAllText($plan, $Utf8)
    $m = [regex]::Match($text, "(?m)^${Field}:\s*(.+?)\s*$")
    if ($m.Success) { return $m.Groups[1].Value.Trim('"') }
    return $null
}

function Set-PlanStatus([string]$Dir, [string]$Status) {
    $plan = Get-PlanPath $Dir
    $text = [System.IO.File]::ReadAllText($plan, $Utf8)
    $text = [regex]::Replace($text, '(?m)^status:\s*.*$', "status: $Status", 1)
    [System.IO.File]::WriteAllText($plan, $text, $Utf8)
}

function Get-Stages([string]$Dir) {
    $plan = Get-PlanPath $Dir
    if (-not (Test-Path $plan)) { return @() }
    $lines = [System.IO.File]::ReadAllLines($plan, $Utf8)
    $stages = @()
    foreach ($l in $lines) {
        $m = [regex]::Match($l, '^\s*-\s*\[( |x|X)\]\s*(Stage\s*\d+.*)$')
        if ($m.Success) {
            $stages += [pscustomobject]@{ Done = ($m.Groups[1].Value -ne ' '); Text = $m.Groups[2].Value.Trim() }
        }
    }
    return $stages
}

function Get-Projects {
    if (-not (Test-Path $ProjectsDir)) { return @() }
    Get-ChildItem $ProjectsDir -Directory | ForEach-Object {
        $stages = @(Get-Stages $_.FullName)
        $last = Invoke-Git $_.FullName @('log', '-1', '--format=%ct')
        [pscustomobject]@{
            Slug       = $_.Name
            Dir        = $_.FullName
            Status     = (Get-PlanField $_.FullName 'status')
            Title      = (Get-PlanField $_.FullName 'title')
            Done       = @($stages | Where-Object Done).Count
            Total      = $stages.Count
            NextStage  = ($stages | Where-Object { -not $_.Done } | Select-Object -First 1).Text
            LastCommit = if ($last) { [int64]$last } else { 0 }
        }
    }
}

function Resolve-Project([string]$Name) {
    $p = Get-Projects | Where-Object { $_.Slug -eq $Name }
    if (-not $p) { $p = Get-Projects | Where-Object { $_.Slug -like "*$Name*" } }
    if (@($p).Count -ne 1) { throw "No single project matches '$Name'. Run: .\ab.ps1 status" }
    return $p
}

# Runs `claude -p` headless in $Dir with the prompt on stdin. Kills it after $TimeoutMinutes.
# Returns @{ ExitCode; Output; TimedOut }.
function Invoke-Claude([string]$Dir, [string]$Prompt, [string]$Model, [int]$TimeoutMinutes) {
    $cfg = Get-Config
    $q = { param($s) '"' + ($s -replace '"', '\"') + '"' }
    $argList = @('-p', '--model', $Model, '--permission-mode', 'dontAsk', '--output-format', 'json')
    $argList += '--allowedTools'
    $argList += ($cfg.allowedTools | ForEach-Object { & $q $_ })
    $argList += '--disallowedTools'
    $argList += ($cfg.disallowedTools | ForEach-Object { & $q $_ })

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $cfg.claudePath
    $psi.Arguments = $argList -join ' '
    $psi.WorkingDirectory = $Dir
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $Utf8
    $psi.StandardErrorEncoding = $Utf8

    $proc = [System.Diagnostics.Process]::Start($psi)
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    $bytes = $Utf8.GetBytes($Prompt)
    $proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    $proc.StandardInput.Close()

    $timedOut = -not $proc.WaitForExit($TimeoutMinutes * 60 * 1000)
    if ($timedOut) {
        & taskkill.exe /T /F /PID $proc.Id 2>$null | Out-Null
        $proc.WaitForExit(10000) | Out-Null
    }
    # The JSON result carries the final reply, the cost and every tool call the allowlist denied.
    $out = $outTask.Result
    $denials = @()
    $cost = $null
    try {
        $json = $out | ConvertFrom-Json
        $out = $json.result
        $cost = $json.total_cost_usd
        $denials = @($json.permission_denials | ForEach-Object {
            $i = $_.tool_input
            "$($_.tool_name): $(if ($i.command) { $i.command } elseif ($i.file_path) { $i.file_path } else { $i | ConvertTo-Json -Compress })"
        })
    } catch { }
    if ($denials) { $out += "`r`n`r`n[denied tool calls]`r`n" + ($denials -join "`r`n") }
    if ($errTask.Result) { $out += "`r`n`r`n[stderr]`r`n" + $errTask.Result }
    return [pscustomobject]@{ ExitCode = $(if ($timedOut) { -1 } else { $proc.ExitCode }); Output = $out; TimedOut = $timedOut; Denials = $denials; Cost = $cost }
}

function Show-Notification([string]$Title, [string]$Text) {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $n = New-Object System.Windows.Forms.NotifyIcon
        $n.Icon = [System.Drawing.SystemIcons]::Information
        $n.Visible = $true
        $n.ShowBalloonTip(10000, $Title, $Text, 'Info')
        Start-Sleep -Seconds 10
        $n.Dispose()
    } catch { }
}
