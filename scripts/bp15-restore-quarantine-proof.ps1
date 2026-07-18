param(
  [string]$SourcePostgresContainer = "llm-council-standard-postgres-1",
  [string]$QuarantineImage = "local/llm-council/postgres-age:local",
  [ValidateRange(10, 300)][int]$StartupTimeoutSeconds = 120
)

$ErrorActionPreference = "Stop"

# This rehearsal creates one disposable subject in the local source database,
# takes a pre-erasure account-schema backup, and restores it into a container
# with Docker network mode "none". Only aggregate, non-identifying evidence is
# emitted. The dump, quarantine database, and credentials are always removed.
$nonce = [Guid]::NewGuid().ToString("N")
$subjectId = [Guid]::NewGuid().ToString()
$tenantId = $subjectId
$exportRequestId = [Guid]::NewGuid().ToString()
$deletionRequestId = [Guid]::NewGuid().ToString()
$accountLocatorId = [Guid]::NewGuid().ToString()
$remoteLocatorId = [Guid]::NewGuid().ToString()
$accountTaskId = [Guid]::NewGuid().ToString()
$remoteTaskId = [Guid]::NewGuid().ToString()
$processorNotificationId = [Guid]::NewGuid().ToString()
$tenantKey = "t_" + $tenantId.Replace("-", "")
$username = "bp15restore_" + $nonce.Substring(0, 12)
$email = $username + "@example.invalid"
$artifactRef = "privacy-export:" + $exportRequestId
$completionTimestamp = [DateTimeOffset]::UtcNow.ToString("o")
$sourceDump = "/tmp/bp15-pre-erasure-" + $nonce + ".dump"
$hostDump = Join-Path ([IO.Path]::GetTempPath()) ("bp15-pre-erasure-" + $nonce + ".dump")
$quarantineContainer = "bp15-quarantine-" + $nonce.Substring(0, 12)
$quarantineDatabase = "bp15_quarantine"
$quarantinePassword = "bp15-" + [Guid]::NewGuid().ToString("N")
$sourceDatabase = $null
$sourceUser = $null
$quarantineStarted = $false

function Assert-LastExitCode([string]$Operation) {
  if ($LASTEXITCODE -ne 0) {
    throw "$Operation failed with exit code $LASTEXITCODE."
  }
}

function Invoke-SourceSql([string]$Sql) {
  & docker exec $SourcePostgresContainer psql -U $script:sourceUser -d $script:sourceDatabase -v ON_ERROR_STOP=1 -qAt -c ("SET search_path TO account; " + $Sql)
  Assert-LastExitCode "Source Postgres query"
}

function Invoke-QuarantineSql([string]$Sql) {
  & docker exec $script:quarantineContainer psql -U postgres -d $script:quarantineDatabase -v ON_ERROR_STOP=1 -qAt -c ("SET search_path TO account; " + $Sql)
  Assert-LastExitCode "Quarantine Postgres query"
}

try {
  $sourceDatabase = (& docker exec $SourcePostgresContainer printenv POSTGRES_DB).Trim()
  Assert-LastExitCode "Source database discovery"
  $sourceUser = (& docker exec $SourcePostgresContainer printenv POSTGRES_USER).Trim()
  Assert-LastExitCode "Source database user discovery"
  if ([string]::IsNullOrWhiteSpace($sourceDatabase) -or [string]::IsNullOrWhiteSpace($sourceUser)) {
    throw "Source Postgres database contract is incomplete."
  }

  $fixtureSql = @"
INSERT INTO accounts (id, username, email, password_hash, hash_algorithm, status)
VALUES ('$subjectId', '$username', '$email', 'privacy-erased', 'BCRYPT', 'ACTIVE');
INSERT INTO tenant (id, name, type, tenant_key)
VALUES ('$tenantId', 'BP1.5 restore quarantine subject', 'PERSONAL', '$tenantKey');
INSERT INTO tenant_membership (tenant_id, account_id, role)
VALUES ('$tenantId', '$subjectId', 'OWNER');
INSERT INTO billing_profile (tenant_id) VALUES ('$tenantId');
INSERT INTO privacy_subject (data_subject_id, email)
VALUES ('$subjectId', '$email');
INSERT INTO personal_data_locator
  (id, tenant_id, data_subject_id, store_type, object_reference,
   classification, retention_basis, erase_strategy, legal_basis,
   deletion_state, processor_reference, policy_rules_status, key_ref,
   handler_version, idempotency_key)
VALUES
  ('$accountLocatorId', '$tenantId', '$subjectId', 'ACCOUNT',
   'accounts:$subjectId', 'PERSONAL', 'DISPOSABLE_TEST', 'ANONYMIZE',
   'CONSENT', 'ACTIVE', 'account-service', 'APPROVED',
   'account:$subjectId', 'privacy-p1.v1', 'ACCOUNT:accounts:$subjectId'),
  ('$remoteLocatorId', '$tenantId', '$subjectId', 'OBJECT_STORE',
   'exports/$subjectId.json', 'PERSONAL', 'DISPOSABLE_TEST', 'DELETE',
   'CONSENT', 'ACTIVE', 'object-store', 'APPROVED',
   'object:$subjectId', 'privacy-p1.v1', 'OBJECT_STORE:exports/$subjectId.json');
INSERT INTO privacy_request (id, data_subject_id, request_type, status)
VALUES ('$exportRequestId', '$subjectId', 'ACCESS', 'COMPLETED');
INSERT INTO privacy_export_artifact
  (privacy_request_id, data_subject_id, artifact_ref, filename,
   content_type, content, expires_at)
VALUES
  ('$exportRequestId', '$subjectId', '$artifactRef',
   'bp15-restore-export.json', 'application/json',
   convert_to('{"disposable":true}', 'UTF8'), now() + interval '7 days');
"@
  Invoke-SourceSql $fixtureSql | Out-Null

  & docker exec $SourcePostgresContainer pg_dump -U $sourceUser -d $sourceDatabase --format=custom --schema=account --file=$sourceDump
  Assert-LastExitCode "Pre-erasure backup"
  & docker cp ("${SourcePostgresContainer}:" + $sourceDump) $hostDump
  Assert-LastExitCode "Copy pre-erasure backup"
  if (-not (Test-Path -LiteralPath $hostDump) -or (Get-Item -LiteralPath $hostDump).Length -le 0) {
    throw "Pre-erasure backup artifact is empty."
  }

  $liveErasureSql = @"
INSERT INTO privacy_request (id, data_subject_id, request_type, status, updated_at)
VALUES ('$deletionRequestId', '$subjectId', 'DELETE', 'COMPLETED', '$completionTimestamp');
INSERT INTO erasure_task
  (id, privacy_request_id, store_type, locator_id, status, operation,
   handler_version, idempotency_key, updated_at)
VALUES
  ('$accountTaskId', '$deletionRequestId', 'ACCOUNT', '$accountLocatorId',
   'COMPLETED', 'DELETE', 'privacy-p1.v1',
   '${deletionRequestId}:${accountLocatorId}:DELETE:privacy-p1.v1', '$completionTimestamp'),
  ('$remoteTaskId', '$deletionRequestId', 'OBJECT_STORE', '$remoteLocatorId',
   'COMPLETED', 'DELETE', 'privacy-p1.v1',
   '${deletionRequestId}:${remoteLocatorId}:DELETE:privacy-p1.v1', '$completionTimestamp');
UPDATE accounts
SET username = 'deleted-$subjectId',
    email = 'deleted-$subjectId@privacy.local',
    password_hash = 'privacy-erased',
    status = 'DISABLED',
    token_version = token_version + 1,
    deleted_at = '$completionTimestamp',
    updated_at = '$completionTimestamp'
WHERE id = '$subjectId';
UPDATE personal_data_locator
SET deletion_state = 'ERASED', policy_rules_status = 'COMPLETED'
WHERE id IN ('$accountLocatorId', '$remoteLocatorId');
UPDATE privacy_export_artifact
SET expires_at = '$completionTimestamp'::timestamptz - interval '1 second'
WHERE artifact_ref = '$artifactRef';
INSERT INTO processor_register
  (id, processor_name, data_shared_details, erasure_receipt_id,
   erasure_status, created_at, updated_at)
VALUES
  ('$processorNotificationId', 'object-store', 'OBJECT_STORE:disposable',
   '$deletionRequestId', 'COMPLETED', '$completionTimestamp', '$completionTimestamp');
"@
  Invoke-SourceSql $liveErasureSql | Out-Null

  # The ledger remains in memory and is intentionally not emitted. It contains
  # every field required by the BP1.5 restore-quarantine contract.
  $ledger = [pscustomobject]@{
    PrivacyRequestId = $deletionRequestId
    DataSubjectId = $subjectId
    TenantId = $tenantId
    LocatorIds = @($accountLocatorId, $remoteLocatorId)
    CompletedTaskIds = @($accountTaskId, $remoteTaskId)
    ExportArtifactReferences = @($artifactRef)
    ProcessorNotificationIds = @($processorNotificationId)
    CompletionTimestamp = $completionTimestamp
  }
  $ledgerFieldsPresent = -not [string]::IsNullOrWhiteSpace($ledger.PrivacyRequestId) -and
    -not [string]::IsNullOrWhiteSpace($ledger.DataSubjectId) -and
    -not [string]::IsNullOrWhiteSpace($ledger.TenantId) -and
    $ledger.LocatorIds.Count -eq 2 -and $ledger.CompletedTaskIds.Count -eq 2 -and
    $ledger.ExportArtifactReferences.Count -eq 1 -and
    $ledger.ProcessorNotificationIds.Count -eq 1 -and
    -not [string]::IsNullOrWhiteSpace($ledger.CompletionTimestamp)
  if (-not $ledgerFieldsPresent) { throw "Deletion ledger is incomplete." }

  $containerId = (& docker run -d --name $quarantineContainer --network none `
    -e "POSTGRES_USER=postgres" `
    -e "POSTGRES_PASSWORD=$quarantinePassword" `
    -e "POSTGRES_DB=$quarantineDatabase" `
    $QuarantineImage).Trim()
  Assert-LastExitCode "Start quarantine Postgres"
  if ([string]::IsNullOrWhiteSpace($containerId)) { throw "Quarantine container did not start." }
  $quarantineStarted = $true

  $deadline = (Get-Date).AddSeconds($StartupTimeoutSeconds)
  $ready = $false
  while ((Get-Date) -lt $deadline) {
    & docker exec $quarantineContainer pg_isready -U postgres -d $quarantineDatabase | Out-Null
    if ($LASTEXITCODE -eq 0) { $ready = $true; break }
    Start-Sleep -Seconds 2
  }
  if (-not $ready) { throw "Quarantine Postgres did not become ready." }

  $networkMode = (& docker inspect --format '{{.HostConfig.NetworkMode}}' $quarantineContainer).Trim()
  Assert-LastExitCode "Inspect quarantine network mode"
  if ($networkMode -ne "none") { throw "Quarantine container is not network isolated." }

  & docker cp $hostDump ("${quarantineContainer}:/tmp/restore.dump")
  Assert-LastExitCode "Copy backup into quarantine"
  & docker exec $quarantineContainer psql -U postgres -d $quarantineDatabase -v ON_ERROR_STOP=1 -c "CREATE EXTENSION IF NOT EXISTS pgcrypto; CREATE SCHEMA IF NOT EXISTS account;" | Out-Null
  Assert-LastExitCode "Prepare quarantine extensions"
  $previousErrorActionPreference = $ErrorActionPreference
  try {
    # Capture pg_restore diagnostics so a schema-level failure does not emit
    # restored definitions or fixture contents into the evidence stream.
    $ErrorActionPreference = "SilentlyContinue"
    $restoreOutput = @(& docker exec $quarantineContainer pg_restore -U postgres -d $quarantineDatabase --no-owner --no-privileges --schema=account /tmp/restore.dump 2>&1)
    $restoreExitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousErrorActionPreference
  }
  if ($restoreExitCode -ne 0) {
    throw "Restore account schema into quarantine failed with exit code $restoreExitCode and $($restoreOutput.Count) diagnostic lines."
  }

  $preReplayState = @(Invoke-QuarantineSql "SELECT (SELECT count(*) FROM accounts WHERE id = '$subjectId' AND deleted_at IS NULL), (SELECT count(*) FROM personal_data_locator WHERE data_subject_id = '$subjectId' AND deletion_state = 'ACTIVE'), (SELECT count(*) FROM privacy_export_artifact WHERE artifact_ref = '$artifactRef' AND expires_at > now());")
  if ($preReplayState.Count -ne 1 -or $preReplayState[0] -ne "1|2|1") {
    throw "Pre-erasure state was not restored into quarantine as expected."
  }

  $replaySql = @"
INSERT INTO privacy_request (id, data_subject_id, request_type, status, updated_at)
VALUES ('$($ledger.PrivacyRequestId)', '$($ledger.DataSubjectId)', 'DELETE',
        'COMPLETED', '$($ledger.CompletionTimestamp)')
ON CONFLICT (id) DO UPDATE
SET status = EXCLUDED.status, updated_at = EXCLUDED.updated_at;
UPDATE accounts
SET username = 'deleted-$($ledger.DataSubjectId)',
    email = 'deleted-$($ledger.DataSubjectId)@privacy.local',
    password_hash = 'privacy-erased',
    status = 'DISABLED',
    token_version = token_version + 1,
    deleted_at = '$($ledger.CompletionTimestamp)',
    updated_at = '$($ledger.CompletionTimestamp)'
WHERE id = '$($ledger.DataSubjectId)';
UPDATE personal_data_locator
SET deletion_state = 'ERASED', policy_rules_status = 'COMPLETED'
WHERE id IN ('$($ledger.LocatorIds[0])', '$($ledger.LocatorIds[1])');
UPDATE privacy_export_artifact
SET expires_at = '$($ledger.CompletionTimestamp)'::timestamptz - interval '1 second'
WHERE artifact_ref = '$($ledger.ExportArtifactReferences[0])';
INSERT INTO erasure_task
  (id, privacy_request_id, store_type, locator_id, status, operation,
   handler_version, idempotency_key, updated_at)
VALUES
  ('$($ledger.CompletedTaskIds[0])', '$($ledger.PrivacyRequestId)', 'ACCOUNT',
   '$($ledger.LocatorIds[0])', 'COMPLETED', 'DELETE', 'privacy-p1.v1',
   '$($ledger.PrivacyRequestId):$($ledger.LocatorIds[0]):DELETE:privacy-p1.v1',
   '$($ledger.CompletionTimestamp)'),
  ('$($ledger.CompletedTaskIds[1])', '$($ledger.PrivacyRequestId)', 'OBJECT_STORE',
   '$($ledger.LocatorIds[1])', 'COMPLETED', 'DELETE', 'privacy-p1.v1',
   '$($ledger.PrivacyRequestId):$($ledger.LocatorIds[1]):DELETE:privacy-p1.v1',
   '$($ledger.CompletionTimestamp)')
ON CONFLICT (id) DO UPDATE SET status = 'COMPLETED', updated_at = EXCLUDED.updated_at;
INSERT INTO processor_register
  (id, processor_name, data_shared_details, erasure_receipt_id,
   erasure_status, created_at, updated_at)
VALUES
  ('$($ledger.ProcessorNotificationIds[0])', 'object-store',
   'OBJECT_STORE:disposable', '$($ledger.PrivacyRequestId)', 'COMPLETED',
   '$($ledger.CompletionTimestamp)', '$($ledger.CompletionTimestamp)')
ON CONFLICT (id) DO UPDATE
SET erasure_status = 'COMPLETED', updated_at = EXCLUDED.updated_at;
"@
  Invoke-QuarantineSql $replaySql | Out-Null

  $postReplayState = @(Invoke-QuarantineSql "SELECT (SELECT count(*) FROM accounts WHERE id = '$subjectId' AND deleted_at IS NOT NULL AND status = 'DISABLED' AND username = 'deleted-$subjectId'), (SELECT count(*) FROM personal_data_locator WHERE data_subject_id = '$subjectId' AND deletion_state = 'ERASED'), (SELECT count(*) FROM privacy_export_artifact WHERE artifact_ref = '$artifactRef' AND expires_at <= now()), (SELECT count(*) FROM erasure_task WHERE privacy_request_id = '$deletionRequestId' AND status = 'COMPLETED'), (SELECT count(*) FROM processor_register WHERE id = '$processorNotificationId' AND erasure_receipt_id = '$deletionRequestId' AND erasure_status = 'COMPLETED'), (SELECT count(*) FROM tenant_membership WHERE account_id = '$subjectId' AND tenant_id <> '$tenantId');")
  if ($postReplayState.Count -ne 1 -or $postReplayState[0] -ne "1|2|1|2|1|0") {
    throw "Deletion-ledger replay did not preserve every quarantine invariant."
  }

  [pscustomobject]@{
    PreErasureBackupPresent = $true
    QuarantineNetworkMode = $networkMode
    LedgerFieldsPresent = $ledgerFieldsPresent
    RestoredActiveAccountBeforeReplay = $true
    RestoredActiveLocatorsBeforeReplay = 2
    AccountErasedAfterReplay = $true
    LocatorsErasedAfterReplay = 2
    ExportArtifactSuppressedAfterReplay = $true
    CompletedTasksReplayed = 2
    ProcessorNotificationsReplayed = 1
    CrossTenantMembershipsAfterReplay = 0
  } | ConvertTo-Json -Compress
} finally {
  if ($quarantineStarted) {
    & docker rm -f $quarantineContainer | Out-Null
  }
  if ($SourcePostgresContainer -and $sourceDump) {
    & docker exec $SourcePostgresContainer rm -f $sourceDump 2>$null
  }
  Remove-Item -LiteralPath $hostDump -Force -ErrorAction SilentlyContinue
}
