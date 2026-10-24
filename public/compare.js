const form = document.querySelector('#compare-form');

if (form) {
  form.querySelectorAll('input[name="ids"]').forEach((control) => {
    control.addEventListener('change', () => form.requestSubmit());
  });

  document.querySelectorAll('.sort-button').forEach((button) => {
    button.addEventListener('click', () => {
      const inputs = [...form.querySelectorAll('input[name="sort"]')];
      const sortOrder = inputs
        .map((input) => input.value)
        .filter((value) => value !== 'none')
        .map((value) => {
          const [key, direction] = value.split(':');
          return { key, direction };
        });
      const index = sortOrder.findIndex((item) => item.key === button.dataset.sortKey);

      if (index === -1) {
        sortOrder.push({ key: button.dataset.sortKey, direction: 'asc' });
      } else if (sortOrder[index].direction === 'asc') {
        sortOrder[index].direction = 'desc';
      } else {
        sortOrder.splice(index, 1);
      }

      inputs.forEach((input) => input.remove());
      if (sortOrder.length) {
        sortOrder.forEach(({ key, direction }) => {
          const input = document.createElement('input');
          input.type = 'hidden';
          input.name = 'sort';
          input.value = `${key}:${direction}`;
          form.append(input);
        });
      } else {
        const input = document.createElement('input');
        input.type = 'hidden';
        input.name = 'sort';
        input.value = 'none';
        form.append(input);
      }
      form.requestSubmit();
    });
  });
}
