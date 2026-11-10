const recipes = [
  { id: 'risotto', name: 'Charred Leek & Lemon Risotto', blurb: 'Silky, bright, finished with herbs.', veg: true, mins: 40, price: 4.20,
    food: 'radial-gradient(circle at 40% 40%, #f3e7b8 0 30%, #e9d68f 31% 55%, #a7c08a 56% 64%, #f3e7b8 65%)',
    ingredients: [['Arborio rice', '500 g'], ['Leeks', '3'], ['Lemons', '2'], ['Parmesan', '120 g', 'parmesan'], ['Vegetable stock', '1.5 l']] },
  { id: 'chicken', name: 'Herb-Roast Chicken Thighs', blurb: 'Crisp skin, garlic, thyme and lemon.', veg: false, mins: 50, price: 5.10,
    food: 'radial-gradient(circle at 55% 45%, #c9893f 0 26%, #a86a2c 27% 45%, #6f8f4e 46% 56%, #e8c58b 57%)',
    ingredients: [['Chicken thighs', '12'], ['Garlic', '1 head'], ['Thyme', '1 bunch']] },
  { id: 'burrata', name: 'Blistered Tomato & Burrata', blurb: 'Warm tomatoes, cold cheese, basil oil.', veg: true, mins: 15, price: 3.40,
    food: 'radial-gradient(circle at 50% 50%, #fbfbf6 0 22%, #d64a37 23% 40%, #f08a3b 41% 52%, #4f8a3f 53% 60%, #fbfbf6 61%)',
    ingredients: [['Cherry tomatoes', '900 g'], ['Burrata', '3'], ['Basil', '2 bunches']] },
  { id: 'shortrib', name: 'Slow-Braised Short Rib', blurb: 'Red wine, shallots, a long afternoon.', veg: false, mins: 210, price: 9.80,
    food: 'radial-gradient(circle at 45% 50%, #5a2a1f 0 35%, #7a3a26 36% 52%, #d9b98a 53%)', ingredients: [['Short ribs', '3 kg']] },
  { id: 'salmon', name: 'Miso-Glazed Salmon', blurb: 'Sweet, salty, ten minutes under the grill.', veg: false, mins: 20, price: 8.60,
    food: 'radial-gradient(circle at 50% 45%, #e98457 0 30%, #c8623a 31% 44%, #2f4f3a 45% 52%, #f1e6d0 53%)', ingredients: [['Salmon fillets', '6']] },
  { id: 'paella', name: 'Saffron Seafood Paella', blurb: 'For the table, straight from the pan.', veg: false, mins: 60, price: 7.40,
    food: 'radial-gradient(circle at 50% 50%, #f2b632 0 40%, #e0902a 41% 50%, #d4553b 51% 56%, #f2b632 57%)', ingredients: [['Bomba rice', '600 g']] },
  { id: 'peach', name: 'Grilled Peach & Fennel', blurb: 'Smoky fruit, shaved fennel, mint.', veg: true, mins: 20, price: 3.10,
    food: 'radial-gradient(circle at 45% 45%, #f5a35c 0 28%, #f7c58b 29% 44%, #cfe0a8 45% 58%, #fbf5e6 59%)', ingredients: [['Peaches', '6']] },
  { id: 'pannacotta', name: 'Burnt Honey Panna Cotta', blurb: 'Wobbly, golden, a little bitter.', veg: true, mins: 25, price: 2.90,
    food: 'radial-gradient(circle at 50% 50%, #fbf3dc 0 34%, #d99a35 35% 42%, #fbf3dc 43%)', ingredients: [['Cream', '1 l'], ['Honey', '200 g']] },
];
const slots = [
  ['slot-fri-evening', 'Friday', '5–7 pm', 4], ['slot-sat-morning', 'Saturday', '9–11 am', 3],
  ['slot-sat-evening', 'Saturday', '5–7 pm', 3], ['slot-sun-morning', 'Sunday', '9–11 am', 5],
];
const state = { guests: 2, vegOnly: false, chosen: [], swapped: false, slot: null, ordered: false };
const $ = (s) => document.querySelector(s);
const money = (n) => '$' + n.toFixed(2);

function renderRecipes() {
  $('#recipes').innerHTML = recipes.map(r => `
    <article class="recipe${state.vegOnly && !r.veg ? ' hidden' : ''}${state.chosen.includes(r.id) ? ' chosen' : ''}" id="recipe-${r.id}">
      <div class="plate ${r.veg ? 'veg' : ''}"><div class="dish"><div class="food" data-food="${r.id}"></div></div>
        <img src="/demo/img/supper-${r.id}.jpg" alt="${r.name}" loading="lazy"></div>
      <div class="body">
        <div class="tags">${r.veg ? '<span class="tag">Vegetarian</span>' : ''}<span class="tag time">${r.mins >= 60 ? Math.round(r.mins / 60 * 10) / 10 + ' hr' : r.mins + ' min'}</span></div>
        <h3>${r.name}</h3>
        <p>${r.blurb}</p>
        <div class="row"><span class="price">${money(r.price)} <small>/ serving</small></span>
          <button class="add" id="add-${r.id}" aria-label="${state.chosen.includes(r.id) ? 'Remove' : 'Add'} ${r.name}">${state.chosen.includes(r.id) ? 'On the menu ✓' : 'Add to menu'}</button></div>
      </div>
    </article>`).join('');
  recipes.forEach(r => {
    $('#add-' + r.id).onclick = () => toggle(r.id);
    const food = document.querySelector(`[data-food="${r.id}"]`);
    if (food) food.style.background = r.food;
  });
  document.querySelectorAll('.plate img').forEach(img => img.addEventListener('error', () => img.remove()));
}

function renderMenu() {
  const chosen = recipes.filter(r => state.chosen.includes(r.id));
  $('#lines').innerHTML = chosen.length ? chosen.map(r => `
    <div class="line"><span>${r.name}<small>${state.guests} servings</small></span><span>${money(r.price * state.guests)}</span></div>`).join('')
    : '<p class="empty">Add a few dishes to start your menu.</p>';
  const items = chosen.flatMap(r => r.ingredients);
  $('#ingredients-wrap').hidden = !items.length;
  $('#ingredients').innerHTML = items.map(([name, qty, key]) => {
    if (key === 'parmesan') {
      return state.swapped
        ? `<div class="ingredient" id="ingredient-parmesan"><span class="swapped">Vegetarian hard cheese · ${qty}</span><span>✓</span></div>`
        : `<div class="ingredient" id="ingredient-parmesan"><span>Parmesan · ${qty} <small class="warn">not vegetarian</small></span><button class="swap" id="swap-parmesan">Swap</button></div>`;
    }
    return `<div class="ingredient"><span>${name}</span><span class="qty">${qty}</span></div>`;
  }).join('');
  const sw = $('#swap-parmesan'); if (sw) sw.onclick = () => { state.swapped = true; renderMenu(); };
  const sub = chosen.reduce((t, r) => t + r.price * state.guests, 0);
  const del = state.slot ? slots.find(s => s[0] === state.slot)[3] : 0;
  $('#subtotal').textContent = money(sub);
  $('#delivery').textContent = money(del);
  $('#total').textContent = money(sub + del);
  $('#budget-note').innerHTML = chosen.length ? (sub + del <= 80 ? `<span class="under">${money(80 - sub - del)} under budget</span>` : `<span class="over">${money(sub + del - 80)} over budget</span>`) : '';
  $('#place-order').disabled = !chosen.length || !state.slot || state.ordered;
  $('#place-order').textContent = state.ordered ? 'Ordered (demo)' : 'Place order';
}

function renderSlots() {
  $('#slots').innerHTML = slots.map(([id, day, time, fee]) => `
    <div class="slot"><input type="radio" name="slot" id="${id}" ${state.slot === id ? 'checked' : ''}>
      <label for="${id}">${day}<small>${time} · ${money(fee)}</small></label></div>`).join('');
  slots.forEach(([id]) => $('#' + id).onchange = () => { state.slot = id; renderMenu(); });
}

function toggle(id) {
  state.chosen = state.chosen.includes(id) ? state.chosen.filter(x => x !== id) : [...state.chosen, id];
  renderRecipes(); renderMenu();
}

$('#guests').oninput = (e) => { state.guests = Math.max(1, Math.min(20, Number(e.target.value) || 1)); renderMenu(); };
$('#diet-veg').onclick = (e) => { state.vegOnly = !state.vegOnly; e.target.setAttribute('aria-pressed', state.vegOnly); renderRecipes(); };
$('#place-order').onclick = () => { state.ordered = true; renderMenu();
  $('#order-note').innerHTML = '<p class="done">All set for Saturday. (This is a demo: nothing was ordered.)</p>'; };
renderRecipes(); renderSlots(); renderMenu();
