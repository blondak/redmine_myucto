const { test } = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');

function fixture(savedId = '7') {
  const elements = {};
  for (const name of ['myucto-supplier-picker', 'settings_base_url', 'settings_supplier_id',
    'myucto-supplier-search', 'myucto-supplier-options', 'myucto-supplier-status',
    'myucto-supplier-details', 'myucto-load-suppliers', 'myucto-supplier-name',
    'myucto-supplier-ic', 'myucto-supplier-dic']) {
    elements[name] = {
      value: '', dataset: {}, hidden: true, textContent: '', listeners: {}, children: [],
      addEventListener(event, callback) { this.listeners[event] = callback; },
      setCustomValidity(message) { this.validity = message; },
      replaceChildren() { this.children = []; },
      appendChild(child) { this.children.push(child); }
    };
  }
  elements['settings_base_url'].value = 'https://billing.example.test';
  elements['settings_supplier_id'].value = savedId;
  elements['myucto-supplier-picker'].dataset = {
    url: '/myucto/suppliers', loading: 'loading', error: 'error', invalid: 'choose', empty: 'empty', unavailable: 'unavailable'
  };
  const requests = [];
  const document = {
    readyState: 'complete', getElementById: id => elements[id],
    querySelector: () => ({ content: 'csrf-token' }), createElement: () => ({})
  };
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../../assets/javascripts/supplier_picker.js'), 'utf8'), {
    document, fetch: (url, options) => new Promise(resolve => requests.push({ url, options, resolve }))
  });
  return { elements, requests };
}
const company = (id = 7) => ({ id, name: 'Example <s.r.o.>', text: `Example (ID ${id})`, ic: '12345678', dic: 'CZ12345678' });
const flush = () => new Promise(resolve => setImmediate(resolve));

async function respond(request, suppliers) {
  request.resolve({ ok: true, json: async () => ({ suppliers }) });
  await flush();
}

test('loads saved company details and sends only the URL with CSRF', async () => {
  const { elements: e, requests } = fixture();
  assert.deepEqual(JSON.parse(requests[0].options.body), { base_url: 'https://billing.example.test' });
  assert.equal(requests[0].options.headers['X-CSRF-Token'], 'csrf-token');
  await respond(requests[0], [company()]);
  assert.equal(e['settings_supplier_id'].value, '7');
  assert.equal(e['myucto-supplier-name'].textContent, 'Example <s.r.o.>');
  assert.equal(e['myucto-supplier-ic'].textContent, '12345678');
  assert.equal(e['myucto-supplier-details'].hidden, false);
});

test('an outage preserves the saved company ID', async () => {
  const { elements: e, requests } = fixture();
  requests[0].resolve({ ok: false });
  await flush();
  assert.equal(e['settings_supplier_id'].value, '7');
  assert.equal(e['myucto-supplier-status'].textContent, 'error');
});

test('never silently switches a missing saved company', async () => {
  const { elements: e, requests } = fixture();
  await respond(requests[0], [company(8)]);
  assert.equal(e['settings_supplier_id'].value, '');
  assert.equal(e['myucto-supplier-search'].validity, 'choose');
  assert.equal(e['myucto-supplier-status'].textContent, 'unavailable');
});

test('selects the sole company on first setup, rejects arbitrary typed names', async () => {
  const { elements: e, requests } = fixture('');
  await respond(requests[0], [company()]);
  assert.equal(e['settings_supplier_id'].value, '7');
  e['myucto-supplier-search'].value = 'Not an option';
  e['myucto-supplier-search'].listeners.input();
  assert.equal(e['settings_supplier_id'].value, '');
  assert.equal(e['myucto-supplier-search'].validity, 'choose');
  e['myucto-supplier-search'].value = company().text;
  e['myucto-supplier-search'].listeners.input();
  assert.equal(e['settings_supplier_id'].value, '7');
  assert.equal(e['myucto-supplier-search'].validity, '');
});

test('ignores a stale response after changing the destination URL', async () => {
  const { elements: e, requests } = fixture();
  e['settings_base_url'].value = 'https://other.example.test';
  e['settings_base_url'].listeners.input();
  await respond(requests[0], [company()]);
  assert.equal(e['settings_supplier_id'].value, '');
  assert.equal(e['myucto-supplier-details'].hidden, true);
  assert.equal(e['myucto-supplier-options'].children.length, 0);
});
