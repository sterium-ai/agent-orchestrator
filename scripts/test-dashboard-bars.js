// Node built-ins only (fs, vm, path). Extracts the inline <script> from
// docs/dashboard/index.html, evaluates it in a stubbed browser-ish context,
// and exercises renderQuotaBar()/provider() against scripts/test-fixtures/dashboard-sample.json.
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const htmlPath = path.join(__dirname, '..', 'docs', 'dashboard', 'index.html');
const fixturePath = path.join(__dirname, 'test-fixtures', 'dashboard-sample.json');

const html = fs.readFileSync(htmlPath, 'utf8');
const scriptMatch = html.match(/<script>([\s\S]*?)<\/script>/);
if (!scriptMatch) {
  console.error('FAIL: could not find an inline <script> block in docs/dashboard/index.html');
  process.exit(1);
}
const scriptBody = scriptMatch[1];

const fixture = JSON.parse(fs.readFileSync(fixturePath, 'utf8'));

// renderQuotaBar shows a window whose reset time has already passed as reset with a 0 %
// bar, which is right on the page and fatal in a fixture: the sample's fixed 2026-09 reset dates
// made these checks pass until that date and fail every day after. Push every already-passed
// reset into the future, keeping each window's order, so the checks always exercise live windows.
{
  const now = Date.now();
  let n = 0;
  for (const prov of Object.values(fixture.providers || {})) {
    for (const q of prov.quotas || []) {
      if (!q.resetsAt || new Date(q.resetsAt).getTime() <= now) q.resetsAt = new Date(now + ++n * 3 * 3600000).toISOString();
    }
  }
}

const elements = {};
function fakeElement() {
  return { innerHTML: '', textContent: '', href: '', hidden: false, style: {}, querySelector: () => fakeElement() };
}
const document = {
  getElementById(id) {
    if (!elements[id]) elements[id] = fakeElement();
    return elements[id];
  },
};
const fetchStub = () => Promise.reject(new Error('network disabled in test harness'));
const sandbox = {
  console,
  document,
  fetch: fetchStub,
  setInterval: () => 0,
  clearInterval: () => {},
  setTimeout: () => 0,
  clearTimeout: () => {},
};
const context = vm.createContext(sandbox);
vm.runInContext(scriptBody, context, { filename: 'dashboard-index-inline-script.js' });

// Top-level `const`/`function` bindings in the script live in the context's
// lexical scope, not as properties of the context object — pull the ones we
// need out via a follow-up script run against the same context.
const bridge = vm.runInContext(
  '(function () { return { renderQuotaBar, provider, renderLessons, escapeHtml, fmtTime, fmtTok, USAGE_LINKS, groupSharedAccounts, freshestReadingByAccount }; })()',
  context
);

let failures = 0;
function check(name, condition, detail) {
  if (condition) {
    console.log(`PASS: ${name}`);
  } else {
    failures++;
    console.log(`FAIL: ${name}${detail ? ` — ${detail}` : ''}`);
  }
}

// Case 1: codex-shaped provider with two normal quota bars.
{
  const p = fixture.providers.codex;
  const u = fixture.usage.codex;
  try {
    bridge.provider('codex', p, u);
    const html = elements['prov-codex'].innerHTML;
    const resets = p.quotas.map((q) => bridge.fmtTime(q.resetsAt));
    const ok =
      html.includes('25') &&
      html.includes('60') &&
      html.includes('resets') &&
      resets.every((r) => html.includes(r)) &&
      (html.match(/resets /g) || []).length === 2;
    check('two-bars: output contains both usedPercent values and both reset times', ok, html);
  } catch (e) {
    check('two-bars: output contains both usedPercent values and both reset times', false, e.message);
  }
}

// Case 2: copilot-shaped provider with one bar plus noPremiumRequests true.
{
  const p = fixture.providers.copilot;
  const u = fixture.usage.copilot;
  try {
    bridge.provider('copilot', p, u);
    const html = elements['prov-copilot'].innerHTML;
    const ok = html.includes('This plan includes no premium requests.') && html.includes('10');
    check('no-premium-requests: output contains the no-premium-requests sentence', ok, html);
  } catch (e) {
    check('no-premium-requests: output contains the no-premium-requests sentence', false, e.message);
  }
}

// Case 3: claude-shaped provider with empty quotas array and null plan -> "no official figure" fallback.
{
  const p = fixture.providers.claude;
  const u = fixture.usage.claude;
  try {
    bridge.provider('claude', p, u);
    const html = elements['prov-claude'].innerHTML;
    const ok = html.includes('no official figure') && html.includes(bridge.USAGE_LINKS.claude);
    check('no-official-figure: output contains fallback text and correct USAGE_LINKS URL', ok, html);
  } catch (e) {
    check('no-official-figure: output contains fallback text and correct USAGE_LINKS URL', false, e.message);
  }
}

// Case 4: provider object with the quotas key entirely absent (backward-compat).
{
  const p = fixture.legacyProvider;
  const u = fixture.legacyUsage;
  let threw = false;
  try {
    bridge.provider('legacy', p, u);
  } catch (e) {
    threw = true;
    check('missing-quotas-key: renders without throwing', false, e.message);
  }
  if (!threw) check('missing-quotas-key: renders without throwing', true);
}

// Direct unit check of renderQuotaBar(q) in isolation (no DOM lookup required).
{
  const q = { label: '5 h', usedPercent: 25, remaining: 75, total: 100, resetsAt: new Date(Date.now() + 3 * 3600000).toISOString(), source: 'codex-cli' };
  try {
    const out = bridge.renderQuotaBar(q);
    const ok =
      typeof out === 'string' &&
      out.includes('25') &&
      out.includes('75') &&
      out.includes('resets') &&
      out.includes(bridge.fmtTime(q.resetsAt));
    check('renderQuotaBar: standalone call returns expected HTML string', ok, out);
  } catch (e) {
    check('renderQuotaBar: standalone call returns expected HTML string', false, e.message);
  }
}

// Case 6: the Lessons card renders the active count and newest five, marking the two
// entries dated within 24h of the fixture's own updatedAt ("NEW").
{
  const lessons = fixture.lessons;
  const asOf = fixture.updatedAt;
  try {
    bridge.renderLessons(lessons, asOf);
    const html = elements['lessons-card'].innerHTML;
    const ids = lessons.newest.map((l) => l.id);
    const hasCount = html.includes(`>${lessons.activeCount}<`);
    const hasAllIds = ids.every((id) => html.includes(id));
    const newCount = (html.match(/NEW/g) || []).length;
    const ok = html.length > 0 && hasCount && hasAllIds && newCount === 2;
    check('lessons: card renders active count, newest five, and marks the two <24h entries as NEW', ok, html);
  } catch (e) {
    check('lessons: card renders active count, newest five, and marks the two <24h entries as NEW', false, e.message);
  }
}

// Case 7: two Codex logins. One block per login with its own plan and account fingerprint; when
// both fingerprints are the same the card must say so, because the "reserve" then shares the one
// quota window and the older block's full bar is a stale reading of it, not spare capacity.
{
  const twoLogins = {
    installed: true, ready: true, cooldownUntil: null, lastMessage: null, plan: 'plus',
    quotas: [],
    accounts: [
      { key: 'codex', label: 'primary', ready: true, cooldownUntil: null, lastMessage: null, plan: 'plus', accountId: 'AAAA1111',
        quotas: [{ label: '7 d', usedPercent: 36, remaining: 64, total: 100, resetsAt: '2026-09-26T00:18:41Z', readAt: new Date(Date.now() - 600000).toISOString(), source: 'codex-jsonl' }] },
      { key: 'codex/b', label: 'b', ready: true, cooldownUntil: null, lastMessage: null, plan: 'prolite', accountId: 'BBBB2222',
        quotas: [{ label: '7 d', usedPercent: 0, remaining: 100, total: 100, resetsAt: '2026-09-26T00:18:41Z', readAt: new Date(Date.now() - 30 * 3600000).toISOString(), source: 'codex-jsonl' }] },
    ],
  };
  try {
    bridge.provider('codex', twoLogins, null);
    const html = elements['prov-codex'].innerHTML;
    const ok =
      html.includes('Plan (primary)') &&
      html.includes('Plus') && html.includes('Pro Lite') &&
      html.includes('#AAAA1111') && html.includes('#BBBB2222') &&
      html.includes('not live') &&
      !html.includes('Note:');
    check('two-logins: each login shows its own plan and fingerprint, the old reading is marked, no false shared-account warning', ok, html);
  } catch (e) {
    check('two-logins: each login shows its own plan and fingerprint, the old reading is marked, no false shared-account warning', false, e.message);
  }

  // Same account behind both logins -> warning, and the stale block points at the live one.
  const shared = JSON.parse(JSON.stringify(twoLogins));
  shared.accounts[1].accountId = 'AAAA1111';
  shared.accounts[1].plan = 'plus';
  shared.accounts[0].quotas[0].readAt = new Date(Date.now() - 600000).toISOString();
  shared.accounts[1].quotas[0].readAt = new Date(Date.now() - 30 * 3600000).toISOString();
  try {
    bridge.provider('codex', shared, null);
    const html = elements['prov-codex'].innerHTML;
    const groups = bridge.groupSharedAccounts(shared.accounts);
    const ok =
      groups.length === 1 && groups[0][1].join(',') === 'primary,b' &&
      html.includes('are the same account') &&
      html.includes('its figure is the live one') &&
      bridge.freshestReadingByAccount(shared.accounts).get('AAAA1111').label === 'primary';
    check('shared-account: two logins of one account are flagged and the stale bar points at the live one', ok, html);
  } catch (e) {
    check('shared-account: two logins of one account are flagged and the stale bar points at the live one', false, e.message);
  }
}

if (failures > 0) {
  console.error(`\n${failures} check(s) failed.`);
  process.exit(1);
} else {
  console.log('\nAll checks passed.');
  process.exit(0);
}
