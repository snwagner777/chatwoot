# Inbox2 Railway Community runtime

The fork stays on Chatwoot 4.18.0 (`9f920b549c14491a4e587687a3eed5d21c6ccc7d`). Its Docker image runs Rails and Sidekiq together in the existing Railway service. No additional worker service is required by this change.

## Source and process contract

The startup model is derived from the [official Railway Chatwoot template](https://github.com/railwayapp-templates/chatwoot/tree/20ca56b9f98e36aa2d8c6f600fda4003cd9fd0c2): wait for PostgreSQL, prepare the database, then supervise Sidekiq and Rails with `multirun`. Its MIT notice is retained in `docker/entrypoints/railway.LICENSE`.

- `railway.json` selects `docker/Dockerfile`, clears a custom start-command override, and preserves the `/api` deployment healthcheck with a 300-second timeout.
- The image command runs `docker/entrypoints/railway.sh`. It creates `storage` and `tmp/pids`, removes only a stale Rails PID file, waits for the database, and calls `db:chatwoot_prepare`. On the pinned release, that task already invokes migrations.
- `multirun` keeps both processes under one supervisor. The wrapper forwards termination signals and waits for supervisor shutdown. If either child exits, the other is stopped too; even a clean child exit ends the service nonzero, preserving the official template’s restart behavior under `ON_FAILURE`. Rails uses Railway's `PORT`, defaulting to 3000.
- The existing volume must remain mounted at `/app/storage`. The image declares that path; it does not create or replace a Railway volume. No startup step clears stored uploads.
- Readiness uses the hostname and port from `DATABASE_URL`, or the existing PostgreSQL host/port variables. A bounded wait fails closed after `DATABASE_WAIT_TIMEOUT` seconds (default 60). Neither the connection URL nor credentials are put in readiness command arguments or startup logs.
- Existing `REDIS_URL` and `SECRET_KEY_BASE` are required. Existing database and storage variables remain in Railway. No values belong in Git, Docker build arguments, documentation, or test artifacts.

## Build inputs

Ruby stays at 3.4.4 on Alpine 3.21. Node is pinned to 24.13.0 and its published multi-architecture image digest; pnpm stays at 10.2.0, Bundler at 2.5.16, and `multirun` at Alpine's 1.0.0-r2. Ruby and JavaScript dependencies use the existing lockfiles; pnpm installs with `--frozen-lockfile`. `postcss-import` is explicitly declared because `postcss.config.js` imports it directly.

The default image is Community edition: the enterprise directory is removed before production assets compile. Existing Enterprise publishing explicitly passes `CW_EDITION=ee` to preserve its upstream behavior. Runtime variables cannot restore code omitted from the Community image.

`RAILWAY_GIT_COMMIT_SHA` is accepted as non-secret build metadata for `.git_sha`; ordinary Git builds fall back to `git rev-parse HEAD`. The existing Docker build test also supplies the GitHub SHA and builds without publishing an image.

## Release checks

Before switching the existing Railway service to the reviewed GitHub branch:

1. Build the exact integrated Community image in CI. Local shell/readiness contract tests are not an image-build substitute.
2. Confirm the image contains both mail-action and UI/auth commits plus this runtime commit, and has no enterprise directory.
3. Retain the existing database, Redis, domain, volume mount, and variable references. Do not create a second paid worker service.
4. Confirm `/api` becomes healthy and both Rails and Sidekiq remain running. Check an existing attachment and a synthetic background job.
5. Test sign-in, branded inbox rendering, and synthetic-mailbox Trash/Junk actions, including a partial-failure retry. Do not exercise destructive operations against real customer mail as a smoke test.
6. Keep a known-good image/source reference for rollback. Volume-backed Railway deployments can have brief downtime; the deployment healthcheck does not continuously monitor worker health.

The implementation's no-network tests cover process ordering, failed migrations, invalid ports, bounded readiness, credential-safe readiness output, upload preservation, fail-closed supervisor exit, and shutdown-signal forwarding. An actual Docker image build and deployment must be verified separately.

References: [Railway configuration](https://docs.railway.com/config-as-code/reference), [Dockerfiles](https://docs.railway.com/builds/dockerfiles), [build metadata variables](https://docs.railway.com/variables/reference).
