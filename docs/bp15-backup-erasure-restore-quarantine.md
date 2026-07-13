# BP 1.5 Backup Erasure And Restore Quarantine

Immutable backups are not edited in place. BP 1.5 graduation requires restored backups to be quarantined and reconciled before any restored data can serve users.

## Required Ledger

Maintain a deletion ledger containing:

- `privacy_request_id`
- `data_subject_id`
- `tenant_id`
- affected locator IDs
- completed task IDs
- export artifact references
- processor notification IDs
- completion timestamp

## Restore Quarantine Procedure

1. Restore backup into an isolated network with no public edge.
2. Apply all migrations through the current production version.
3. Replay the deletion ledger:
   - keep erased account rows anonymized
   - keep erased locators in `ERASED`
   - suppress export artifacts past expiry
   - replay processor notifications where needed
4. Run tenant isolation checks before releasing any restored data.
5. Promote only after the quarantine report confirms no erased subject data can return to service.

## Graduation Evidence

BP 1.5 is not graduated until a pre-erasure backup is restored in quarantine and this procedure proves erased data is not served again.
