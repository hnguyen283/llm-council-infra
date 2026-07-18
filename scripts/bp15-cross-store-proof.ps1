param(
  [string]$BaseUrl = "http://127.0.0.1:8080",
  [ValidateRange(5, 20)][int]$ExpectedTenantCount = 5,
  [ValidateRange(1, 100)][int]$ExpectedJobsPerTenant = 20,
  [string]$PostgresContainer = "llm-council-standard-postgres-1",
  [string]$ValkeyContainer = "llm-council-standard-valkey-1",
  [string]$OrchestratorContainer = "llm-council-standard-orchestrator-service-1",
  [string]$GraphRagIndexerContainer = "llm-council-standard-graphrag-indexing-worker-1",
  [string]$KafkaContainer = "llm-council-standard-kafka-1",
  [ValidateRange(30, 600)][int]$IndexingTimeoutSeconds = 240
)

$ErrorActionPreference = "Stop"
$expectedJobCount = $ExpectedTenantCount * $ExpectedJobsPerTenant
$databaseName = $null
$databaseUser = $null

function Assert-LastExitCode([string]$Operation) {
  if ($LASTEXITCODE -ne 0) { throw "$Operation failed with exit code $LASTEXITCODE." }
}

function Invoke-Psql([string]$Sql) {
  & docker exec $PostgresContainer psql -U $script:databaseUser -d $script:databaseName -v ON_ERROR_STOP=1 -qAt -c ("SET search_path TO account; " + $Sql)
  Assert-LastExitCode "Postgres query"
}

function Get-ContainerEnvironmentValue([string]$Container, [string]$Name) {
  $lines = & docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' $Container
  Assert-LastExitCode "Inspect container environment"
  $prefix = $Name + "="
  foreach ($line in $lines) {
    if ($line.StartsWith($prefix)) { return $line.Substring($prefix.Length) }
  }
  return $null
}

function Get-HmacHex([string]$Key, [string]$Value) {
  $hmac = [System.Security.Cryptography.HMACSHA256]::new([Text.Encoding]::UTF8.GetBytes($Key))
  try {
    return [BitConverter]::ToString($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value))).Replace("-", "").ToLowerInvariant()
  } finally {
    $hmac.Dispose()
  }
}

function Get-Sha256Hex([string]$Value) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value))).Replace("-", "").ToLowerInvariant()
  } finally {
    $sha.Dispose()
  }
}

function Get-StatusCode($ErrorRecord) {
  if ($null -eq $ErrorRecord.Exception.Response) { return $null }
  try { return [int]$ErrorRecord.Exception.Response.StatusCode } catch { return $null }
}

function Invoke-Valkey([string[]]$Arguments) {
  $password = Get-ContainerEnvironmentValue $ValkeyContainer "VALKEY_PASSWORD"
  if ([string]::IsNullOrWhiteSpace($password)) { throw "VALKEY_PASSWORD is unavailable." }
  $dockerArgs = @("exec", $ValkeyContainer, "valkey-cli", "--no-auth-warning", "-a", $password, "--raw") + $Arguments
  $result = @(& docker @dockerArgs)
  Assert-LastExitCode "Valkey query"
  return $result
}

$databaseName = (& docker exec $PostgresContainer printenv POSTGRES_DB).Trim()
Assert-LastExitCode "Postgres database discovery"
$databaseUser = (& docker exec $PostgresContainer printenv POSTGRES_USER).Trim()
Assert-LastExitCode "Postgres database user discovery"

# Select the five most recent accounts that each own exactly the expected
# number of successful requests. Raw account and job identifiers never leave
# this process; all emitted evidence is aggregate.
$accountRows = @(Invoke-Psql @"
WITH grouped AS (
  SELECT account_id,
         count(*) AS total_count,
         count(*) FILTER (WHERE status = 'DONE') AS done_count,
         max(started_at) AS last_started
  FROM usage_requests
  WHERE started_at >= now() - interval '4 hours'
  GROUP BY account_id
), selected AS (
  SELECT account_id, total_count, done_count, last_started
  FROM grouped
  WHERE total_count = $ExpectedJobsPerTenant AND done_count = $ExpectedJobsPerTenant
  ORDER BY last_started DESC
  LIMIT $ExpectedTenantCount
)
SELECT account_id::text || '|' || total_count || '|' || done_count
FROM selected
ORDER BY last_started;
"@)
if ($accountRows.Count -ne $ExpectedTenantCount) {
  throw "Expected $ExpectedTenantCount completed workload owners, found $($accountRows.Count)."
}

$accountIds = New-Object System.Collections.Generic.List[string]
foreach ($row in $accountRows) {
  $parts = $row.Split('|')
  if ($parts.Count -ne 3 -or [int]$parts[1] -ne $ExpectedJobsPerTenant -or [int]$parts[2] -ne $ExpectedJobsPerTenant) {
    throw "Relational workload distribution is incomplete."
  }
  $accountIds.Add($parts[0])
}
$accountIdSet = @{}
foreach ($accountId in $accountIds) { $accountIdSet[$accountId] = $true }
$idList = ($accountIds | ForEach-Object { "'$_'" }) -join ","

$jobRows = @(Invoke-Psql "SELECT job_id || '|' || status || '|' || account_id::text FROM usage_requests WHERE account_id IN ($idList) AND started_at >= now() - interval '4 hours' ORDER BY started_at;")
if ($jobRows.Count -ne $expectedJobCount) { throw "Relational usage row count is not $expectedJobCount." }
$jobIds = New-Object System.Collections.Generic.List[string]
$jobOwners = @{}
foreach ($row in $jobRows) {
  $parts = $row.Split('|')
  if ($parts.Count -ne 3 -or $parts[1] -ne "DONE" -or -not $accountIdSet.ContainsKey($parts[2])) {
    throw "Relational usage ownership or terminal state is invalid."
  }
  $jobIds.Add($parts[0])
  $jobOwners[$parts[0]] = $parts[2]
}

# Validate the Valkey record/index layout without printing any key, tenant, or
# job identifier. Every record must be terminal and stored under the tenant
# HMAC referenced by its short-lived reverse index.
$jobIndexKeys = @($jobIds | ForEach-Object { "job-index:" + $_ })
$indexHashes = @(Invoke-Valkey (@("MGET") + $jobIndexKeys))
if ($indexHashes.Count -ne $expectedJobCount) { throw "Valkey job-index result count is incomplete." }
$recordKeys = New-Object System.Collections.Generic.List[string]
for ($i = 0; $i -lt $jobIds.Count; $i++) {
  $tenantHash = [string]$indexHashes[$i]
  if ($tenantHash -notmatch '^[0-9a-f]{64}$') { throw "Valkey tenant namespace is not an HMAC-SHA256 label." }
  $recordKeys.Add("job:" + $tenantHash + ":" + $jobIds[$i])
}
$recordJson = @(Invoke-Valkey (@("MGET") + @($recordKeys)))
if ($recordJson.Count -ne $expectedJobCount) { throw "Valkey job record result count is incomplete." }
$cacheTenantHashes = @{}
for ($i = 0; $i -lt $recordJson.Count; $i++) {
  if ([string]::IsNullOrWhiteSpace([string]$recordJson[$i])) { throw "Valkey job record is missing." }
  $record = $recordJson[$i] | ConvertFrom-Json
  $jobId = [string]$record.jobId
  $owner = [string]$record.ownerUserId
  if (-not $jobOwners.ContainsKey($jobId) -or $jobOwners[$jobId] -ne $owner -or
      [string]$record.tenantId -ne $owner -or [string]$record.actorAccountId -ne $owner -or
      [string]$record.snapshot.state -ne "DONE") {
    throw "Valkey job ownership, tenant context, or terminal state is invalid."
  }
  if ($recordKeys[$i].Contains($owner)) { throw "Raw tenant identifier leaked into a Valkey job key." }
}

$orchestratorNamespaceKey = Get-ContainerEnvironmentValue $OrchestratorContainer "TENANT_NAMESPACE_HMAC_KEY"
$graphRagNamespaceKey = Get-ContainerEnvironmentValue $GraphRagIndexerContainer "TENANT_NAMESPACE_HMAC_KEY"
if ([string]::IsNullOrWhiteSpace($orchestratorNamespaceKey) -or
    [string]::IsNullOrWhiteSpace($graphRagNamespaceKey) -or
    $orchestratorNamespaceKey -ne $graphRagNamespaceKey) {
  throw "Orchestrator and GraphRAG tenant namespace keys are missing or inconsistent."
}
foreach ($accountId in $accountIds) {
  $cacheTenantHashes[(Get-HmacHex $graphRagNamespaceKey $accountId)] = $true
}

# A successful workload does not guarantee a cache write (for example, a
# no-match search can return before the cache-set path). Exercise the production
# GraphRAG cache module directly with bounded, short-lived probes so all five
# tenant namespaces are covered without relying on model/search output shape.
$cacheProbeNonce = [Guid]::NewGuid().ToString("N")
$cacheProbeKeys = New-Object System.Collections.Generic.List[string]
$cacheProbePython = "import os; from src.db.cache import set_cached_query; set_cached_query(os.environ['BP15_TENANT_ID'], 'local', os.environ['BP15_QUERY'], {'bp15Probe': True}, 300)"
foreach ($accountId in $accountIds) {
  $query = "bp15 tenant cache isolation probe " + $cacheProbeNonce
  $dockerArgs = @(
    "exec",
    "-e", ("BP15_TENANT_ID=" + $accountId),
    "-e", ("BP15_QUERY=" + $query),
    $GraphRagIndexerContainer,
    "python", "-c", $cacheProbePython
  )
  & docker @dockerArgs | Out-Null
  Assert-LastExitCode "GraphRAG cache isolation probe"
  $tenantHash = Get-HmacHex $graphRagNamespaceKey $accountId
  $queryDigest = Get-Sha256Hex $query.ToLowerInvariant()
  $cacheProbeKeys.Add("query_cache:v2:${tenantHash}:local:standard:${queryDigest}")
}

$queryCacheKeys = @(Invoke-Valkey @("--scan", "--pattern", "query_cache:v2:*"))
$matchedCacheKeys = 0
$matchedCacheTenants = @{}
foreach ($key in $queryCacheKeys) {
  $parts = $key.Split(':')
  if ($parts.Count -ne 6 -or $parts[0] -ne "query_cache" -or $parts[1] -ne "v2" -or
      $parts[2] -notmatch '^[0-9a-f]{64}$' -or $parts[5] -notmatch '^[0-9a-f]{64}$') {
    throw "GraphRAG v2 cache key shape is invalid."
  }
  foreach ($accountId in $accountIds) {
    if ($key.Contains($accountId)) { throw "Raw tenant identifier leaked into a GraphRAG cache key." }
  }
  if ($cacheTenantHashes.ContainsKey($parts[2])) {
    $matchedCacheKeys++
    $matchedCacheTenants[$parts[2]] = $true
  }
}
if ($matchedCacheTenants.Count -ne $ExpectedTenantCount) {
  throw "GraphRAG cache evidence does not cover every workload tenant."
}
Invoke-Valkey (@("DEL") + @($cacheProbeKeys)) | Out-Null

$provisionedCount = [int](Invoke-Psql "SELECT count(*) FROM tenant_provisioning WHERE tenant_id IN ($idList) AND store_type = 'GRAPHRAG' AND provisioning_state = 'PROVISIONED';")
if ($provisionedCount -ne $ExpectedTenantCount) { throw "GraphRAG provisioning is incomplete for workload tenants." }
$namespaceCount = 0
$graphCount = 0
foreach ($accountId in $accountIds) {
  $suffix = $accountId.Replace('-', '_')
  $schema = "tenant_" + $suffix
  $graph = "research_graph_" + $suffix
  $namespaceCount += [int](Invoke-Psql "SELECT count(*) FROM information_schema.schemata WHERE schema_name = '$schema';")
  $graphCount += [int](Invoke-Psql "SELECT count(*) FROM ag_catalog.ag_graph WHERE name = '$graph';")
}
if ($namespaceCount -ne $ExpectedTenantCount -or $graphCount -ne $ExpectedTenantCount) {
  throw "GraphRAG relational/AGE namespaces are incomplete."
}

# Publish two non-sensitive synthetic evidence records through the live Kafka
# topic and let the real GraphRAG indexer process them. This provides an exact
# key/tenant/schema isolation probe even when normal research returns no URLs.
$probeNonce = [Guid]::NewGuid().ToString("N")
$probeRecords = New-Object System.Collections.Generic.List[object]
for ($i = 0; $i -lt 2; $i++) {
  $tenantId = $accountIds[$i]
  $url = "https://bp15.invalid/isolation/" + $probeNonce + "/" + $i
  $documentId = Get-Sha256Hex $url.ToLowerInvariant()
  $partitionKey = Get-HmacHex $graphRagNamespaceKey $tenantId
  $payload = [ordered]@{
    jobId = "bp15-cross-store-" + $probeNonce + "-" + $i
    tenantId = $tenantId
    documentId = $documentId
    url = $url
    domain = "bp15.invalid"
    title = "BP1.5 isolation probe"
    content = "Disposable BP1.5 tenant isolation evidence record number " + $i + "."
    language = "en"
    timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  } | ConvertTo-Json -Compress
  $probeRecords.Add([pscustomobject]@{ TenantId = $tenantId; DocumentId = $documentId; Key = $partitionKey; Payload = $payload })
}
$producerInput = ($probeRecords | ForEach-Object { $_.Key + "|" + $_.Payload }) -join [Environment]::NewLine
$producerInput | & docker exec -i $KafkaContainer /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server localhost:9092 --topic research.evidence.collected --property parse.key=true --property "key.separator=|"
Assert-LastExitCode "Kafka isolation probe publication"

$consumerGroup = "bp15-proof-" + $probeNonce.Substring(0, 12)
$previousErrorActionPreference = $ErrorActionPreference
try {
  # The console consumer reports its normal bounded timeout on stderr and exits
  # 1 after returning all available records. Keep that diagnostic from becoming
  # a PowerShell terminating error; record content is validated below.
  $ErrorActionPreference = "SilentlyContinue"
  $topicLines = @(& docker exec $KafkaContainer /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic research.evidence.collected --group $consumerGroup --from-beginning --timeout-ms 15000 --property print.key=true --property "key.separator=|" 2>$null)
  $consumerExitCode = $LASTEXITCODE
} finally {
  $ErrorActionPreference = $previousErrorActionPreference
}
if ($consumerExitCode -notin @(0, 1)) { throw "Kafka diagnostic consumer failed with exit code $consumerExitCode." }
$observedProbeCount = 0
foreach ($probe in $probeRecords) {
  $matched = @($topicLines | Where-Object { $_ -like ("*" + $probe.DocumentId + "*") })
  if ($matched.Count -ne 1) { throw "Kafka probe record was missing or duplicated." }
  $separator = $matched[0].IndexOf('|')
  if ($separator -le 0) { throw "Kafka probe key was not emitted by the diagnostic consumer." }
  $observedKey = $matched[0].Substring(0, $separator)
  $observedPayload = $matched[0].Substring($separator + 1) | ConvertFrom-Json
  if ($observedKey -ne $probe.Key -or [string]$observedPayload.tenantId -ne $probe.TenantId -or
      [string]$observedPayload.documentId -ne $probe.DocumentId) {
    throw "Kafka partition key and tenant payload are inconsistent."
  }
  $observedProbeCount++
}

$deadline = (Get-Date).AddSeconds($IndexingTimeoutSeconds)
$indexed = $false
while ((Get-Date) -lt $deadline) {
  $own0 = 0; $own1 = 0; $cross01 = 0; $cross10 = 0
  $schema0 = "tenant_" + $probeRecords[0].TenantId.Replace('-', '_')
  $schema1 = "tenant_" + $probeRecords[1].TenantId.Replace('-', '_')
  try {
    $own0 = [int](Invoke-Psql "SELECT count(*) FROM `"$schema0`".documents WHERE id = '$($probeRecords[0].DocumentId)';")
    $own1 = [int](Invoke-Psql "SELECT count(*) FROM `"$schema1`".documents WHERE id = '$($probeRecords[1].DocumentId)';")
    $cross01 = [int](Invoke-Psql "SELECT count(*) FROM `"$schema0`".documents WHERE id = '$($probeRecords[1].DocumentId)';")
    $cross10 = [int](Invoke-Psql "SELECT count(*) FROM `"$schema1`".documents WHERE id = '$($probeRecords[0].DocumentId)';")
    if ($own0 -eq 1 -and $own1 -eq 1 -and $cross01 -eq 0 -and $cross10 -eq 0) {
      $indexed = $true
      break
    }
  } catch {
    # Namespace/indexing convergence is bounded by the deadline below.
  }
  Start-Sleep -Seconds 5
}
if (-not $indexed) { throw "GraphRAG did not index the Kafka probes into isolated tenant schemas." }

# Use a sixth disposable workspace to request every workload job through the
# public edge. The caller owns none of them, so all 100 reads must fail closed
# with 404. Credentials and identifiers stay in memory and are never emitted.
$denyProbeId = [Guid]::NewGuid().ToString()
$denyProbeNonce = [Guid]::NewGuid().ToString("N")
$denyProbeUsername = "bp15deny_" + $denyProbeNonce.Substring(0, 12)
$denyProbeEmail = $denyProbeUsername + "@example.invalid"
$denyProbeTenantKey = "t_" + $denyProbeId.Replace('-', '')
$denyProbeDevice = "bp15-deny-device-" + $denyProbeNonce.Substring(0, 12)
$crossWorkspaceDenials = 0
try {
  Invoke-Psql "INSERT INTO accounts (id, username, email, password_hash, hash_algorithm, status) VALUES ('$denyProbeId', '$denyProbeUsername', '$denyProbeEmail', public.crypt('password', public.gen_salt('bf', 12)), 'BCRYPT', 'ACTIVE'); INSERT INTO account_roles (account_id, role_id) SELECT '$denyProbeId', id FROM roles WHERE name = 'USER'; INSERT INTO tenant (id, name, type, tenant_key) VALUES ('$denyProbeId', 'BP1.5 cross-workspace deny probe', 'PERSONAL', '$denyProbeTenantKey'); INSERT INTO tenant_membership (tenant_id, account_id, role) VALUES ('$denyProbeId', '$denyProbeId', 'OWNER'); INSERT INTO billing_profile (tenant_id) VALUES ('$denyProbeId');" | Out-Null
  $loginHeaders = @{ "Content-Type" = "application/json"; "X-Device-Id" = $denyProbeDevice }
  $loginBody = @{ username = $denyProbeUsername; password = "password" } | ConvertTo-Json -Compress
  $denyLogin = Invoke-RestMethod -Method Post -Uri ($BaseUrl + "/auth/login") -Headers $loginHeaders -Body $loginBody -ErrorAction Stop
  $denyToken = [string]$denyLogin.accessToken
  foreach ($jobId in $jobIds) {
    $headers = @{ Authorization = "Bearer $denyToken"; "X-Workspace-Id" = $denyProbeId }
    try {
      Invoke-RestMethod -Method Get -Uri ($BaseUrl + "/jobs/" + $jobId) -Headers $headers -ErrorAction Stop | Out-Null
      throw "Cross-workspace job lookup unexpectedly succeeded."
    } catch {
      if ($_.Exception.Message -eq "Cross-workspace job lookup unexpectedly succeeded.") { throw }
      $status = Get-StatusCode $_
      if ($status -eq 401) {
        $denyLogin = Invoke-RestMethod -Method Post -Uri ($BaseUrl + "/auth/login") -Headers $loginHeaders -Body $loginBody -ErrorAction Stop
        $denyToken = [string]$denyLogin.accessToken
        $headers.Authorization = "Bearer $denyToken"
        try {
          Invoke-RestMethod -Method Get -Uri ($BaseUrl + "/jobs/" + $jobId) -Headers $headers -ErrorAction Stop | Out-Null
          throw "Cross-workspace job lookup unexpectedly succeeded after token renewal."
        } catch {
          if ($_.Exception.Message -like "Cross-workspace job lookup unexpectedly succeeded*") { throw }
          if ((Get-StatusCode $_) -ne 404) { throw "Cross-workspace job lookup did not fail closed with 404." }
        }
      } elseif ($status -ne 404) {
        throw "Cross-workspace job lookup did not fail closed with 404."
      }
      $crossWorkspaceDenials++
    }
  }
} finally {
  Invoke-Psql "UPDATE accounts SET status = 'DISABLED', token_version = token_version + 1, updated_at = now() WHERE id = '$denyProbeId' AND status = 'ACTIVE';" | Out-Null
}
if ($crossWorkspaceDenials -ne $expectedJobCount) { throw "Cross-workspace denial count is incomplete." }

[pscustomobject]@{
  RelationalUsageRows = $jobRows.Count
  RelationalTenantCount = $accountIds.Count
  PerTenantUsageRows = $ExpectedJobsPerTenant
  TerminalDoneRows = $jobRows.Count
  CrossWorkspaceJobDenials = $crossWorkspaceDenials
  ValkeyNamespacedJobs = $recordJson.Count
  GraphRagCacheTenantCount = $matchedCacheTenants.Count
  GraphRagCacheEntries = $matchedCacheKeys
  GraphRagProvisionedTenants = $provisionedCount
  GraphRagSchemas = $namespaceCount
  GraphRagGraphs = $graphCount
  KafkaTenantKeyedProbeRecords = $observedProbeCount
  GraphRagIsolatedProbeDocuments = 2
  CrossTenantProbeDocuments = 0
  RawTenantIdentifiersInCacheKeys = 0
} | ConvertTo-Json -Compress
