# Provider-backed email actions

This fork adds administrator-only bulk and individual email actions. No live mailbox, provider account or customer message is modified by the automated test suite.

## Contract

POST `/api/v1/accounts/:account_id/conversations/bulk_email_delete`

JSON body: `{"ids":[12,13],"mode":"trash","request_id":"<UUID>"}`

- `ids` are 1–25 unique positive conversation **display IDs**, scoped to the authenticated account
- `mode` is `trash` or `spam`; permanent purge is deliberately unsupported
- Generate `request_id` once when the reviewed confirmation opens. Freeze its selected IDs and mode. Reuse it when retrying failures or a lost response; a newly reviewed action gets a new UUID
- Response: `{"results":[{"id":12,"deleted":true},{"id":13,"error":"..."}]}`. Spam success returns `spam:true`, never `deleted:true`
- Partial failures are not successes. Preserve failed selections and the request ID. Some large batches are explicitly deferred before starting an item to stay inside the HTTP time budget; retry reconciles the original persisted snapshots
- As elsewhere in Chatwoot, insufficient account permissions produce HTTP401. Invalid inputs produce422

## Semantics and limitations

Trash moves the selected conversations' **received INBOX messages** to the provider's unique special-use Trash folder, verifies the destination, and then permanently removes the local conversation, attachments and history. Server Trash recovery is performed in the provider's mail app; this endpoint does not offer local restore.

Spam moves received INBOX messages to the unique special-use Junk folder and marks the local conversation resolved with the `spam` label, retaining its transcript and attachments. This does not promise provider spam-filter training.

Sent and archived provider copies are not affected. The action requires a native `Channel::Email` with an active IMAP connection, the MOVE capability and a unique provider-advertised destination. Unsupported inboxes, capabilities, folders and ambiguous/missing Message-IDs fail visibly. There is no fallback to broad EXPUNGE or permanent deletion. Provider attempts and batches are time-bounded; very large individual threads can require retries or an explicit later background-operation design.

Legacy `DELETE /conversations/:id` rejects email conversations with a422 directing callers to the provider-backed action. Non-email deletion and internal cleanup/account-deletion jobs retain their existing behavior. Older mobile/third-party clients must handle this error and use the new action; otherwise they cannot claim provider synchronization.

## Integrity

`email_action_receipts` persists original message membership, provider IDs/locations, per-message confirmations and final outcomes outside the deletable conversation aggregate. Completed receipts allow replay after a response was lost and the conversation no longer exists. All receipts are account scoped. Apply migration `20261001160000_create_email_action_receipts` before enabling these controls.

Stored IMAP UIDs are used only with matching UIDVALIDITY and an exact parsed Message-ID. Older messages are resolved using exact header verification at action time. Every newly moved message is checked in the destination. A retry skips previously confirmed receipt members and reconciles only unfinished members already in the destination, allowing monotonic progress within the request budget. Do not manually move messages between folders while an action is in progress.

Email inserts acquire a fresh row lock on the existing parent conversation. Both production bulk-import insert paths, which bypass callbacks, participate in the same lock. Provider-backed cleanup holds that lock, verifies original message membership and invokes local cleanup synchronously. A newly saved reply changes the snapshot and retains the conversation; a racing append after removal fails visibly before insertion instead of being silently discarded. Lock acquisition for actions is nonblocking so an already busy thread is retained for retry. Internal cleanup jobs outside this endpoint retain their existing semantics.

## Verification and rollout gate

Automated coverage includes exact UID and UIDVALIDITY checks, destination confirmation, no permanent purge, partial outcomes, response-lost replay, account isolation, original membership on retries, retained spam history, legacy-route rejection, frozen UI selection, double-submit protection and real PostgreSQL incoming/outgoing insertion races.

Before release, use a synthetic mailbox on the actual configured provider to verify its special-use folders and MOVE behavior, then test the integrated web/mobile UI. Do not point smoke tests at live customer mail. Review the migration and retention of operation receipts. Merge/deployment is a separate release gate.
