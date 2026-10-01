// Runs only against the disposable CI fixture. Artifacts never include auth state.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const { assetPath, errorSummary } = require('./diagnostics.cjs');
const { chromium } = require(process.env.INBOX2_PLAYWRIGHT_PATH);
const root = process.env.INBOX2_QA_TMP_DIR;
assert.equal(process.env.INBOX2_SYNTHETIC_QA, '1');
const fixtures = JSON.parse(fs.readFileSync(`${root}/fixtures.json`));
const report = {
  synthetic: true,
  coreCallback: 'HMAC-verified synthetic stub; not real Core E2E',
  checks: [],
  pageErrors: [],
  consoleErrors: [],
  assetResponses: [],
  failedAssets: [],
  stage: 'launch',
};
const record = name => report.checks.push({ name, passed: true });
const api = (page, url, method = 'get', data) =>
  page.evaluate(
    async args => {
      try {
        const response = await window.axios(args);
        return { status: response.status, data: response.data };
      } catch (error) {
        return {
          status: error.response?.status || 0,
          data: error.response?.data,
        };
      }
    },
    { url, method, data }
  );
const bounded = (entries, entry) => {
  if (entries.length < 100) entries.push(entry);
};
(async () => {
  const browser = await chromium.launch({ headless: true });
  let lastPage;
  try {
    for (const [index, user] of [
      fixtures.users[0],
      fixtures.users[2],
    ].entries()) {
      const context = await browser.newContext({
        viewport: { width: 1440, height: 960 },
      });
      await context.route('**/*', route => {
        const url = new URL(route.request().url());
        if (['127.0.0.1', 'localhost'].includes(url.hostname))
          return route.continue();
        return route.abort();
      });
      const page = await context.newPage();
      lastPage = page;
      page.on('pageerror', error =>
        bounded(report.pageErrors, errorSummary(error))
      );
      page.on('console', message => {
        if (message.type() === 'error')
          bounded(report.consoleErrors, {
            ...errorSummary({ message: message.text() }),
            asset: assetPath(message.location().url),
          });
      });
      page.on('response', response => {
        const asset = assetPath(response.url());
        if (
          asset &&
          ['script', 'stylesheet'].includes(
            response.request().resourceType()
          ) &&
          (response.status() >= 400 ||
            /\/entrypoints\/|\/@vite\/client/.test(asset))
        )
          bounded(report.assetResponses, { asset, status: response.status() });
      });
      page.on('requestfailed', request => {
        const asset = assetPath(request.url());
        if (asset)
          bounded(report.failedAssets, {
            asset,
            ...errorSummary({ message: request.failure()?.errorText }),
          });
      });
      report.stage = `account-${index + 1}-anonymous-app-render`;
      await page.goto('http://127.0.0.1:4310/app/login', {
        waitUntil: 'domcontentloaded',
        timeout: 120000,
      });
      await page.getByTestId('email_input').waitFor({
        state: 'visible',
        timeout: 120000,
      });
      record(`Account ${index + 1} application renders before SSO`);
      report.stage = `account-${index + 1}-sso`;

      await page.goto(user.url, {
        waitUntil: 'domcontentloaded',
        timeout: 120000,
      });
      await page.waitForURL(`**/accounts/${user.account_id}/**`, {
        timeout: 120000,
      });
      await page
        .getByText(`Synthetic Customer ${index + 1}-1`, { exact: false })
        .first()
        .waitFor({ timeout: 90000 });
      assert.equal(
        await page.locator('html').getAttribute('data-operator-theme'),
        index === 0 ? 'economyops' : 'neutral'
      );
      record(
        `Account ${index + 1} SSO, populated native inbox and scoped theme`
      );
      await page.screenshot({
        path: `${root}/artifacts/synthetic-account-${index + 1}-inbox.png`,
      });
      await page
        .getByText(`Synthetic Customer ${index + 1}-1`, { exact: false })
        .first()
        .click();
      await page
        .getByText('Synthetic QA only:', { exact: false })
        .first()
        .waitFor();
      await page.screenshot({
        path: `${root}/artifacts/synthetic-account-${index + 1}-conversation.png`,
      });
      if (index === 0) {
        await page.setViewportSize({ width: 390, height: 844 });
        await page.screenshot({
          path: `${root}/artifacts/synthetic-mobile-web-conversation.png`,
        });
        await page.setViewportSize({ width: 1440, height: 960 });
      }
      await page
        .getByText(`Synthetic SMS Customer ${index + 1}`, { exact: false })
        .first()
        .click();
      await page
        .getByText('Synthetic reply awaiting provider confirmation', {
          exact: false,
        })
        .first()
        .waitFor();
      const messages = await api(
        page,
        `/api/v1/accounts/${user.account_id}/conversations/${fixtures.accounts[index].sms_id}/messages`
      );
      assert.equal(messages.status, 200);
      assert.ok(
        messages.data.payload.some(message => message.status === 'pending')
      );
      const pending = messages.data.payload.find(
        message => message.status === 'pending'
      );
      const forged = await api(
        page,
        `/api/v1/accounts/${user.account_id}/conversations/${fixtures.accounts[index].sms_id}/messages/${pending.id}`,
        'patch',
        { status: 'delivered' }
      );
      assert.equal(forged.status, 403);
      record(`Account ${index + 1} browser cannot forge provider delivery`);

      await page.screenshot({
        path: `${root}/artifacts/synthetic-account-${index + 1}-pending-provider.png`,
      });
      record(
        `Account ${index + 1} renders unconfirmed provider reply as pending`
      );
      await page.goto(
        `http://127.0.0.1:4310/app/accounts/${user.account_id}/settings/general`
      );
      await page
        .getByText(/General settings/i, { exact: false })
        .first()
        .waitFor({ timeout: 30000 });
      await page.screenshot({
        path: `${root}/artifacts/synthetic-account-${index + 1}-settings.png`,
      });
      record(`Account ${index + 1} native settings renders`);
      const other = fixtures.accounts[index === 0 ? 1 : 0].id;
      const denied = await api(page, `/api/v1/accounts/${other}`);
      assert.ok([401, 403, 404].includes(denied.status));
      record(`Account ${index + 1} cannot access other account`);
      if (index === 0) {
        const ids = fixtures.accounts[0].email_ids;
        const legacy = await api(
          page,
          `/api/v1/accounts/${user.account_id}/conversations/${ids[0]}`,
          'delete'
        );
        assert.equal(legacy.status, 422);
        const request = {
          ids: ids.slice(0, 2),
          mode: 'trash',
          request_id: require('node:crypto').randomUUID(),
        };
        const endpoint = `/api/v1/accounts/${user.account_id}/conversations/bulk_email_delete`;
        const trash = await api(page, endpoint, 'post', request);
        assert.equal(trash.status, 200);
        assert.ok(trash.data.results.every(result => result.deleted));
        assert.deepEqual(
          (await api(page, endpoint, 'post', request)).data.results,
          trash.data.results
        );
        const spam = await api(page, endpoint, 'post', {
          ids: [ids[2]],
          mode: 'spam',
          request_id: require('node:crypto').randomUUID(),
        });
        assert.equal(spam.status, 200);
        assert.equal(spam.data.results[0].spam, true);
        const kept = await api(
          page,
          `/api/v1/accounts/${user.account_id}/conversations/${ids[2]}`
        );
        assert.equal(kept.status, 200);
        assert.equal(kept.data.status, 'resolved');
        const provider = JSON.parse(
          fs.readFileSync(`${root}/provider-state.json`)
        );
        assert.equal(Object.keys(provider.Trash).length, 2);
        assert.equal(Object.keys(provider.Junk).length, 1);
        record(
          'Generic IMAP wire protocol bulk Trash, durable retry, retained Junk thread, legacy guard'
        );
      }
      fs.writeFileSync(
        `${root}/revoked.json`,
        JSON.stringify([user.core_user_id])
      );
      assert.equal(
        (await api(page, `/api/v1/accounts/${user.account_id}`)).status,
        401
      );
      record(
        `Account ${index + 1} Core session revocation blocks the next request`
      );
      fs.writeFileSync(`${root}/revoked.json`, '[]');
      await context.close();
    }
    report.stage = 'runtime-error-check';
    assert.deepEqual(report.pageErrors, []);
  } catch (error) {
    report.failure = errorSummary(error);
    if (lastPage && !lastPage.isClosed())
      await lastPage
        .screenshot({ path: `${root}/artifacts/synthetic-failure.png` })
        .catch(() => {});
    process.exitCode = 1;
  } finally {
    await browser.close();
    fs.writeFileSync(
      `${root}/artifacts/result.json`,
      JSON.stringify(report, null, 2)
    );
  }
})();
