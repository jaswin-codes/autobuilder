# Pester 5 tests for the Docker sandbox of the build stage. Docker itself is mocked or faked,
# so these run without Docker installed:  Invoke-Pester -Path tests
BeforeAll {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path (Join-Path $RepoRoot 'scripts') 'lib.ps1')
    $HostExe = (Get-Process -Id $PID).Path
    $SavedDocker = $env:AB_DOCKER
    # A throwaway project folder under projects/ (git-ignored), the only place the sandbox mounts.
    $Proj = Join-Path $ProjectsDir ('pester-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force (Join-Path $Proj '.git') | Out-Null
}

AfterAll {
    Remove-Item -Recurse -Force $Proj -ErrorAction SilentlyContinue
    $env:AB_DOCKER = $SavedDocker
}

Describe 'build commands run in the container' {
    It 'runs the command through docker run with the isolation flags' {
        Mock Invoke-Docker { 0 }
        Invoke-Sandbox $Proj @('python', '-m', 'pytest') | Should -Be 0
        Should -Invoke Invoke-Docker -Times 1 -Exactly -ParameterFilter {
            $DockerArgs[0] -eq 'run' -and ($DockerArgs[-3..-1] -join ' ') -eq 'python -m pytest' -and
            $TimeoutSeconds -eq (Get-Config).sandbox.stepTimeoutMinutes * 60
        }
    }

    It 'mounts only the project folder, with no network, as a non-root user, with limits' {
        $sb = (Get-Config).sandbox
        $a = Get-SandboxDockerArgs $Proj @('node', 'app.js') 'ab-sandbox-test'
        $opts = $a[0..([array]::IndexOf($a, $sb.image) - 1)]
        $value = { param($flag) $opts[[array]::IndexOf($opts, $flag) + 1] }

        $mounts = @(for ($i = 0; $i -lt $opts.Count; $i++) { if ($opts[$i] -eq '--mount') { $opts[$i + 1] } })
        $mounts | Should -Be @("type=bind,source=$Proj,target=/work", "type=bind,source=$(Join-Path $Proj '.git'),target=/work/.git,readonly")
        $opts | Should -Not -Contain '-v'
        $opts | Should -Not -Contain '--volume'
        $opts | Should -Not -Contain '--privileged'
        & $value '--network' | Should -Be 'none'
        & $value '--user' | Should -Be '1000:1000'
        & $value '--cap-drop' | Should -Be 'ALL'
        & $value '--security-opt' | Should -Be 'no-new-privileges'
        $opts | Should -Contain '--read-only'
        & $value '--cpus' | Should -Be "$($sb.cpus)"
        & $value '--memory' | Should -Be "$($sb.memory)"
        & $value '--pids-limit' | Should -Be "$($sb.pidsLimit)"
        $a[-2..-1] | Should -Be @('node', 'app.js')
    }

    It 'gives network access only to the dependency installs' -TestCases @(
        @{ Cmd = 'npm ci --ignore-scripts'; Net = 'bridge' }
        @{ Cmd = 'npm install --ignore-scripts lodash@4 express'; Net = 'bridge' }
        @{ Cmd = 'pip install -r requirements.txt'; Net = 'bridge' }
        @{ Cmd = 'npm install lodash'; Net = 'none' }
        @{ Cmd = 'npm install --ignore-scripts --ignore-scripts=false'; Net = 'none' }
        @{ Cmd = 'pip install requests'; Net = 'none' }
        @{ Cmd = 'npm test'; Net = 'none' }
        @{ Cmd = 'python -m pytest'; Net = 'none' }
    ) {
        $a = Get-SandboxDockerArgs $Proj ($Cmd -split ' ') 'ab-sandbox-test'
        $a[[array]::IndexOf($a, '--network') + 1] | Should -Be $Net
    }

    It 'refuses to mount a folder outside projects/' {
        Mock Invoke-Docker { 0 }
        { Invoke-Sandbox $TestDrive @('python', '-V') } | Should -Throw '*refusing to mount*'
        { Invoke-Sandbox $Root @('python', '-V') } | Should -Throw '*refusing to mount*'
        Should -Invoke Invoke-Docker -Times 0
    }

    It 'stops a step that runs past its time limit' {
        Mock Invoke-Docker { 0 }
        Mock Invoke-Docker { $null } -ParameterFilter { $DockerArgs[0] -eq 'run' }
        Invoke-Sandbox $Proj @('python', 'loop.py') | Should -Be 124
        Should -Invoke Invoke-Docker -Times 1 -Exactly -ParameterFilter { $DockerArgs[0] -eq 'rm' -and $DockerArgs[1] -eq '-f' }
    }
}

Describe 'the build stage can only run code through the sandbox' {
    AfterEach { $env:AB_DOCKER = $SavedDocker }

    It 'puts sandbox on the agent PATH and tells it the project folder' {
        $psi = New-ClaudeStartInfo $Proj 'sonnet' 'build'
        $psi.EnvironmentVariables['AB_SANDBOX_DIR'] | Should -Be $Proj
        $bin = Join-Path (Join-Path $Root 'scripts') 'bin'
        ($psi.EnvironmentVariables['PATH'] -split [regex]::Escape([System.IO.Path]::PathSeparator))[0] | Should -Be $bin
        $psi.EnvironmentVariables['GIT_CONFIG_COUNT'] | Should -Be '2'
        $psi.Arguments | Should -BeLike '*"Bash(sandbox:*)"*'
    }

    It 'ships an allowlist with no host code execution' {
        $cfg = Get-Config
        $cfg.allowedTools | Should -Contain 'Bash(sandbox:*)'
        @($cfg.allowedTools | Where-Object { $_ -match $HostExecRule }) | Should -BeNullOrEmpty
    }

    It 'refuses to start a build stage whose allowlist runs code on the host' {
        $bad = Get-Config
        $bad.allowedTools = @($bad.allowedTools) + 'Bash(python:*)'
        Mock Get-Config { $bad }
        { New-ClaudeStartInfo $Proj 'sonnet' 'build' } | Should -Throw '*run code on the host*'
    }

    It 'does not give the plan stage the sandbox' {
        $psi = New-ClaudeStartInfo $Proj 'opus' 'plan'
        $psi.EnvironmentVariables.ContainsKey('AB_SANDBOX_DIR') | Should -BeFalse
    }

    It 'routes `sandbox <command>` from the agent shell to docker run' {
        $bash = if ($env:ProgramFiles -and (Test-Path "$env:ProgramFiles\Git\bin\bash.exe")) { "$env:ProgramFiles\Git\bin\bash.exe" }
                else { (Get-Command bash -ErrorAction SilentlyContinue).Source }
        if (-not $bash) { Set-ItResult -Skipped -Because 'bash is not installed'; return }
        $log = Join-Path $TestDrive 'docker-args.txt'
        if ($IsWindows -or $env:OS -eq 'Windows_NT') {
            $fake = Join-Path $TestDrive 'docker.cmd'
            Set-Content $fake "@echo off`r`necho %*>>`"$log`"`r`nexit /b 0" -Encoding ASCII
        } else {
            $fake = Join-Path $TestDrive 'docker'
            Set-Content $fake "#!/bin/sh`nprintf '%s\n' `"`$*`" >> '$log'`n"
            chmod +x $fake
        }
        $env:AB_DOCKER = $fake
        $env:AB_SANDBOX_DIR = $Proj
        try {
            $shim = (Join-Path (Join-Path (Join-Path $Root 'scripts') 'bin') 'sandbox') -replace '\\', '/'
            & $bash $shim python -m pytest -q -- 'a b' | Out-Host
            $LASTEXITCODE | Should -Be 0
        } finally { Remove-Item Env:AB_SANDBOX_DIR }
        $logged = Get-Content $log -Raw
        $logged | Should -Match '^run '
        $logged | Should -Match '--network none'
        $logged | Should -Match 'python -m pytest -q -- "?a b"?'
    }
}

Describe 'the daily run without Docker' {
    AfterEach { $env:AB_DOCKER = $SavedDocker }

    It 'refuses to start and runs nothing on the host' {
        $copy = Join-Path $TestDrive 'ab'
        New-Item -ItemType Directory -Force (Join-Path $copy 'inbox') | Out-Null
        foreach ($item in 'scripts', 'prompts', 'docker', 'config.json', 'ab.ps1') {
            Copy-Item -Recurse (Join-Path $RepoRoot $item) $copy
        }
        $cfg = Get-Content (Join-Path $copy 'config.json') -Raw | ConvertFrom-Json
        $cfg.claudePath = Join-Path $TestDrive 'claude-must-not-run.exe'
        $cfg | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $copy 'config.json')
        Set-Content (Join-Path (Join-Path $copy 'inbox') 'some-idea.md') 'an idea'

        $env:AB_DOCKER = Join-Path $TestDrive 'no-docker-here.exe'
        $out = & $HostExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path (Join-Path $copy 'scripts') 'run-daily.ps1') -Force 2>&1 | Out-String

        $LASTEXITCODE | Should -Be 1
        $out | Should -Match 'Run refused'
        $out | Should -Match 'Docker was not found'
        Test-Path (Join-Path (Join-Path $copy 'inbox') 'some-idea.md') | Should -BeTrue   # not even planned
        @(Get-ChildItem (Join-Path $copy 'projects') -ErrorAction SilentlyContinue).Count | Should -Be 0
        Test-Path (Join-Path (Join-Path $copy 'state') 'last-run.txt') | Should -BeFalse  # retried on the next trigger
    }

    It 'explains that Docker Desktop must be started when it is installed but not running' {
        $env:AB_DOCKER = $HostExe   # any existing executable stands in for docker here
        Mock Invoke-Docker { 1 }
        { Assert-SandboxReady } | Should -Throw '*not running*'
    }
}
