const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const workflow = fs.readFileSync(path.join(__dirname, '../.github/workflows/sandy-public-callback.yml'), 'utf8');
const marker = '          script: |\n';
const start = workflow.indexOf(marker);
assert.notEqual(start, -1, 'workflow must define the callback script');
const bodyStart = start + marker.length;
const rest = workflow.slice(bodyStart).split('\n');
const script = [];
for (const line of rest) {
  if (line.length && !line.startsWith('            ')) break;
  script.push(line.startsWith('            ') ? line.slice(12) : '');
}
const source = script.join('\n');

const requestId = 'f394f9cc-12ab-4ad8-9222-9a43bc9f5330';
const requestRunId = '1234567890123';
const publicRunId = 9876543210;
const mainSha = 'a'.repeat(40);
const runSha = 'b'.repeat(40);

function invoke(overrides = {}) {
  const calls = { relay: [], branch: 0, compare: [] };
  const run = {
    path: '.github/workflows/sandy-public-macos.yml',
    workflow_id: 364487606,
    name: `sandy-public-ci-${requestId}-${requestRunId}`,
    event: 'repository_dispatch',
    run_attempt: 1,
    display_title: `sandy-public-ci-${requestId}-${requestRunId}`,
    id: publicRunId,
    head_sha: runSha,
    ...overrides.run,
  };
  const context = {
    payload: { workflow_run: run },
    repo: { owner: 'iamyosuke', repo: 'sandy-ci' },
  };
  const github = {
    rest: { repos: {
      getBranch: async (input) => {
        calls.branch++;
        assert.equal(JSON.stringify(input), JSON.stringify({ owner: 'iamyosuke', repo: 'sandy-ci', branch: 'main' }));
        return { data: { commit: { sha: overrides.mainSha || mainSha } } };
      },
      compareCommitsWithBasehead: async (input) => {
        calls.compare.push(input);
        return { data: { status: overrides.comparisonStatus || 'ahead' } };
      },
    } },
  };
  const env = {
    SANDY_CALLBACK_TOKEN: 'fine-grained-token',
    SANDY_CALLBACK_REPOSITORY_ID: '1217636338',
    SANDY_CALLBACK_ISSUE_NUMBER: '81',
    ...overrides.env,
  };
  const fetch = async (...args) => {
    calls.relay.push(args);
    if (args[0] === 'https://api.github.com/repositories/1217636338') {
      return { ok: true, json: async () => overrides.repository || { id: 1217636338, full_name: 'hidden-org/hidden-repo' } };
    }
    return { ok: true };
  };
  const wrapped = `(async () => {\n${source}\n})()`;
  return vm.runInNewContext(wrapped, { context, github, process: { env }, fetch, AbortSignal }, { timeout: 1000 })
    .then(() => calls);
}

test('relays only the three validated opaque IDs in the fixed body', async () => {
  const calls = await invoke();
  assert.equal(calls.relay.length, 2);
  assert.equal(calls.relay[0][0], 'https://api.github.com/repositories/1217636338');
  const [url, options] = calls.relay[1];
  assert.equal(url, 'https://api.github.com/repos/hidden-org/hidden-repo/issues/81/comments');
  assert.equal(options.method, 'POST');
  assert.equal(options.headers.Authorization, 'Bearer fine-grained-token');
  assert.deepEqual(JSON.parse(options.body), {
    body: JSON.stringify({ request_id: requestId, request_run_id: requestRunId, public_run_id: String(publicRunId) }),
  });
  assert.equal(JSON.stringify(calls.compare), JSON.stringify([{ owner: 'iamyosuke', repo: 'sandy-ci', basehead: `${runSha}...${mainSha}` }]));
});

test('accepts the workflow path with GitHub main-ref suffix', async () => {
  const calls = await invoke({ run: { path: '.github/workflows/sandy-public-macos.yml@main' } });
  assert.equal(calls.relay.length, 2);
});

for (const [label, run] of [
  ['wrong workflow path', { path: '.github/workflows/other.yml' }],
  ['wrong workflow ID', { workflow_id: 123 }],
  ['wrong trigger event', { event: 'push' }],
  ['rerun attempt', { run_attempt: 2 }],
  ['unbound request run ID', { display_title: `sandy-public-ci-${requestId}-0` }],
  ['malformed request ID', { display_title: `sandy-public-ci-not-a-uuid-${requestRunId}` }],
  ['invalid public run ID', { id: '123;evil' }],
  ['invalid workflow SHA', { head_sha: 'invalid' }],
]) {
  test(`fails closed for ${label}`, async () => {
    const result = invoke({ run });
    await assert.rejects(result);
    await result.catch(() => {});
  });
}

test('fails closed when the run SHA is not in current main history', async () => {
  await assert.rejects(invoke({ comparisonStatus: 'behind' }));
});

test('fails closed when relay configuration is missing', async () => {
  const calls = await invoke({ env: { SANDY_CALLBACK_TOKEN: '' } }).catch((error) => error);
  assert.match(calls.message, /relay configuration/);
});

test('fails closed when repository ID or issue number targets another relay', async () => {
  for (const env of [
    { SANDY_CALLBACK_REPOSITORY_ID: '5567774149' },
    { SANDY_CALLBACK_ISSUE_NUMBER: '42' },
  ]) {
    await assert.rejects(invoke({ env }));
  }
});

test('fails closed when repository lookup does not match the fixed target', async () => {
  await assert.rejects(invoke({ repository: { id: 1217636339, full_name: 'hidden-org/hidden-repo' } }));
  await assert.rejects(invoke({ repository: { id: 1217636338, full_name: 'invalid/name/extra' } }));
});

test('callback script is valid JavaScript', () => {
  assert.doesNotThrow(() => new vm.Script(`(async () => {\n${source}\n})()`));
});
