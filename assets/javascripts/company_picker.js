/* Enhance real selects with Redmine's bundled jQuery UI autocomplete. */
(function () {
  if (window.MyuctoCompanyPicker) {
    window.MyuctoCompanyPicker.initialize();
    return;
  }

  function normalize(text) {
    return text.toLocaleLowerCase().normalize('NFD').replace(/[\u0300-\u036f]/g, '');
  }

  function initializeSelect(select) {
    const $ = window.jQuery;
    if (select.myuctoPicker || !$ || !$.fn.autocomplete || select.disabled) return;

    const input = document.createElement('input');
    input.type = 'text';
    input.id = select.id + '_search';
    input.className = 'autocomplete';
    input.size = 60;
    input.style.maxWidth = '100%';
    input.autocomplete = 'off';
    input.placeholder = select.dataset.placeholder || '';
    // Only the original select has a name: forms always submit the selected ID.
    let changingFromInput = false;
    function selectedLabel() {
      const option = select.options[select.selectedIndex];
      return option && option.value ? option.textContent : '';
    }
    function refresh(options) {
      const keepQuery = options && options.preserveSearch && input.validity.customError;
      if (keepQuery) select.value = '';
      else {
        input.value = selectedLabel();
        input.setCustomValidity('');
      }
      input.disabled = select.disabled;
      $(input).autocomplete('close');
    }
    function notifyChange() {
      changingFromInput = true;
      try { select.dispatchEvent(new Event('change', { bubbles: true })); }
      finally { changingFromInput = false; }
    }

    $(input).autocomplete({
      minLength: 0,
      delay: 0,
      position: { collision: 'flipfit' },
      source: function (request, response) {
        const term = normalize(request.term);
        const choices = Array.from(select.options)
          .filter(option => option.value && !option.disabled && normalize(option.textContent).includes(term))
          .slice(0, 50)
          .map(option => ({ label: option.textContent, value: option.value }));
        response(choices);
      },
      focus: function () { return false; },
      select: function (_event, ui) {
        select.value = ui.item.value;
        input.value = ui.item.label;
        input.setCustomValidity('');
        notifyChange();
        return false;
      }
    });
    input.addEventListener('focus', function () {
      input.select();
      $(input).autocomplete('search', '');
    });
    input.addEventListener('input', function () {
      const exact = Array.from(select.options).find(option =>
        option.value && !option.disabled && option.textContent === input.value);
      select.value = exact ? exact.value : '';
      input.setCustomValidity(input.value && !exact ? select.dataset.invalid : '');
      notifyChange();
    });
    select.addEventListener('change', function () {
      if (!changingFromInput) refresh();
    });
    select.insertAdjacentElement('afterend', input);
    select.hidden = true;
    const label = document.querySelector('label[for="' + select.id + '"]');
    if (label) label.htmlFor = input.id;
    select.myuctoPicker = { refresh: refresh };
    refresh();
  }

  function initialize() {
    document.querySelectorAll('select.myucto-company-select').forEach(initializeSelect);
  }
  window.MyuctoCompanyPicker = {
    initialize: initialize,
    refresh: function (select, options) {
      initializeSelect(select);
      if (select.myuctoPicker) select.myuctoPicker.refresh(options);
    }
  };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', initialize);
  else initialize();
})();
