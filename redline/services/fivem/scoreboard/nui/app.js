// Scoreboard NUI — renders the player snapshot pushed by server.lua.

const rowsEl = document.getElementById('rows');
const serverNameEl = document.getElementById('server-name');
const serverMetaEl = document.getElementById('server-meta');
const hostilesChip = document.getElementById('hostiles-chip');
const bountyChip = document.getElementById('bounty-chip');
const legendEl = document.getElementById('legend');

const CLASS_COLORS = {
  player: '#ffb400',
  squad: '#ff5f56',
  survival: '#ff5f56',
  bounty: '#ffd97a',
  police: '#5aa2ff',
  misc_npc: '#9aa0a8',
  ambient: '#6b7280',
};

const CLASS_LABELS = {
  player: 'players',
  squad: 'hostiles',
  survival: 'hostiles',
  bounty: 'bounty',
  police: 'police',
  misc_npc: 'script NPCs',
  ambient: 'world NPCs',
};

let lastData = null;

function fmtNum(n) {
  return n == null ? '0' : String(n);
}

function kdClass(kd) {
  if (kd == null || isNaN(kd)) return '—';
  if (kd === Infinity) return '∞';
  return kd.toFixed(2);
}

function rowFor(p, index) {
  const tr = document.createElement('tr');
  if (p.me) tr.classList.add('me');
  if (!p.alive) tr.classList.add('offline');

  const td = (cls) => {
    const c = document.createElement('td');
    if (cls) c.className = cls;
    return c;
  };

  const num = td('num');
  num.textContent = String(index + 1);

  const name = td('name');
  name.textContent = p.name || 'Unknown';
  if (p.me) {
    const tag = document.createElement('span');
    tag.className = 'tag';
    tag.textContent = ' (you)';
    name.appendChild(tag);
  }
  if (!p.alive) {
    const tag = document.createElement('span');
    tag.className = 'tag';
    tag.textContent = ' dead';
    name.appendChild(tag);
  }

  const kills = td('num');
  kills.textContent = fmtNum(p.kills.total);

  const deaths = td('num');
  deaths.textContent = fmtNum(p.deaths);

  const kd = td('num kd');
  kd.textContent = kdClass(p.kd);

  // Kill breakdown, compact "players x · hostiles y · ..." line.
  const bdown = td('bdown');
  const breakdown = document.createElement('span');
  breakdown.className = 'breakdown';
  const parts = [];
  for (const [cls, color] of Object.entries(CLASS_COLORS)) {
    const count = (p.kills && p.kills[cls]) || 0;
    if (count > 0) {
      parts.push(`<b style="color:${color}">${count}</b> ${CLASS_LABELS[cls]}`);
    }
  }
  breakdown.innerHTML = parts.length ? parts.join(' · ') : '—';
  bdown.appendChild(breakdown);

  const bounty = td('num');
  bounty.textContent = fmtNum(p.bounty);

  const veh = td();
  veh.textContent = p.vehicle || '';

  const ping = td('num');
  ping.textContent = fmtNum(p.ping);

  tr.append(num, name, kills, deaths, kd, bdown, bounty, veh, ping);
  return tr;
}

function render(data) {
  if (!data) return;
  lastData = data;

  serverNameEl.innerHTML = data.serverName
    ? `<span class="dot">●</span> ${data.serverName}`
    : 'redline sandbox';

  const playerCount = (data.players || []).length;
  serverMetaEl.textContent = `${playerCount} player${playerCount === 1 ? '' : 's'} online`;

  const tbody = rowsEl;
  tbody.innerHTML = '';
  const players = data.players || [];
  for (let i = 0; i < players.length; i++) {
    tbody.appendChild(rowFor(players[i], i));
  }

  if (hostilesChip) {
    hostilesChip.innerHTML = `<b>${fmtNum(data.hostiles)}</b> hostile NPCs alive`;
  }
  if (bountyChip) {
    if (data.bounty) {
      bountyChip.className = 'chip bounty-live';
      bountyChip.innerHTML = `bounty live: <b>${data.bounty}</b>`;
    } else {
      bountyChip.className = 'chip';
      bountyChip.textContent = 'no bounty';
    }
  }
  if (legendEl) {
    legendEl.textContent = 'kills: players · hostiles · police · world NPCs';
  }
}

// Message bridge from the client.
window.addEventListener('message', (event) => {
  const msg = event.data;
  if (!msg || typeof msg !== 'object') return;
  if (msg.type === 'setVisible') {
    document.getElementById('scoreboard').classList.toggle('hidden', !msg.visible);
  } else if (msg.type === 'update') {
    render(msg.data);
  }
});

// Initial ghost state until the client updates us.
render({ players: [], hostiles: 0, bounty: null, serverName: 'redline sandbox' });