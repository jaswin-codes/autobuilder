# Autobuilder command line. Run `.\ab.ps1 help` for usage.
param(
    [Parameter(Position = 0)][string]$Command = 'status',
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Rest
)

. (Join-Path $PSScriptRoot 'scripts\lib.ps1')
$cfg = Get-Config

function Set-Status([string]$Name, [string]$Status, [string]$Message) {
    $p = Resolve-Project $Name
    Set-PlanStatus $p.Dir $Status
    Invoke-Git $p.Dir @('commit', '-am', $Message) | Out-Null
    Write-Host "$($p.Slug) -> $Status"
}

switch ($Command) {
    'idea' {
        # .\ab.ps1 idea "habit tracker cli" "a tiny CLI that ..."   (or just one quoted string)
        if (-not $Rest) { throw 'Usage: .\ab.ps1 idea "<title>" ["<description>"]' }
        New-Item -ItemType Directory -Force $cfg.inboxDir | Out-Null
        $title = $Rest[0]
        $body = if ($Rest.Count -gt 1) { ($Rest[1..($Rest.Count - 1)] -join ' ') } else { $title }
        $file = Join-Path $cfg.inboxDir ((Get-Slug $title) + '.md')
        [System.IO.File]::WriteAllText($file, "# $title`r`n`r`n$body`r`n", $Utf8)
        Write-Host "Saved to $file. It will be planned on the next run (or now: .\ab.ps1 plan)."
    }
    'plan' { & (Join-Path $PSScriptRoot 'scripts\run-daily.ps1') -Force -PlanOnly }
    'run' { & (Join-Path $PSScriptRoot 'scripts\run-daily.ps1') -Force }
    'show' {
        $p = Resolve-Project $Rest[0]
        Get-Content (Get-PlanPath $p.Dir) -Encoding UTF8
    }
    'approve' { Set-Status $Rest[0] 'approved' 'docs(plan): approve plan' }
    'pause' { Set-Status $Rest[0] 'paused' 'docs(plan): pause project' }
    'resume' { Set-Status $Rest[0] 'approved' 'docs(plan): resume project' }
    'status' {
        $rows = Get-Projects
        if (-not $rows) { Write-Host 'No projects yet. Add one: .\ab.ps1 idea "<title>" "<description>"' }
        else { $rows | Select-Object Slug, Status, @{ n = 'Progress'; e = { "$($_.Done)/$($_.Total)" } },
            @{ n = 'Last commit'; e = { if ($_.LastCommit) { [DateTimeOffset]::FromUnixTimeSeconds($_.LastCommit).LocalDateTime.ToString('ddd dd MMM HH:mm') } } },
            @{ n = 'Next'; e = { $_.NextStage } } | Format-Table -AutoSize -Wrap }
        $pending = @(Get-ChildItem $cfg.inboxDir -File -ErrorAction SilentlyContinue).Count
        if ($pending) { Write-Host "$pending idea(s) waiting in the inbox." }
    }
    'review' {
        # Shows what changed since your last review and runs each project's tests.
        # .\ab.ps1 review [project] [-mark]   (-mark records this point as reviewed)
        $mark = $Rest -contains '-mark'
        $name = $Rest | Where-Object { $_ -ne '-mark' } | Select-Object -First 1
        $list = if ($name) { @(Resolve-Project $name) } else { Get-Projects | Where-Object { $_.LastCommit } }
        $reviewDir = Join-Path $StateDir 'reviewed'
        New-Item -ItemType Directory -Force $reviewDir | Out-Null
        foreach ($p in $list) {
            $markFile = Join-Path $reviewDir $p.Slug
            $since = if (Test-Path $markFile) { (Get-Content $markFile -Raw).Trim() } else { $null }
            $range = if ($since) { "$since..HEAD" } else { 'HEAD' }
            Write-Host "`n=== $($p.Slug) [$($p.Status), $($p.Done)/$($p.Total)] ===" -ForegroundColor Cyan
            Invoke-Git $p.Dir @('log', '--oneline', '--reverse', $range) | ForEach-Object { Write-Host "  $_" }
            $test = Get-PlanField $p.Dir 'test_command'
            if ($test -and $p.Done -gt 0) {
                Write-Host "  running tests: $test"
                Push-Location $p.Dir
                try { cmd /c "$test 2>&1" | Select-Object -Last 5 | ForEach-Object { Write-Host "    $_" } } finally { Pop-Location }
                Write-Host "  tests: $(if ($LASTEXITCODE -eq 0) { 'PASS' } else { "FAIL (exit $LASTEXITCODE)" })" -ForegroundColor $(if ($LASTEXITCODE -eq 0) { 'Green' } else { 'Red' })
            }
            if ($mark) { Invoke-Git $p.Dir @('rev-parse', 'HEAD') | Set-Content $markFile }
        }
        if (-not $mark) { Write-Host "`nWhen happy: .\ab.ps1 review -mark, then push each project yourself." }
    }
    'log' {
        $file = Join-Path $LogsDir ((Get-Date -Format 'yyyy-MM-dd') + '.md')
        if ($Rest) { $file = Join-Path $LogsDir "$($Rest[0]).md" }
        if (Test-Path $file) { Get-Content $file -Encoding UTF8 } else { Write-Host "No log at $file" }
    }
    default {
        Write-Host @'
Autobuilder - small daily coding stages on your project ideas.

  .\ab.ps1 idea "<title>" "<description>"   add an idea to the inbox
  .\ab.ps1 plan                             plan inbox ideas now (no building)
  .\ab.ps1 show <project>                   print a project's plan
  .\ab.ps1 approve <project>                approve a plan so it gets built
  .\ab.ps1 pause|resume <project>           stop / restart daily work on a project
  .\ab.ps1 status                           overview of all projects
  .\ab.ps1 review [project] [-mark]         new commits since last review + run tests
  .\ab.ps1 log [yyyy-MM-dd]                 today's (or a given day's) run log
  .\ab.ps1 run                              force a full daily run now
'@
    }
}
