# Runs one build command inside the Docker sandbox. Called through scripts/bin/sandbox, which
# prefixes every argument with '+'. The project folder comes from AB_SANDBOX_DIR, set by the runner.
. (Join-Path $PSScriptRoot 'lib.ps1')
$command = @($args | ForEach-Object { "$_".Substring(1) })
try {
    exit (Invoke-Sandbox $env:AB_SANDBOX_DIR $command)
} catch {
    [Console]::Error.WriteLine("sandbox: $($_.Exception.Message)")
    exit 125
}
