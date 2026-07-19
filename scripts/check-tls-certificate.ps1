param(
    [Parameter(Mandatory = $true)]
    [string] $CertificatePath,

    [Parameter(Mandatory = $true)]
    [string] $ExpectedHost
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $CertificatePath -PathType Leaf)) {
    throw "Certificate file does not exist: $CertificatePath"
}

$certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
    (Resolve-Path -LiteralPath $CertificatePath).Path
)
$now = [DateTimeOffset]::Now
if ($now -lt $certificate.NotBefore -or $now -gt $certificate.NotAfter) {
    throw "Certificate is outside its validity window."
}

$identities = New-Object System.Collections.Generic.List[string]
$san = $certificate.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' } | Select-Object -First 1
if ($null -ne $san) {
    foreach ($entry in ($san.Format($false) -split ',\s*')) {
        $separator = $entry.IndexOf('=')
        if ($separator -ge 0) {
            $identities.Add($entry.Substring($separator + 1).Trim())
        }
    }
}
if ($identities.Count -eq 0) {
    $commonName = $certificate.GetNameInfo(
        [System.Security.Cryptography.X509Certificates.X509NameType]::DnsName,
        $false
    )
    if (-not [string]::IsNullOrWhiteSpace($commonName)) {
        $identities.Add($commonName)
    }
}

function Test-HostIdentity([string] $HostName, [string] $Pattern) {
    if ($HostName.Equals($Pattern, [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    if ($Pattern.StartsWith('*.')) {
        $suffix = $Pattern.Substring(1)
        if ($HostName.EndsWith($suffix, [StringComparison]::OrdinalIgnoreCase)) {
            $prefix = $HostName.Substring(0, $HostName.Length - $suffix.Length)
            return -not $prefix.Contains('.') -and $prefix.Length -gt 0
        }
    }
    return $false
}

$identityMatches = $false
foreach ($identity in $identities) {
    if (Test-HostIdentity $ExpectedHost $identity) {
        $identityMatches = $true
        break
    }
}
if (-not $identityMatches) {
    throw "Certificate identity does not match PUBLIC_HOST '$ExpectedHost'."
}

$chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
$chain.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
if (-not $chain.Build($certificate)) {
    $problems = $chain.ChainStatus | ForEach-Object { $_.Status.ToString() }
    throw "Certificate is not trusted by the current user or machine: $($problems -join ', ')."
}

Write-Output "VALID: HTTPS certificate matches $ExpectedHost and is locally trusted."
