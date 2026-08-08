// Race leaderboard NUI.

const board = document.getElementById('raceboard');
const rows = document.getElementById('rrows');
const statusEl = document.getElementById('rstatus');
const leaderEl = document.getElementById('rleader');

const titleEl = document.getElementById('rtitle');

const state = { list: [], leader: null, status: 'idle', car: null, turtleCar: null };

function fmtTime(ms) {
  if (typeof ms !== 'number' || ms < 0) return '—';
  const hundredths = Math.floor(ms / 10);
  const seconds = Math.floor(hundredths / 100);
  const mm = Math.floor(seconds / 60);
  const ss = String(seconds % 60).padStart(2, '0');
  const hh = String(hundredths % 100).padStart(2, '0');
  return `${mm}:${ss}.${hh}`;
}

function timeLabel(p) {
  return fmtTime(p.elapsedMs);
}

// The board orders on this, so show it — otherwise the rows shuffle mid-race
// for no visible reason.
function distLabel(p) {
  if (p.finished) return '—';
  if (typeof p.distance !== 'number') return '…';
  return p.distance >= 1000
    ? `${(p.distance / 1000).toFixed(2)} km`
    : `${Math.round(p.distance)} m`;
}

function render() {
  if (!state.list.length) {
    board.classList.add('hidden');
    return;
  }
  board.classList.remove('hidden');

  rows.innerHTML = '';
  state.list.forEach((p, i) => {
    const tr = document.createElement('tr');
    if (p.me) tr.classList.add('me');
    if (p.finished) tr.classList.add('done');

    // textContent, never innerHTML: p.name is player-chosen and relayed to
    // everyone, and CEF script here reaches every resource's NUI callbacks.
    for (const value of [String(i + 1), p.name || 'Unknown', distLabel(p), timeLabel(p)]) {
      const td = document.createElement('td');
      td.textContent = value;
      tr.appendChild(td);
    }
    rows.appendChild(tr);
  });

  // At most two cars for the whole field, so they go in the title, not down a
  // column. The second one only exists in turtle mode.
  if (!state.car) {
    titleEl.textContent = 'Race';
  } else if (state.turtleCar) {
    titleEl.textContent = `Race — ${state.car} vs 🐢 ${state.turtleCar}`;
  } else {
    titleEl.textContent = `Race — ${state.car}`;
  }

  statusEl.textContent = state.status === 'running'
    ? 'Race in progress'
    : state.status === 'finished' ? 'Race finished' : state.status;

  const lead = state.list.find(p => p.id === state.leader);
  leaderEl.textContent = lead ? `🏁 ${lead.name} is in the lead` : '';
}

window.addEventListener('message', (event) => {
  const msg = event.data;
  if (!msg || msg.type !== 'standings') return;
  const d = msg.data || {};
  state.list = d.list || [];
  state.leader = d.leader;
  state.status = d.status || 'idle';
  state.car = d.car || null;
  state.turtleCar = d.turtleCar || null;
  render();
});