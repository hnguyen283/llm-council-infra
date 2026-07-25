[CmdletBinding()]
param([ValidateSet('validate', 'test', 'security', 'package', 'evidence', 'all')][string]$Stage = 'all')

$gitBash = Join-Path ${env:ProgramFiles} 'Git\bin\bash.exe'
if (-not (Test-Path -LiteralPath $gitBash)) { throw 'Git Bash is required for the POSIX CI contract.' }
& $gitBash -lc "cd '$($PSScriptRoot.Replace('\', '/'))/..' && bash ci/run.sh $Stage"
exit $LASTEXITCODE
