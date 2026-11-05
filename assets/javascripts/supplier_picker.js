/* Native searchable combobox: no CDN or additional JavaScript dependency. */
(function () {
  function initialize() {
    const root = document.getElementById('myucto-supplier-picker');
    if (!root || root.dataset.initialized) return;
    root.dataset.initialized = 'true';
    const url = document.getElementById('settings_base_url');
    const id = document.getElementById('settings_supplier_id');
    const search = document.getElementById('myucto-supplier-search');
    const list = document.getElementById('myucto-supplier-options');
    const status = document.getElementById('myucto-supplier-status');
    const details = document.getElementById('myucto-supplier-details');
    const button = document.getElementById('myucto-load-suppliers');
    let suppliers = [];
    let generation = 0;

    function choose(supplier) {
      id.value = String(supplier.id);
      search.value = supplier.text;
      search.setCustomValidity('');
      document.getElementById('myucto-supplier-name').textContent = supplier.name;
      document.getElementById('myucto-supplier-ic').textContent = supplier.ic || '—';
      document.getElementById('myucto-supplier-dic').textContent = supplier.dic || '—';
      details.hidden = false;
      status.textContent = '';
    }

    search.addEventListener('input', function () {
      const selected = suppliers.find(supplier => supplier.text === search.value);
      if (selected) choose(selected);
      else {
        id.value = '';
        details.hidden = true;
        search.setCustomValidity(root.dataset.invalid);
      }
    });

    url.addEventListener('input', function () {
      generation += 1;
      suppliers = [];
      list.replaceChildren();
      details.hidden = true;
      id.value = '';
      search.value = '';
      search.setCustomValidity(root.dataset.invalid);
      status.textContent = '';
      button.disabled = false;
    });

    async function load() {
      const attempt = ++generation;
      const previousId = id.value;
      button.disabled = true;
      status.textContent = root.dataset.loading;
      try {
        const csrf = document.querySelector('meta[name="csrf-token"]');
        const response = await fetch(root.dataset.url, {
          method: 'POST', credentials: 'same-origin',
          headers: { 'Content-Type': 'application/json', 'Accept': 'application/json',
                     'X-CSRF-Token': csrf ? csrf.content : '' },
          body: JSON.stringify({ base_url: url.value.trim() })
        });
        if (!response.ok) throw new Error('lookup failed');
        const data = await response.json();
        if (attempt !== generation) return;
        if (!Array.isArray(data.suppliers)) throw new Error('invalid response');
        suppliers = data.suppliers;
        list.replaceChildren();
        suppliers.forEach(supplier => {
          const option = document.createElement('option');
          option.value = supplier.text;
          option.label = [supplier.display_name, supplier.ic].filter(Boolean).join(' · ');
          list.appendChild(option);
        });
        const selected = suppliers.find(supplier => String(supplier.id) === previousId);
        // Do not silently switch an existing integration to another company.
        if (selected) choose(selected);
        else if (!previousId && suppliers.length === 1) choose(suppliers[0]);
        else {
          id.value = '';
          details.hidden = true;
          search.value = '';
          search.setCustomValidity(root.dataset.invalid);
          status.textContent = previousId ? root.dataset.unavailable :
            (suppliers.length ? root.dataset.invalid : root.dataset.empty);
        }
      } catch (_) {
        if (attempt === generation) status.textContent = root.dataset.error;
        // Keep the saved ID on an outage; opening settings must not erase it.
      } finally {
        if (attempt === generation) button.disabled = false;
      }
    }
    button.addEventListener('click', load);
    if (url.value.trim()) load();
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', initialize);
  else initialize();
})();
