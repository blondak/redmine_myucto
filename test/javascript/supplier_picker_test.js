const { test } = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');

class Element {
  constructor() {
    this.value = '';
    this.dataset = {};
    this.hidden = false;
    this.disabled = false;
    this.textContent = '';
    this.listeners = {};
    this.children = [];
  }
  addEventListener(event, callback) { this.listeners[event] = callback; }
  replaceChildren(...children) { this.children = children; }
  appendChild(child) { this.children.push(child); return child; }
}

class Select extends Element {
  constructor() { super(); this.selectedIndex = -1; }
  get options() { return this.children; }
  get value() { return this.options?.[this.selectedIndex]?.value || ''; }
  set value(value) {
    this.selectedIndex = this.options?.findIndex(option => option.value === String(value)) ?? -1;
  }
  replaceChildren(...options) {
    super.replaceChildren(...options);
    this.selectedIndex = options.length ? 0 : -1;
  }
  appendChild(option) {
    super.appendChild(option);
    if (this.selectedIndex < 0) this.selectedIndex = 0;
    return option;
  }
}

function option(value, text) {
  const element = new Element();
  element.value = String(value);
  element.textContent = text;
  return element;
}

function fixture(savedId = '7', companyPicker) {
  const elements = {};
  for (const id of ['myucto-supplier-picker', 'settings_base_url', 'myucto-supplier-status',
    'myucto-supplier-details', 'myucto-load-suppliers', 'myucto-supplier-name',
    'myucto-supplier-ic', 'myucto-supplier-dic']) elements[id] = new Element();
  const select = elements.settings_supplier_id = new Select();
  select.replaceChildren(option('', ''));
  if (savedId) select.appendChild(option(savedId, `ID ${savedId}`));
  select.value = savedId;
  elements['myucto-supplier-details'].hidden = true;
  elements.settings_base_url.value = 'https://billing.example.test';
  elements['myucto-supplier-picker'].dataset = {
    url: '/myucto/suppliers', loading: 'loading', error: 'error', empty: 'empty', unavailable: 'unavailable'
  };
  const requests = [];
  const document = {
    readyState: 'complete', getElementById: id => elements[id],
    querySelector: selector => selector === 'meta[name="csrf-token"]' ? { content: 'csrf-token' } : null,
    createElement: tag => { assert.equal(tag, 'option'); return new Element(); }
  };
  // The canonical select works without jQuery or the optional autocomplete.
  const window = companyPicker ? { MyuctoCompanyPicker: companyPicker } : {};
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../../assets/javascripts/supplier_picker.js'), 'utf8'), {
    document, window,
    fetch: (url, options) => new Promise(resolve => requests.push({ url, options, resolve }))
  });
  return { elements, requests };
}

const company = (id = 7, fields = {}) => ({
  id, name: 'Example <s.r.o.>', text: `Example (ID ${id})`, ic: '12345678', dic: 'CZ12345678', ...fields
});
const flush = () => new Promise(resolve => setImmediate(resolve));
async function respond(request, suppliers) {
  request.resolve({ ok: true, json: async () => ({ suppliers }) });
  await flush();
}

test('loads saved details in the native select and sends only URL with CSRF', async () => {
  const { elements: e, requests } = fixture();
  assert.equal(requests[0].url, '/myucto/suppliers');
  assert.equal(requests[0].options.method, 'POST');
  assert.equal(requests[0].options.credentials, 'same-origin');
  assert.deepEqual(JSON.parse(requests[0].options.body), { base_url: 'https://billing.example.test' });
  assert.equal(requests[0].options.headers['X-CSRF-Token'], 'csrf-token');
  assert.equal(requests[0].options.headers['Content-Type'], 'application/json');
  await respond(requests[0], [company()]);
  assert.equal(e.settings_supplier_id.value, '7');
  assert.deepEqual(e.settings_supplier_id.options.map(item => item.value), ['', '7']);
  assert.equal(e.settings_supplier_id.options[1].textContent, 'Example (ID 7) · 12345678');
  assert.equal(e.settings_supplier_id.hidden, false);
  assert.equal(e['myucto-supplier-name'].textContent, 'Example <s.r.o.>');
  assert.equal(e['myucto-supplier-ic'].textContent, '12345678');
  assert.equal(e['myucto-supplier-dic'].textContent, 'CZ12345678');
  assert.equal(e['myucto-supplier-details'].hidden, false);
  assert.equal(e['myucto-load-suppliers'].disabled, false);
});

test('an initial outage preserves the saved company option and ID', async () => {
  const { elements: e, requests } = fixture();
  requests[0].resolve({ ok: false });
  await flush();
  assert.equal(e.settings_supplier_id.value, '7');
  assert.equal(e.settings_supplier_id.options[1].textContent, 'ID 7');
  assert.equal(e['myucto-supplier-status'].textContent, 'error');
  assert.equal(e['myucto-load-suppliers'].disabled, false);
});

test('a refresh outage preserves selection, options and loaded details', async () => {
  const { elements: e, requests } = fixture();
  await respond(requests[0], [company(), company(8)]);
  const previousOptions = e.settings_supplier_id.options.slice();
  e['myucto-load-suppliers'].listeners.click();
  requests[1].resolve({ ok: false });
  await flush();
  assert.equal(e.settings_supplier_id.value, '7');
  assert.deepEqual(e.settings_supplier_id.options, previousOptions);
  assert.equal(e['myucto-supplier-details'].hidden, false);
  assert.equal(e['myucto-supplier-name'].textContent, company().name);
  assert.equal(e['myucto-supplier-status'].textContent, 'error');
});

test('keeps a missing saved company as a fallback option and reports unavailable', async () => {
  const { elements: e, requests } = fixture();
  await respond(requests[0], [company(8)]);
  assert.equal(e.settings_supplier_id.value, '7');
  assert.deepEqual(e.settings_supplier_id.options.map(item => item.value), ['', '8', '7']);
  assert.equal(e.settings_supplier_id.options[e.settings_supplier_id.selectedIndex].textContent, 'ID 7');
  assert.equal(e['myucto-supplier-status'].textContent, 'unavailable');
  assert.equal(e['myucto-supplier-details'].hidden, true);
});

test('selects the sole company on first setup', async () => {
  const { elements: e, requests } = fixture('');
  await respond(requests[0], [company()]);
  assert.equal(e.settings_supplier_id.value, '7');
  assert.equal(e['myucto-supplier-details'].hidden, false);
  assert.equal(e['myucto-supplier-status'].textContent, '');
});

test('leaves multiple companies unselected and reports an empty result', async () => {
  const multiple = fixture('');
  await respond(multiple.requests[0], [company(), company(8)]);
  assert.equal(multiple.elements.settings_supplier_id.value, '');
  assert.equal(multiple.elements['myucto-supplier-details'].hidden, true);
  const empty = fixture('');
  await respond(empty.requests[0], []);
  assert.equal(empty.elements.settings_supplier_id.value, '');
  assert.equal(empty.elements.settings_supplier_id.options.length, 1);
  assert.equal(empty.elements['myucto-supplier-status'].textContent, 'empty');
});

test('ignores a stale response after URL change and loads the new destination', async () => {
  const { elements: e, requests } = fixture();
  e.settings_base_url.value = 'https://other.example.test';
  e.settings_base_url.listeners.input();
  await respond(requests[0], [company()]);
  assert.equal(e.settings_supplier_id.value, '');
  assert.deepEqual(e.settings_supplier_id.options.map(item => item.value), ['']);
  assert.equal(e['myucto-supplier-details'].hidden, true);
  assert.equal(e['myucto-supplier-status'].textContent, '');
  assert.equal(e['myucto-load-suppliers'].disabled, false);
  e['myucto-load-suppliers'].listeners.click();
  assert.deepEqual(JSON.parse(requests[1].options.body), { base_url: 'https://other.example.test' });
  await respond(requests[1], [company(8)]);
  assert.equal(e.settings_supplier_id.value, '8');
});

test('select change updates details without refreshing the autocomplete input', async () => {
  const refreshed = [];
  const { elements: e, requests } = fixture('7', { refresh: select => refreshed.push(select) });
  await respond(requests[0], [company(), company(8, { name: 'Other company', ic: '', dic: '' })]);
  assert.equal(refreshed.length, 1);
  e.settings_supplier_id.value = '8';
  e.settings_supplier_id.listeners.change();
  assert.equal(e['myucto-supplier-name'].textContent, 'Other company');
  assert.equal(e['myucto-supplier-ic'].textContent, '—');
  assert.equal(e['myucto-supplier-dic'].textContent, '—');
  assert.equal(e['myucto-supplier-details'].hidden, false);
  assert.equal(e['myucto-supplier-status'].textContent, '');
  assert.equal(refreshed.length, 1);
  e.settings_supplier_id.value = '';
  e.settings_supplier_id.listeners.change();
  assert.equal(e['myucto-supplier-details'].hidden, true);
});

test('async refresh retains the company selected while discovery was in flight', async () => {
  const { elements: e, requests } = fixture();
  await respond(requests[0], [company(), company(8, { name: 'Other company' })]);
  e['myucto-load-suppliers'].listeners.click();
  e.settings_supplier_id.value = '8';
  e.settings_supplier_id.listeners.change();
  await respond(requests[1], [company(), company(8, { name: 'Updated other company' })]);
  assert.equal(e.settings_supplier_id.value, '8');
  assert.equal(e['myucto-supplier-name'].textContent, 'Updated other company');
  assert.equal(e['myucto-supplier-details'].hidden, false);
  assert.equal(e['myucto-supplier-status'].textContent, '');
});
