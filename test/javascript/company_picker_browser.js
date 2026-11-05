// Real browser test with the jQuery UI bundle shipped by the target Redmine.
// REDMINE_JQUERY_PATH=/path/to/jquery-3.7.1-ui-1.13.3.js node test/javascript/company_picker_browser.js
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const { spawnSync } = require('node:child_process');
const assert = require('node:assert/strict');

assert.ok(process.env.REDMINE_JQUERY_PATH, 'Set REDMINE_JQUERY_PATH to the Redmine jQuery UI bundle');
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'myucto-picker-'));
const bundle = pathToFileURL(path.resolve(process.env.REDMINE_JQUERY_PATH)).href;
const picker = pathToFileURL(path.resolve(__dirname, '../../assets/javascripts/company_picker.js')).href;
const html = String.raw`<!doctype html><meta charset="utf-8"><title>MyÚčto company selectors</title>
<style>body{font:14px Arial;margin:35px;color:#444}p{margin:24px 0}label{display:inline-block;width:180px}input,select{padding:5px;border:1px solid #ccc;border-radius:3px}.ui-autocomplete{position:absolute;background:white;border:1px solid #ccc;list-style:none;margin:0;padding:0;max-width:600px}.ui-menu-item-wrapper{padding:7px}.ui-state-active{background:#e7f1fa}.ui-helper-hidden-accessible{position:absolute;left:-10000px}#results{display:none}</style>
<h2>MyÚčto</h2><form id="settings">
<p><label for="supplier">Fakturující firma</label><select id="supplier" name="settings[supplier_id]" class="myucto-company-select" data-invalid="Vyberte firmu" data-placeholder="Název, IČO nebo ID firmy…"><option value=""></option><option value="7" selected>Žluťoučká firma · IČO 12345678 · ID 7</option><option value="8">Servis s.r.o. · IČO 87654321 · ID 8</option></select></p>
<p><label for="customer">Odběratel projektu</label><select id="customer" name="myucto_project_setting[client_id]" class="myucto-company-select" data-invalid="Vyberte firmu" data-placeholder="Název, IČO nebo ID firmy…"><option value=""></option><option value="11">Prodejna Praha · IČO 11112222 · ID 11</option><option value="12">Servis Brno · IČO 22223333 · ID 12</option></select></p>
<p><label for="disabled">Nedostupné API</label><select id="disabled" disabled class="myucto-company-select"><option value="13">Uložený odběratel · ID 13</option></select></p>
</form><pre id="results"></pre>
<script src="${bundle}"></script><script src="${picker}"></script>
<script>
window.addEventListener('load', function () {
  const results = document.getElementById('results');
  const passed = [];
  function check(condition, message) { if (!condition) throw new Error(message); passed.push(message); }
  function type(input, value) { input.value = value; input.dispatchEvent(new Event('input', { bubbles: true })); }
  function key(input, name, code) { input.dispatchEvent(new KeyboardEvent('keydown', { key: name, keyCode: code, which: code, bubbles: true })); }
  try {
    const supplier = document.getElementById('supplier');
    const customer = document.getElementById('customer');
    const supplierInput = document.getElementById('supplier_search');
    const customerInput = document.getElementById('customer_search');
    check(supplier.hidden && customer.hidden && supplierInput && customerInput, 'Both real selects gain native Redmine autocomplete');
    check(supplierInput.value.includes('Žluťoučká') && supplier.value === '7', 'Saved selection is displayed without changing its ID');
    check(document.querySelector('label[for="supplier_search"]'), 'Visible input retains its label');
    check(!document.getElementById('disabled').hidden && !document.getElementById('disabled_search'), 'Disabled API fallback stays a native disabled select');
    MyuctoCompanyPicker.initialize();
    check(document.querySelectorAll('#supplier_search').length === 1, 'Repeated initialization creates no duplicate input');

    supplierInput.focus();
    type(supplierInput, 'zluto');
    $(supplierInput).autocomplete('search', 'zluto');
    let menu = $(supplierInput).autocomplete('widget');
    check(menu.find('.ui-menu-item').length === 1 && menu.text().includes('Žluťoučká'), 'Autocomplete matches company names without diacritics');
    type(supplierInput, '87654321');
    $(supplierInput).autocomplete('search', '87654321');
    check(menu.find('.ui-menu-item').length === 1 && menu.text().includes('Servis'), 'Autocomplete searches registration numbers');
    key(supplierInput, 'ArrowDown', 40);
    key(supplierInput, 'Enter', 13);
    check(supplier.value === '8' && supplierInput.value.includes('Servis') && supplierInput.checkValidity(), 'Arrow and Enter select a supplier by its real ID');

    customerInput.focus();
    type(customerInput, 'ID 12');
    $(customerInput).autocomplete('search', 'ID 12');
    key(customerInput, 'ArrowDown', 40);
    key(customerInput, 'Enter', 13);
    check(customer.value === '12' && customerInput.value.includes('Brno'), 'The customer uses the same keyboard selection');
    const formData = new FormData(document.getElementById('settings'));
    check(formData.get('settings[supplier_id]') === '8' && formData.get('myucto_project_setting[client_id]') === '12', 'Forms submit selected IDs, not display names');
    check(Array.from(formData.keys()).length === 2, 'Search inputs submit no extra form fields');
    type(customerInput, 'Nonexistent company');
    check(customer.value === '' && !customerInput.checkValidity(), 'Unselected free text cannot save a wrong company');
    customer.value = '11';
    MyuctoCompanyPicker.refresh(customer, { preserveSearch: true });
    check(customer.value === '' && customerInput.value === 'Nonexistent company' && !customerInput.checkValidity(), 'An asynchronous refresh preserves an unfinished search and its validation');
    type(customerInput, '');
    check(customer.value === '' && customerInput.checkValidity(), 'Clearing the optional selection is supported');
    customer.value = '11';
    MyuctoCompanyPicker.refresh(customer);
    check(customerInput.value.includes('Praha'), 'Refreshing options restores the selected display name');

    const unsafe = document.createElement('option');
    unsafe.value = '99'; unsafe.textContent = '<img src=x onerror=window.pwned=true> · ID 99';
    customer.appendChild(unsafe);
    $(customerInput).autocomplete('search', 'ID 99');
    check($(customerInput).autocomplete('widget').find('img').length === 0 && !window.pwned, 'Company labels are rendered as text');
    $(customerInput).autocomplete('close');

    const fallback = document.createElement('select'); fallback.id = 'fallback'; fallback.className = 'myucto-company-select';
    fallback.innerHTML = '<option value="41">Plain select</option><option value="42">Second company</option>';
    document.getElementById('settings').appendChild(fallback);
    const jquery = window.jQuery; window.jQuery = undefined;
    MyuctoCompanyPicker.initialize();
    fallback.value = '42';
    check(!fallback.hidden && !document.getElementById('fallback_search') && fallback.value === '42', 'Without autocomplete the ordinary select remains usable');
    window.jQuery = jquery;
    fallback.remove();
    supplierInput.focus(); $(supplierInput).autocomplete('search', '');
    results.dataset.passed = 'true'; results.textContent = passed.join('\n');
  } catch (error) { results.dataset.passed = 'false'; results.textContent = error.stack; }
});
</script>`;
try {
  const fixture = path.join(directory, 'picker.html');
  fs.writeFileSync(fixture, html);
  const args = ['--headless', '--no-sandbox', '--disable-gpu', '--allow-file-access-from-files',
    '--user-data-dir=' + path.join(directory, 'profile'),
    '--virtual-time-budget=3000', '--window-size=1100,800', '--dump-dom', pathToFileURL(fixture).href];
  if (process.env.MYUCTO_PICKER_SCREENSHOT) args.unshift('--screenshot=' + process.env.MYUCTO_PICKER_SCREENSHOT);
  const result = spawnSync(process.env.CHROMIUM || 'chromium-browser', args, { encoding: 'utf8', timeout: 20000, maxBuffer: 4 * 1024 * 1024 });
  const match = result.stdout && result.stdout.match(/<pre id="results" data-passed="(true|false)">([\s\S]*?)<\/pre>/);
  assert.ok(match, result.stderr || String(result.error));
  assert.equal(match[1], 'true', match[2]);
  console.log(match[2]);
  console.log('PASS real Chromium / Redmine jQuery UI');
} finally {
  fs.rmSync(directory, { recursive: true, force: true });
}
