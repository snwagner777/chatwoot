# EPS native notification delivery

This is a content-free bridge to the existing EconomyOps Field native push path.
It is disabled by default. Set `EPS_NATIVE_NOTIFICATIONS_ENABLED=true` only after
the matching Core `INBOX2_MESSAGE` category, dispatcher, membership validation,
Field routing, and physical device checks have passed the release gate.
The Core global/category rollout switches remain separately authoritative.

After a native Chatwoot `Notification` commits, a job containing only its numeric
ID is queued. Before every delivery or retry it reloads the notification and
checks the flag, unread/unsnoozed state, current account membership, conversation
access, push preference, EPS identity binding, and PlatformApp access to both
account and user. No EPS web session is required for native delivery.

The job posts an empty body to the configured HTTPS `EPS_CORE_ORIGIN` at
`/api/v1/core/internal/inbox2/notifications`. No redirects are followed. Headers:

- `x-eps-bridge-payload`: unpadded base64url JSON
- `x-eps-bridge-signature`: lowercase hex HMAC-SHA256 over that payload, using
  the already-associated PlatformApp access token
- `content-type: text/plain; charset=utf-8` with an empty body. Ruby's default
  form content type is unsupported by Core; an empty JSON body is also invalid.

The only claims are `purpose: "notification"`, integer Unix `timestamp`, and
positive integer `accountId`, `chatwootUserId`, `conversationId` (the account-local
display ID), and `notificationId`. Customer names, content, attachments, emails,
and access tokens are never included in the notification payload.

Core must enforce the configured account, strict schema, signature, freshness,
current EPS/module/native entitlement, current Chatwoot conversation access, and
durable event deduplication keyed by account plus notification ID. It must also
repeat permission checks before provider dispatch; hook admission is not lasting
permission to notify. Field reauthorizes the destination when the alert is opened.

Temporary network errors, 429s, and 5xx responses receive up to five job attempts
with fresh signatures. Other responses, including redirects and permission
rejections, are terminal. The response body is discarded with a 4 KiB limit.
Turning the fork flag off blocks both newly queued and previously queued jobs.
No deployment, real notification, credential change, or device enablement is
performed by this code-only draft.
