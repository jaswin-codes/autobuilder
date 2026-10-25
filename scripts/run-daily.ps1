# Daily autobuilder run: plans new inbox ideas, then builds the next stage of approved projects.
# Runs at most once per day unless -Force. Use -PlanOnly to skip building.
param(
    [switch]$Force,
    [switch]$PlanOnly
)

. (Join-Path $PSScriptRoot 'lib.ps1')
$cfg = Get-Config
New-Item -ItemType Directory -Force $ProjectsDir, $StateDir, $cfg.inboxDir, (Join-Path $LogsDir 'runs') | Out-Null

$today = Get-Date -Format 'yyyy-MM-dd'
$lastRunFile = Join-Path $StateDir 'last-run.txt'
if (-not $Force -and (Test-Path $lastRunFile) -and ((Get-Content $lastRunFile -Raw).Trim() -eq $today)) {
    Write-Host "Already ran today ($today). Use -Force to run again."
    exit 0
}
$lockFile = Join-Path $StateDir 'running.lock'
if (Test-Path $lockFile) {
    $age = (Get-Date) - (Get-Item $lockFile).LastWriteTime
    if ($age.TotalHours -lt 3) { Write-Host 'Another run is in progress.'; exit 0 }
}
Set-Content $lockFile $PID

$summary = @()
try {
    Write-Log "**Run started**"

    # 1. Turn new inbox ideas into proposed plans.
    $ideas = Get-ChildItem $cfg.inboxDir -File | Where-Object { $_.Extension -in '.md', '.txt' }
    foreach ($idea in $ideas) {
        $slug = Get-Slug $idea.BaseName
        $dir = Join-Path $ProjectsDir $slug
        $n = 2
        while (Test-Path $dir) { $dir = Join-Path $ProjectsDir "$slug-$n"; $n++ }
        $slug = Split-Path $dir -Leaf

        New-Item -ItemType Directory $dir | Out-Null
        Invoke-Git $dir @('init', '-b', 'main') | Out-Null
        Move-Item $idea.FullName (Join-Path $dir 'IDEA.md')

        $prompt = Get-Content (Join-Path $Root 'prompts\plan.md') -Raw -Encoding UTF8
        $r = Invoke-Claude $dir $prompt $cfg.planModel $cfg.planTimeoutMinutes
        [System.IO.File]::WriteAllText((Join-Path $LogsDir "runs\$today-$slug-plan.txt"), $r.Output, $Utf8)

        if (Test-Path (Get-PlanPath $dir)) {
            Invoke-Git $dir @('add', 'IDEA.md', 'PLAN.md') | Out-Null
            Invoke-Git $dir @('commit', '-m', 'docs(plan): add project idea and staged plan', '-m', 'Co-Authored-By: Claude <noreply@anthropic.com>') | Out-Null
            $total = @(Get-Stages $dir).Count
            Write-Log "Planned **$slug** ($total stages) - awaiting approval: ``.\ab.ps1 approve $slug``"
            $summary += "New plan: $slug ($total stages)"
        } else {
            Write-Log "Planning **$slug** failed (no PLAN.md). See logs\runs\$today-$slug-plan.txt"
            $summary += "Planning failed: $slug"
        }
    }

    # 2. Build one stage for each approved project, least recently worked first.
    if (-not $PlanOnly) {
        $queue = Get-Projects | Where-Object { $_.Status -eq 'approved' } | Sort-Object LastCommit | Select-Object -First $cfg.maxStagesPerDay
        foreach ($p in $queue) {
            if (-not $p.NextStage) {
                Set-PlanStatus $p.Dir 'done'
                Invoke-Git $p.Dir @('commit', '-am', 'docs(plan): mark project done') | Out-Null
                Write-Log "**$($p.Slug)** has no stages left - marked done"
                continue
            }
            $before = (Invoke-Git $p.Dir @('rev-parse', 'HEAD'))
            $prompt = (Get-Content (Join-Path $Root 'prompts\stage.md') -Raw -Encoding UTF8).Replace('{{STAGE}}', $p.NextStage)
            Write-Log "Building **$($p.Slug)**: $($p.NextStage)"
            $r = Invoke-Claude $p.Dir $prompt $cfg.buildModel $cfg.stageTimeoutMinutes
            [System.IO.File]::WriteAllText((Join-Path $LogsDir "runs\$today-$($p.Slug).txt"), $r.Output, $Utf8)

            $commits = @(Invoke-Git $p.Dir @('log', '--oneline', "$before..HEAD")).Count
            $dirty = @(Invoke-Git $p.Dir @('status', '--porcelain')).Count
            $result = ([regex]::Match($r.Output, 'RESULT:\s*(.+)')).Groups[1].Value.Trim()
            if (-not $result) { $result = if ($r.TimedOut) { "timed out after $($cfg.stageTimeoutMinutes) min" } else { "no result line (exit $($r.ExitCode))" } }

            $after = Get-Projects | Where-Object Slug -eq $p.Slug
            if ($after.Status -eq 'approved' -and -not $after.NextStage) {
                Set-PlanStatus $p.Dir 'done'
                Invoke-Git $p.Dir @('commit', '-am', 'docs(plan): mark project done') | Out-Null
                $after.Status = 'done'
            }
            $line = "**$($p.Slug)** [$($after.Done)/$($after.Total), $($after.Status)] $commits commit(s) - $result"
            if ($r.Cost) { $line += " (`$$([math]::Round($r.Cost, 2)))" }
            if ($dirty) { $line += " - WARNING: $dirty uncommitted file(s) left" }
            if ($r.Denials) { $line += " - denied: " + (($r.Denials | ForEach-Object { "``$_``" }) -join ', ') }
            Write-Log $line
            $summary += "$($p.Slug): $($after.Done)/$($after.Total) $($after.Status)"
        }
        if (-not $queue) { Write-Log 'No approved projects to build.' }
    }

    Set-Content $lastRunFile $today
    Write-Log "**Run finished**"
} finally {
    Remove-Item $lockFile -ErrorAction SilentlyContinue
}

if ($summary) { Show-Notification 'Autobuilder' ($summary -join "`n") }
