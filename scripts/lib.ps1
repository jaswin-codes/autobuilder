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
    # Docker sandbox for the build stage; older config.json files without a `sandbox` block get these defaults.
    if (-not $cfg.PSObject.Properties['sandbox']) { $cfg | Add-Member -NotePropertyName sandbox -NotePropertyValue ([pscustomobject]@{}) }
    $defaults = [ordered]@{ image = 'autobuilder-sandbox:1'; cpus = 2; memory = '2g'; pidsLimit = 256; stepTimeoutMinutes = 15 }
    foreach ($k in $defaults.Keys) {
        if (-not $cfg.sandbox.PSObject.Properties[$k]) { $cfg.sandbox | Add-Member -NotePropertyName $k -NotePropertyValue $defaults[$k] }
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

# Git settings that stop a project's own .git/config or hooks from running programs on the host.
# Used for the runner's git calls and passed to the build stage's environment.
$GitSafeConfig = [ordered]@{ 'core.hooksPath' = (Join-Path $StateDir 'no-git-hooks'); 'core.fsmonitor' = 'false' }

# Runs git in a project folder and returns stdout lines; stderr is discarded.
function Invoke-Git([string]$Dir, [string[]]$GitArgs) {
    $safe = foreach ($k in $GitSafeConfig.Keys) { '-c'; "$k=$($GitSafeConfig[$k])" }
    $out = & git @safe -C $Dir @GitArgs 2>$null
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

# PLAN.md is written by the model, so only run its test_command if it is a plain test runner
# with simple arguments (no &, |, ;, quotes or redirects).
function Test-SafeTestCommand([string]$Command) {
    return $Command -match '^(npm test|npm run [\w:-]+|pytest|python3? -m pytest|py -m pytest|dotnet test|cargo test|go test|mvn test|gradle test|make test)( [\w./=:-]+)*$'
}

# --- Docker sandbox ---------------------------------------------------------------------------
# Every code-running build command goes through `sandbox <command>` (scripts/bin/sandbox), which runs
# it in a throwaway container: only the project folder is mounted, no network, non-root, capped CPU,
# memory, processes and time. There is no host fallback: if Docker is missing, nothing runs.

# Only these dependency installs get network access; every other step runs with --network none.
$SandboxNetworkCommands = '^(npm (ci|install) --ignore-scripts( [^\s-]\S*)*|pip install -r requirements\.txt)$'

# Bash rules that would let the build stage run code on the host instead of in the sandbox.
$HostExecRule = '^Bash\((python3?|py|node|npm|npx|pip3?|pytest|dotnet|javac?|mvn|gradle|cargo|go|gcc|g\+\+|make|pio|find|xargs|env|sh|bash|cmd|powershell|pwsh|docker)[ :)]'

function Get-DockerExe { if ($env:AB_DOCKER) { $env:AB_DOCKER } else { 'docker' } }

# Quotes one argument for a Windows command line (CommandLineToArgvW rules).
function ConvertTo-NativeArg([string]$Arg) {
    if ($Arg -and $Arg -notmatch '[\s"]') { return $Arg }
    return '"' + (($Arg -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
}

# Runs docker with $DockerArgs. Output goes to this process's console unless -Quiet.
# Returns the exit code, or $null if it was still running after $TimeoutSeconds.
function Invoke-Docker([string[]]$DockerArgs, [int]$TimeoutSeconds = 0, [switch]$Quiet) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Get-DockerExe
    $psi.Arguments = ($DockerArgs | ForEach-Object { ConvertTo-NativeArg $_ }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = [bool]$Quiet
    $psi.RedirectStandardError = [bool]$Quiet
    $proc = [System.Diagnostics.Process]::Start($psi)
    if ($Quiet) { $null = $proc.StandardOutput.ReadToEndAsync(); $null = $proc.StandardError.ReadToEndAsync() }
    if ($TimeoutSeconds -gt 0 -and -not $proc.WaitForExit($TimeoutSeconds * 1000)) { return $null }
    $proc.WaitForExit()
    return $proc.ExitCode
}

# Throws a clear error unless Docker is installed, running and has the sandbox image (built on first use).
function Assert-SandboxReady {
    $cfg = Get-Config
    $docker = Get-DockerExe
    if (-not (Get-Command $docker -ErrorAction SilentlyContinue)) {
        throw "Docker was not found ('$docker'). The build stage only runs code inside a Docker container and never on this machine directly. Install Docker Desktop (https://www.docker.com/products/docker-desktop/), start it, and run again."
    }
    if ((Invoke-Docker @('info', '--format', '{{.ServerVersion}}') 120 -Quiet) -ne 0) {
        throw "Docker is installed but not running. Start Docker Desktop (Linux containers) and run again; nothing was built."
    }
    if ((Invoke-Docker @('image', 'inspect', $cfg.sandbox.image) 60 -Quiet) -ne 0) {
        Write-Host "Building sandbox image $($cfg.sandbox.image) (first run only)..."
        $context = Join-Path $Root 'docker'
        $code = Invoke-Docker @('build', '-t', $cfg.sandbox.image, '-f', (Join-Path $context 'sandbox.Dockerfile'), $context) 1800 -Quiet
        if ($code -ne 0) { throw "Could not build the sandbox image $($cfg.sandbox.image) from docker\sandbox.Dockerfile (exit $code)." }
    }
}

# The `docker run` arguments for one sandboxed command in project folder $Dir.
function Get-SandboxDockerArgs([string]$Dir, [string[]]$Command, [string]$Name) {
    $sb = (Get-Config).sandbox
    $network = if (($Command -join ' ') -match $SandboxNetworkCommands) { 'bridge' } else { 'none' }
    $dockerArgs = @('run', '--rm', '--init', '--name', $Name, '--label', 'autobuilder.sandbox=1',
        '--network', $network,
        '--user', '1000:1000', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges',
        '--read-only', '--tmpfs', '/tmp:rw,exec,size=1g',
        '--cpus', "$($sb.cpus)", '--memory', "$($sb.memory)", '--memory-swap', "$($sb.memory)", '--pids-limit', "$($sb.pidsLimit)",
        '--mount', "type=bind,source=$Dir,target=/work", '--workdir', '/work',
        '-e', 'HOME=/tmp', '-e', 'npm_config_cache=/tmp/.npm',
        '-e', 'PIP_USER=1', '-e', 'PYTHONUSERBASE=/work/.pydeps',
        '-e', 'PATH=/work/.pydeps/bin:/work/node_modules/.bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
        $sb.image)
    # .git is read-only inside: code in the container must not plant hooks or config for the host's git.
    $git = Join-Path $Dir '.git'
    if (Test-Path -LiteralPath $git) {
        $dockerArgs = $dockerArgs[0..($dockerArgs.Count - 2)] + @('--mount', "type=bind,source=$git,target=/work/.git,readonly", $sb.image)
    }
    return $dockerArgs + $Command
}

# Runs $Command (program + arguments, no shell) in the sandbox with $Dir mounted at /work.
# Returns the command's exit code (124 if it hit sandbox.stepTimeoutMinutes).
function Invoke-Sandbox([string]$Dir, [string[]]$Command) {
    if (-not $Command) { throw 'usage: sandbox <command> [args...]   e.g. sandbox python -m pytest' }
    if (-not $Dir) { throw 'AB_SANDBOX_DIR is not set: sandbox only runs from an autobuilder build stage or review.' }
    $full = [System.IO.Path]::GetFullPath($Dir).TrimEnd('\', '/')
    $projects = [System.IO.Path]::GetFullPath($ProjectsDir).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($projects, [System.StringComparison]::OrdinalIgnoreCase) -or $full.Contains(',') -or
        -not (Test-Path -LiteralPath $full -PathType Container)) {
        throw "refusing to mount '$full': only a project folder under $ProjectsDir can be mounted."
    }
    $cfg = Get-Config
    $name = 'ab-sandbox-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
    $code = Invoke-Docker (Get-SandboxDockerArgs $full $Command $name) ([int]$cfg.sandbox.stepTimeoutMinutes * 60)
    if ($null -eq $code) {
        Invoke-Docker @('rm', '-f', $name) 60 -Quiet | Out-Null
        [Console]::Error.WriteLine("sandbox: stopped after $($cfg.sandbox.stepTimeoutMinutes) min (sandbox.stepTimeoutMinutes)")
        return 124
    }
    return $code
}

# Removes sandbox containers left running, e.g. when a stage was killed on timeout.
function Remove-SandboxContainers {
    $ids = @(& (Get-DockerExe) ps -aq --filter 'label=autobuilder.sandbox=1' 2>$null)
    if ($ids) { Invoke-Docker (@('rm', '-f') + $ids) 60 -Quiet | Out-Null }
}

# Process start info for `claude -p` headless in $Dir.
# $Stage 'plan' runs on unapproved inbox text, so it only gets planAllowedTools (no shell);
# 'build' runs on an approved plan and gets allowedTools, with code execution only via `sandbox`.
function New-ClaudeStartInfo([string]$Dir, [string]$Model, [ValidateSet('plan', 'build')][string]$Stage = 'build') {
    $cfg = Get-Config
    $q = { param($s) '"' + ($s -replace '"', '\"') + '"' }
    $tools = if ($Stage -eq 'plan') { $cfg.planAllowedTools } else { $cfg.allowedTools }
    if (-not $tools) { throw "config.json has no tool list for the $Stage stage" }
    if ($Stage -eq 'build') {
        $hostExec = @($tools | Where-Object { $_ -match $HostExecRule })
        if ($hostExec) {
            throw "config.json allowedTools would let the build stage run code on the host: $($hostExec -join ', '). Remove these; build commands run as 'sandbox <command>' (Bash(sandbox:*))."
        }
    }
    # --restricted ignores ~/.claude/settings.json (whose broad allow rules would otherwise apply to this
    # unattended run), confines file tools to the project folder and drops code-running tools unless
    # --tools lists them. --strict-mcp-config keeps user MCP servers out.
    $toolSet = if ($Stage -eq 'plan') { 'Read,Write,Glob,Grep' } else { 'Read,Edit,Write,Glob,Grep,Bash' }
    $argList = @('-p', '--model', $Model, '--permission-mode', 'dontAsk', '--output-format', 'json',
        '--restricted', '--strict-mcp-config', '--tools', $toolSet)
    $argList += '--allowedTools'
    $argList += ($tools | ForEach-Object { & $q $_ })
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
    if ($Stage -eq 'build') {
        # Puts `sandbox` on the Bash tool's PATH and tells it which folder to mount.
        $bin = Join-Path (Join-Path $Root 'scripts') 'bin'
        $psi.EnvironmentVariables['PATH'] = $bin + [System.IO.Path]::PathSeparator + $env:PATH
        $psi.EnvironmentVariables['AB_SANDBOX_DIR'] = $Dir
        # Same as Invoke-Git: the agent's own git calls ignore hooks and fsmonitor set in the project.
        $i = 0
        foreach ($k in $GitSafeConfig.Keys) {
            $psi.EnvironmentVariables["GIT_CONFIG_KEY_$i"] = $k
            $psi.EnvironmentVariables["GIT_CONFIG_VALUE_$i"] = $GitSafeConfig[$k]
            $i++
        }
        $psi.EnvironmentVariables['GIT_CONFIG_COUNT'] = "$i"
    }
    return $psi
}

# Runs `claude -p` headless in $Dir with the prompt on stdin. Kills it after $TimeoutMinutes.
# Returns @{ ExitCode; Output; TimedOut }.
function Invoke-Claude([string]$Dir, [string]$Prompt, [string]$Model, [int]$TimeoutMinutes, [ValidateSet('plan', 'build')][string]$Stage = 'build') {
    $psi = New-ClaudeStartInfo $Dir $Model $Stage
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
