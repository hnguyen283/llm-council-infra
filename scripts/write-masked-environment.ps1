param(
    [Parameter(Mandatory = $true)]
    [string] $OutputPath,

    [Parameter(Mandatory = $true)]
    [string] $Root,

    [Parameter(Mandatory = $true)]
    [string] $EnvironmentListPath
)

$ErrorActionPreference = 'Stop'
$values = [ordered]@{}

$environmentFiles = [IO.File]::ReadAllLines((Resolve-Path -LiteralPath $EnvironmentListPath).Path) |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    ForEach-Object { Join-Path $Root $_ }

foreach ($environmentFile in $environmentFiles) {
    if (-not (Test-Path -LiteralPath $environmentFile -PathType Leaf)) {
        continue
    }
    foreach ($line in [IO.File]::ReadLines((Resolve-Path -LiteralPath $environmentFile).Path)) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith('#')) {
            continue
        }
        $separator = $line.IndexOf('=')
        if ($separator -le 0) {
            continue
        }
        $key = $line.Substring(0, $separator)
        $values[$key] = $line.Substring($separator + 1).TrimEnd("`r")
    }
}

$output = New-Object System.Collections.Generic.List[string]
foreach ($key in @($values.Keys)) {
    $processValue = [Environment]::GetEnvironmentVariable($key, 'Process')
    $value = if ($null -ne $processValue) { $processValue } else { $values[$key] }
    if ($key -notmatch '(_FILE|_DIR)$' -and
        $key -match '(PASSWORD|SECRET|TOKEN|PRIVATE|PEM|API_KEY|HMAC_KEY|SIGNING_KEY)' -and
        -not [string]::IsNullOrEmpty($value)) {
        $value = '***'
    }
    $output.Add("$key=$value")
}

$utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllLines($OutputPath, $output, $utf8WithoutBom)
