param(
    [string] $InfraRoot,
    [string] $ProjectRoot,
    [string] $RepoRoot,
    [string] $HostInfoPath,
    [string] $EnvPath,
    [string] $RemoteDir = "/opt/llm-council",
    [int] $WaitSeconds = 300,
    [switch] $SkipBuild,
    [switch] $SkipUiBuild,
    [switch] $UseHostPassword,
    [switch] $DryRun,
    [switch] $KeepBundle
)

$ErrorActionPreference = "Stop"

if (-not $InfraRoot) {
    $InfraRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}
if (-not $RepoRoot) {
    $RepoRoot = (Resolve-Path (Join-Path $InfraRoot "..\llm-council")).Path
}
if (-not $ProjectRoot) {
    $ProjectRoot = (Resolve-Path (Join-Path $InfraRoot "..")).Path
}
if (-not $HostInfoPath) {
    $HostInfoPath = Join-Path $ProjectRoot "hostInfo.txt"
}
if (-not $EnvPath) {
    $EnvPath = Join-Path $InfraRoot "prod-lite.env"
}
$UiRoot = Join-Path $ProjectRoot "llm-council-ui"
$AdminUiRoot = Join-Path $ProjectRoot "llm-council-admin-ui"
$RequiredServices = @(
    "config-server",
    "discovery-server",
    "api-gateway",
    "auth-service",
    "account-service",
    "orchestrator-service",
    "prompt-service",
    "gemini-service",
    "gpt-service"
)

function Write-Step([string] $Message) {
    Write-Host ""
    Write-Host "=== [deploy-vps] $Message ==="
}

function Read-KeyValueFile([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "File not found: $Path"
    }

    $values = @{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line.TrimStart().StartsWith("#")) { continue }
        if ($line -notmatch "^\s*([^:=]+?)\s*[:=]\s*(.*)\s*$") { continue }
        $key = ($matches[1].Trim().ToLowerInvariant() -replace "[^a-z0-9]", "")
        $values[$key] = $matches[2].Trim()
    }
    return $values
}

function Read-DotEnv([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Env file not found: $Path"
    }

    $values = [ordered]@{}
    foreach ($rawLine in Get-Content -LiteralPath $Path) {
        $line = $rawLine.Trim()
        if ($line.Length -eq 0 -or $line.StartsWith("#")) { continue }
        if ($line -notmatch "^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$") { continue }

        $key = $matches[1]
        $value = $matches[2]
        if (($value.StartsWith('"') -and $value.EndsWith('"')) -or
            ($value.StartsWith("'") -and $value.EndsWith("'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $values[$key] = $value
    }
    return $values
}

function Require-Env([hashtable] $EnvValues, [string[]] $Keys) {
    $missing = @()
    foreach ($key in $Keys) {
        if (-not $EnvValues.Contains($key) -or [string]::IsNullOrWhiteSpace([string] $EnvValues[$key])) {
            $missing += $key
        }
    }
    if ($missing.Count -gt 0) {
        throw "Missing required prod-lite.env value(s): $($missing -join ', ')"
    }
}

function Copy-RelativePath([string] $RelativePath, [string] $DestinationRoot) {
    $src = Join-Path $RepoRoot $RelativePath
    if (-not (Test-Path -LiteralPath $src)) {
        throw "Required artifact path not found: $RelativePath"
    }
    $dst = Join-Path $DestinationRoot $RelativePath
    $dstParent = Split-Path -Parent $dst
    New-Item -ItemType Directory -Force -Path $dstParent | Out-Null
    Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force
}

function Copy-InfraPath([string] $RelativePath, [string] $DestinationRoot) {
    $src = Join-Path $InfraRoot $RelativePath
    if (-not (Test-Path -LiteralPath $src)) {
        throw "Required infra path not found: $RelativePath"
    }
    $dst = Join-Path $DestinationRoot $RelativePath
    $dstParent = Split-Path -Parent $dst
    New-Item -ItemType Directory -Force -Path $dstParent | Out-Null
    Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force
}

function Copy-UiProject([string] $SourceRoot, [string] $ProjectName, [string] $DestinationRoot) {
    if (-not (Test-Path -LiteralPath $SourceRoot)) {
        Write-Host "WARNING: UI project not found, skipping: $SourceRoot"
        return
    }

    $targetRoot = Join-Path $DestinationRoot "ui-source\$ProjectName"
    New-Item -ItemType Directory -Force -Path $targetRoot | Out-Null

    $items = @(
        "angular.json",
        "package.json",
        "package-lock.json",
        "proxy.conf.json",
        "proxy.vps.conf.json",
        "proxy.https.conf.cjs",
        "tsconfig.app.json",
        "tsconfig.json",
        "src",
        "dist"
    )

    foreach ($item in $items) {
        $src = Join-Path $SourceRoot $item
        if (-not (Test-Path -LiteralPath $src)) { continue }
        $dst = Join-Path $targetRoot $item
        Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force
    }
}

function Invoke-UiBuild([string] $SourceRoot, [string] $Label) {
    if (-not (Test-Path -LiteralPath (Join-Path $SourceRoot "package.json"))) {
        Write-Host "WARNING: $Label package.json not found, skipping UI build."
        return
    }
    Push-Location $SourceRoot
    try {
        Invoke-External "npm.cmd" @("run", "build")
    } finally {
        Pop-Location
    }
}

function Invoke-External([string] $FileName, [string[]] $Arguments) {
    if ($DryRun) {
        Write-Host "[dry-run] $FileName $($Arguments -join ' ')"
        return
    }
    & $FileName @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$FileName exited with code $LASTEXITCODE"
    }
}

function Shell-Quote([string] $Value) {
    return "'" + ($Value -replace "'", "'\''") + "'"
}

function Join-WindowsArguments([string[]] $Arguments) {
    $quoted = foreach ($arg in $Arguments) {
        if ($null -eq $arg) { '""'; continue }
        if ($arg -eq "") { '""'; continue }
        if ($arg -notmatch '[\s"]') { $arg; continue }

        $builder = New-Object System.Text.StringBuilder
        [void] $builder.Append('"')
        $slashes = 0
        foreach ($ch in $arg.ToCharArray()) {
            if ($ch -eq '\') {
                $slashes++
                continue
            }
            if ($ch -eq '"') {
                [void] $builder.Append(('\' * (($slashes * 2) + 1)))
                [void] $builder.Append('"')
                $slashes = 0
                continue
            }
            if ($slashes -gt 0) {
                [void] $builder.Append(('\' * $slashes))
                $slashes = 0
            }
            [void] $builder.Append($ch)
        }
        if ($slashes -gt 0) {
            [void] $builder.Append(('\' * ($slashes * 2)))
        }
        [void] $builder.Append('"')
        $builder.ToString()
    }
    return ($quoted -join " ")
}

function New-EnvExportLines([System.Collections.Specialized.OrderedDictionary] $EnvValues) {
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($key in $EnvValues.Keys) {
        if ($key -notmatch "^[A-Za-z_][A-Za-z0-9_]*$") { continue }
        $bytes = [System.Text.Encoding]::UTF8.GetBytes([string] $EnvValues[$key])
        $b64 = [Convert]::ToBase64String($bytes)
        $lines.Add('export ' + $key + '="$(printf ' + (Shell-Quote '%s') + ' ' + (Shell-Quote $b64) + ' | base64 -d)"')
    }
    return $lines
}

function Invoke-SshScript([string] $SshTarget, [int] $SshPort, [string] $Script) {
    if ($DryRun) {
        if ($UseHostPassword) {
            Write-Host "[dry-run] plink -ssh -P $SshPort -l $username -pw ******** $ip bash -se"
        } else {
            Write-Host "[dry-run] ssh -p $SshPort $SshTarget bash -se"
        }
        Write-Host "[dry-run] remote script prepared; secret export lines are intentionally not printed."
        return
    }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    if ($UseHostPassword) {
        $psi.FileName = $script:PlinkPath
        $psi.Arguments = Join-WindowsArguments @(
            "-ssh",
            "-batch",
            "-P",
            [string] $SshPort,
            "-l",
            $username,
            "-pw",
            $script:HostPassword,
            $ip,
            "bash",
            "-se"
        )
    } else {
        $psi.FileName = "ssh"
        $psi.Arguments = Join-WindowsArguments @(
            "-p",
            [string] $SshPort,
            $SshTarget,
            "bash",
            "-se"
        )
    }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true

    $process = [System.Diagnostics.Process]::Start($psi)
    try {
        $process.StandardInput.Write($Script)
        $process.StandardInput.Close()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) {
            throw "ssh remote script exited with code $($process.ExitCode)"
        }
    } finally {
        $process.Dispose()
    }
}

function Copy-RemoteFile([string] $LocalPath, [string] $SshTarget, [int] $SshPort, [string] $RemotePath) {
    if ($DryRun) {
        if ($UseHostPassword) {
            Write-Host "[dry-run] pscp -P $SshPort -l $username -pw ******** $LocalPath ${ip}:$RemotePath"
        } else {
            Write-Host "[dry-run] scp -P $SshPort $LocalPath ${SshTarget}:$RemotePath"
        }
        return
    }

    if ($UseHostPassword) {
        & $script:PscpPath -batch -P $SshPort -l $username -pw $script:HostPassword $LocalPath "${ip}:$RemotePath"
    } else {
        & scp -P $SshPort $LocalPath "${SshTarget}:$RemotePath"
    }
    if ($LASTEXITCODE -ne 0) {
        throw "artifact transfer exited with code $LASTEXITCODE"
    }
}

Write-Step "Reading hostInfo.txt and llm-council\prod-lite.env"
$hostInfo = Read-KeyValueFile $HostInfoPath
$envValues = Read-DotEnv $EnvPath

$ip = $hostInfo["ip"]
$username = $hostInfo["username"]
$sshPortRaw = $hostInfo["portssh"]
$hasPassword = $hostInfo.ContainsKey("password") -and -not [string]::IsNullOrWhiteSpace($hostInfo["password"])

if ([string]::IsNullOrWhiteSpace($ip)) { throw "hostInfo.txt is missing IP" }
if ([string]::IsNullOrWhiteSpace($username)) { throw "hostInfo.txt is missing Username" }
if ([string]::IsNullOrWhiteSpace($sshPortRaw)) { $sshPortRaw = "22" }
$sshPort = [int] $sshPortRaw
$sshTarget = "$username@$ip"

if ($UseHostPassword) {
    if (-not $hasPassword) {
        throw "-UseHostPassword was supplied, but hostInfo.txt does not contain a Password value."
    }
    $script:PlinkPath = (Get-Command plink.exe -ErrorAction SilentlyContinue).Source
    $script:PscpPath = (Get-Command pscp.exe -ErrorAction SilentlyContinue).Source
    if (-not $script:PlinkPath -or -not $script:PscpPath) {
        throw "-UseHostPassword requires PuTTY plink.exe and pscp.exe on PATH."
    }
    $script:HostPassword = $hostInfo["password"]
    Write-Host "Using Password from hostInfo.txt through PuTTY plink/pscp. The password is not transferred to the VPS, but it is supplied to local PuTTY processes for this deployment."
} elseif ($hasPassword) {
    Write-Host "hostInfo.txt contains a password, but default OpenSSH mode cannot consume passwords from files."
    Write-Host "Use SSH key auth to avoid prompts, or rerun with -UseHostPassword to use PuTTY plink/pscp."
}

Require-Env $envValues @(
    "POSTGRES_USER",
    "POSTGRES_PASSWORD",
    "POSTGRES_DB",
    "ACCOUNT_DB_USER",
    "ACCOUNT_DB_PASSWORD",
    "PROMPT_DB_USER",
    "PROMPT_DB_PASSWORD",
    "VALKEY_PASSWORD",
    "AUTH_JWT_SIGNING_KID",
    "AUTH_JWT_PRIVATE_KEY_PEM",
    "AUTH_JWT_PUBLIC_KEYS_PEM",
    "GATEWAY_INTERNAL_KID",
    "GATEWAY_INTERNAL_PRIVATE_KEY_PEM",
    "GATEWAY_INTERNAL_PUBLIC_KEYS_PEM",
    "ACCOUNT_INTERNAL_SERVICE_TOKEN",
    "GEMINI_API_KEY",
    "OPENAI_API_KEY",
    "GRAPHRAG_DB_PASSWORD",
    "LOG_DIR_HOST",
    "AUTH_GOOGLE_CLIENT_ID",
    "AUTH_GOOGLE_ALLOWED_DOMAINS",
    "AUTH_GOOGLE_SIGNUP_SECRET"
)

if (-not $envValues.Contains("PLAN_BY_AI_ENABLED")) {
    $envValues["PLAN_BY_AI_ENABLED"] = "true"
}
if (-not $envValues.Contains("ORCHESTRATOR_CONCURRENCY_MAX_JOBS")) {
    $envValues["ORCHESTRATOR_CONCURRENCY_MAX_JOBS"] = "25"
}

if (-not $SkipBuild) {
    Write-Step "Compiling backend and packaging required JARs"
    Push-Location $RepoRoot
    try {
        Invoke-External "mvn" @(
            "-pl",
            "common,config-server,discovery-server,api-gateway,auth-service,account-service,orchestrator-service,prompt-service,gemini-service,gpt-service",
            "-am",
            "-DskipTests",
            "package"
        )
    } finally {
        Pop-Location
    }
} else {
    Write-Step "Skipping Maven package because -SkipBuild was supplied"
}

if (-not $SkipUiBuild) {
    Write-Step "Building Angular UI bundles"
    Invoke-UiBuild $UiRoot "portal UI"
    Invoke-UiBuild $AdminUiRoot "admin UI"
} else {
    Write-Step "Skipping Angular UI builds because -SkipUiBuild was supplied"
}

Write-Step "Building deployment artifact bundle without .env files"
$stamp = (Get-Date -Format "yyyyMMdd-HHmmss-fff") + "-" + ([guid]::NewGuid().ToString("N").Substring(0, 8))
$staging = Join-Path ([IO.Path]::GetTempPath()) "llm-council-vps-stage-$stamp"
$bundle = Join-Path ([IO.Path]::GetTempPath()) "llm-council-vps-release-$stamp.tgz"

if (Test-Path -LiteralPath $staging) {
    Remove-Item -LiteralPath $staging -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $staging | Out-Null

Copy-InfraPath "projects\data\docker-compose.yml" $staging
Copy-InfraPath "projects\data\overlays\postgres-external.yml" $staging
Copy-InfraPath "projects\data\overlays\vps-operational.yml" $staging
Copy-InfraPath "projects\messaging\docker-compose.yml" $staging
Copy-InfraPath "projects\messaging\overlays\prod-laptop-tunnel.yml" $staging
Copy-InfraPath "projects\platform\docker-compose.yml" $staging
Copy-InfraPath "projects\platform\overlays\prod.yml" $staging
Copy-InfraPath "projects\platform\overlays\log-files.yml" $staging
Copy-InfraPath "projects\core\docker-compose.yml" $staging
Copy-InfraPath "projects\core\overlays\prod.yml" $staging
Copy-InfraPath "projects\core\overlays\prod-lite.yml" $staging
Copy-InfraPath "projects\core\overlays\log-files.yml" $staging
Copy-InfraPath "projects\graphrag\docker-compose.yml" $staging
Copy-InfraPath "projects\graphrag\overlays\log-files.yml" $staging
Copy-InfraPath "prod-lite.sh" $staging
Copy-RelativePath "config-repo" $staging
Copy-InfraPath "infra\postgres\Dockerfile" $staging
Copy-InfraPath "infra\postgres\initdb" $staging
Copy-RelativePath "graphrag-service\Dockerfile" $staging
Copy-RelativePath "graphrag-service\requirements.txt" $staging
Copy-RelativePath "graphrag-service\requirements.lock" $staging
Copy-RelativePath "graphrag-service\scripts" $staging
Copy-RelativePath "graphrag-service\src" $staging
Copy-UiProject $UiRoot "llm-council-ui" $staging
Copy-UiProject $AdminUiRoot "llm-council-admin-ui" $staging

foreach ($service in $RequiredServices) {
    Copy-RelativePath "$service\Dockerfile" $staging
    $jarDir = Join-Path $RepoRoot "$service\target"
    $jars = Get-ChildItem -LiteralPath $jarDir -Filter "*.jar" -File |
        Where-Object { -not $_.Name.EndsWith(".jar.original") }
    if ($jars.Count -eq 0) {
        throw "No packaged JAR found for $service under $jarDir"
    }
    foreach ($jar in $jars) {
        $targetDir = Join-Path $staging "$service\target"
        New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
        Copy-Item -LiteralPath $jar.FullName -Destination (Join-Path $targetDir $jar.Name) -Force
    }
}

$forbiddenFiles = Get-ChildItem -LiteralPath $staging -Recurse -Force |
    Where-Object {
        $_.Name -eq ".env" -or
        $_.Name.StartsWith(".env.") -or
        $_.Name -eq ".env.local" -or
        $_.Name -eq "prod-lite.env" -or
        $_.Name -ieq "hostInfo.txt" -or
        $_.Extension -in @(".pem", ".key", ".p12") -or
        ($_.PSIsContainer -and $_.Name -ieq "ssl")
    }
if ($forbiddenFiles.Count -gt 0) {
    throw "Artifact bundle contains forbidden sensitive files or directories; refusing to deploy."
}

if (Test-Path -LiteralPath $bundle) {
    Remove-Item -LiteralPath $bundle -Force
}
Push-Location $staging
try {
    & tar -czf $bundle .
    if ($LASTEXITCODE -ne 0) {
        throw "tar exited with code $LASTEXITCODE"
    }
} finally {
    Pop-Location
}

Write-Host "Artifact bundle prepared: $bundle"

if ($DryRun) {
    Write-Step "Dry run complete before SSH transfer"
    Write-Host "Target: $sshTarget on SSH port $sshPort"
    Write-Host "Remote directory: $RemoteDir"
    if (-not $KeepBundle) {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $bundle -Force -ErrorAction SilentlyContinue
    }
    exit 0
}

Write-Step "Transferring deployment artifacts"
$remoteBundle = "/tmp/llm-council-release.tgz"
Copy-RemoteFile $bundle $sshTarget $sshPort $remoteBundle

Write-Step "Executing remote Docker Compose deployment"
$exportLines = New-EnvExportLines $envValues
$quotedRemoteDir = Shell-Quote $RemoteDir
$quotedRemoteBundle = Shell-Quote $remoteBundle
$remoteScript = @"
set -eu
set +x

REMOTE_DIR=$quotedRemoteDir
REMOTE_BUNDLE=$quotedRemoteBundle
WAIT_SECONDS=$WaitSeconds

mkdir -p "`$REMOTE_DIR"
tar -xzf "`$REMOTE_BUNDLE" -C "`$REMOTE_DIR"
cd "`$REMOTE_DIR"

export COMPOSE_DISABLE_ENV_FILE=1
$($exportLines -join "`n")
export REMOTE_DIR
export WAIT_SECONDS

chmod 700 ./prod-lite.sh
./prod-lite.sh
rm -f "`$REMOTE_BUNDLE"
"@

Invoke-SshScript $sshTarget $sshPort $remoteScript

Write-Step "Deployment finished"
Write-Host "VPS containers were started with environment variables injected over SSH; no environment file was transferred."

if (-not $KeepBundle) {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $bundle -Force -ErrorAction SilentlyContinue
}
