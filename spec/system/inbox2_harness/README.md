# Synthetic Inbox2 browser QA

This test-only harness is never loaded by the application unless explicitly required with `INBOX2_SYNTHETIC_QA=1` and the disposable `inbox2_synthetic_qa` database. Production Docker builds remove `spec/`.

The workflow uses pinned Ruby, Node, pnpm, Playwright, PostgreSQL/pgvector and Redis inputs. It has no production secrets, uses two fictional accounts, and binds application/mail-fixture listeners to loopback. The Core session callback is a strict HMAC-verified stub; results must not be described as real Core end-to-end proof. Rails HTTP requests to non-local destinations are blocked except that stub. Jobs and ordinary mail delivery are captured in test adapters.

The browser renders the native inbox, conversation and settings for both themes, checks account isolation and session revocation, and exercises the provider-backed Trash/Junk HTTP endpoint against a real local IMAP wire-protocol fixture. A native SendReplyJob is also executed against a loopback SMTP capture, checking company sender and recipient routing. The IMAP fixture implements only commands used by those checks, not a general mail server. SMS samples demonstrate pending provider state; no real provider is contacted.

Only screenshots and a safe assertion summary are uploaded. Generated SSO links, cookies, fixture files, server logs, traces and headers are deliberately excluded. Artifacts expire after three days; the job is capped at 20 minutes.

A passing run proves only its recorded synthetic checks. Actual provider delivery, the real Core callback, native mobile builds and production smoke remain separate gates. Failed or skipped screenshots are not visual proof.
