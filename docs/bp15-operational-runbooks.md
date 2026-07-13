# BP 1.5 Operational Runbooks

These runbooks are required before BP 1.5 can be marked graduated.

## Reconciliation Recovery

1. Query `account.usage_reconciliation_outbox` for `FAILED` or stale `PENDING` rows.
2. Correlate by `tenant_id`, `billing_account_id`, `request_uid`, and `job_id`.
3. Replay one row at a time through the reconciliation service path.
4. Confirm idempotent provider-call keys prevent duplicate charge records.
5. Record the operator, reason, and final status without logging prompt or answer content.

## RLS Denial Triage

1. Confirm the gateway minted an internal JWT with `tenant_id`, `actor_account_id`, and `data_subject_id`.
2. Confirm the service set `app.current_tenant_id` and `app.current_actor_account_id`.
3. Check whether the target row belongs to the active tenant.
4. Do not disable RLS for recovery. Use a time-boxed break-glass database role only with an incident record.

## GraphRAG Auth And Provisioning

1. Verify GraphRAG requests include valid internal JWT metadata.
2. Reject missing, expired, or tenant-mismatched metadata.
3. Check `account.tenant_provisioning` for the tenant's `GRAPHRAG` row.
4. Re-run provisioning only for the affected tenant.

## Privacy Task Recovery

1. Query `account.erasure_task` for `FAILED_RETRYABLE`, `FAILED_TERMINAL`, or expired `LEASED` rows.
2. Validate active legal holds before replaying destructive operations.
3. Retry only idempotent handlers.
4. For remote stores, verify `processor_register` notification status before resending.
5. Do not delete privacy requests, locators, receipts, or legal holds during recovery.

## Legal Holds

1. Confirm the hold scope and reason.
2. Verify destructive privacy tasks are marked `BLOCKED`.
3. Allow access export and non-destructive correction review unless policy says otherwise.
4. Include retained-by-law details in the receipt.

## Emergency Admission Bypass

1. Bypass can apply only to usage admission.
2. It must not bypass membership checks, gateway tenant resolution, RLS, GraphRAG namespace auth, or privacy legal holds.
3. Require explicit expiry and operator identity.
4. Reconcile all bypassed requests after the incident.
