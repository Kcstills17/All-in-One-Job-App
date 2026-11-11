let STAGES = [], jobs = [], LOCS = [];
const OUTCOMES = new Set(["Offer", "Accepted", "Rejected", "Ghosted", "Withdrawn"]);
const INTERVIEWS = new Set(["Recruiter Screen", "Hiring Manager", "Technical Interview", "Take-home", "Final Round", "Work Trial", "Offer", "Accepted"]);
const PENDING = "No response yet";

const $ = s => document.querySelector(s);
const esc = s => String(s ?? "").replace(/[&<>"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));
const stageOf = j => j.history[j.history.length - 1].stage;
const byId = id => jobs.find(j => j.id === id);
// Writes carry the CSRF token from /api/session; an expired login goes back to the login page.
let csrfToken;
const csrf = () => csrfToken ??= fetch("/api/session").then(r => r.json()).then(s => s.csrf);
const api = async (path, opts = {}) => {
  const headers = { "content-type": "application/json" };
  if (opts.method && opts.method !== "GET") headers["x-csrf-token"] = await csrf();
  const res = await fetch(path, { ...opts, headers });
  if (res.status === 401) { location.href = "/login"; return new Promise(() => {}); }
  return res.json();
};
const css = v => getComputedStyle(document.documentElement).getPropertyValue(v);
// Progress stages walk from indigo → teal → green; endings get their own warning colors.
const PALETTE = {
  "Applied": "#7c83ff", "Followed Up": "#8f86f0", "Recruiter Screen": "#5b9dff", "Hiring Manager": "#3fb4e8",
  "Technical Interview": "#26c6c9", "Take-home": "#2fbfa5", "Final Round": "#3ccf8e", "Work Trial": "#6fd779",
  "Offer": "#46d160", "Accepted": "#22b85c", "Rejected": "#f0616d", "Ghosted": "#f4a63b", "Withdrawn": "#a0a4ad",
  [PENDING]: "#8b909a",
};
const color = n => PALETTE[n] || css("--accent");
const options = sel => STAGES.map(s => `<option ${s === sel ? "selected" : ""}>${s}</option>`).join("");

// Forward-only path through STAGES (keeps the Sankey acyclic), plus the history event behind each step.
// An ending (Rejected/Ghosted/Withdrawn) only counts if it's the latest event, so a stale one doesn't hide later progress.
const ENDINGS = new Set(["Rejected", "Ghosted", "Withdrawn"]);
function path(j) {
  const steps = []; let max = -1;
  j.history.forEach((h, k) => {
    if (ENDINGS.has(h.stage) && k !== j.history.length - 1) return;
    const i = STAGES.indexOf(h.stage); if (i > max) { steps.push(h); max = i; }
  });
  const last = steps[steps.length - 1].stage;
  if (last === "Applied" || last === "Followed Up") steps.push({ stage: PENDING, on: "", note: "" });
  return steps;
}

$("#bm").href = `javascript:(()=>{window.open('${location.origin}/add?url='+encodeURIComponent(location.href)+'&title='+encodeURIComponent(document.title),'_blank','width=460,height=600')})()`;

async function load() {
  let refData;
  [STAGES, jobs, LOCS, refData] = await Promise.all([api("/api/stages"), api("/api/jobs"), api("/api/locations"),
    api("/api/referrals").catch(() => ({ statuses: [], referrals: [], failed: true }))]);
  ({ statuses: REF_STATUSES, referrals } = refData);
  // The page updates on refresh but the server doesn't, so an out-of-date server looks like missing data.
  $("#loadErr").hidden = !refData.failed;
  $("#cityList").innerHTML = LOCS.map(l => `<option value="${esc(l)}">`).join("");
  $("#stageFilter").innerHTML = `<option value="">All stages</option>` + STAGES.map(s => `<option>${s}</option>`).join("");
  $("#refAddStatus").innerHTML = refOptions(REF_STATUSES[0]);
  render();
}

// ---- Tabs: only the open view renders (the Sankey can't measure itself while hidden). Linkable: /?view=referrals ----
const VIEWS = ["applications", "referrals", "together"];
let view = VIEWS.find(v => v === new URLSearchParams(location.search).get("view")) || "applications";
function showView() {
  VIEWS.forEach(v => { $(`#view-${v}`).hidden = v !== view; });
  document.querySelectorAll("#tabs button").forEach(b => b.setAttribute("aria-pressed", String(b.dataset.view === view)));
}
function setView(v) {
  view = v; showView();
  const u = new URL(location); v === "applications" ? u.searchParams.delete("view") : u.searchParams.set("view", v);
  history.replaceState(null, "", u);
  render();
}
$("#tabs").addEventListener("click", e => { const v = e.target.closest("[data-view]")?.dataset.view; if (v) { setView(v); scrollTo(0, 0); } });

// ---- Shared chart pieces ----
function hbars(rows, color) {
  const max = Math.max(1, ...rows.map(r => r[1]));
  return rows.map(([name, v, sub = ""]) => `<div class="hrow" title="${esc(name)}: ${v}${sub ? ` (${sub})` : ""}">
    <span class="hname">${esc(name)}</span>
    <span class="htrack"><i style="width:${100 * v / max}%;${v ? "min-width:3px;" : ""}background:var(${color})"></i></span>
    <span class="hval"><b>${v}</b>${sub ? ` <small>${sub}</small>` : ""}</span></div>`).join("");
}
// Every month from the first date to the last, so quiet months still show as gaps.
function monthSpan(dates) {
  const ms = dates.filter(Boolean).map(d => d.slice(0, 7)).sort(), out = [];
  if (!ms.length) return out;
  for (let d = new Date(`${ms[0]}-15T12:00`); ; d.setMonth(d.getMonth() + 1)) {
    const m = ymd(d).slice(0, 7); out.push(m);
    if (m >= ms.at(-1)) return out;
  }
}
function monthBars(months, dates, color, label) {
  const n = d3.rollup(dates.filter(Boolean), v => v.length, d => d.slice(0, 7)), max = Math.max(1, ...n.values());
  return `<div class="mgrid" role="img" aria-label="${esc(label)} by month: ${months.map(m => `${m} ${n.get(m) || 0}`).join(", ")}">` + months.map(m => {
    const v = n.get(m) || 0, d = new Date(`${m}-15T12:00`);
    return `<div class="mcol" title="${d.toLocaleString(undefined, { month: "long", year: "numeric" })}: ${v} ${esc(label.toLowerCase())}">
      <span class="mv">${v || ""}</span><span class="mp"><i style="height:${100 * v / max}%;background:var(${color})"></i></span>
      <span class="ml">${d.toLocaleString(undefined, { month: "short" })}</span></div>`;
  }).join("") + `</div>`;
}
const stats = rows => rows.map(([k, v, tip]) => `<div class="stat"${tip ? ` title="${esc(tip)}"` : ""}><b>${v}</b><span>${k}</span></div>`).join("");
const recent = d => d && Date.now() - new Date(d) < 30 * 864e5;
const companyKey = s => lc0(s).trim();
const contacted = r => r.status !== "To Contact";
const replied = r => ["Replied", "Met", "Referral Offered", "Referred", "Declined"].includes(r.status);
const offered = r => ["Referral Offered", "Referred"].includes(r.status);

function renderRefCharts() {
  const n = referrals.length, reached = referrals.filter(contacted).length, reply = referrals.filter(replied).length;
  const offers = referrals.filter(offered).length, done = referrals.filter(r => r.status === "Referred").length;
  const undated = referrals.filter(r => !r.first_contact).length;
  $("#refStats").innerHTML = stats([
    ["People", n], ["Companies", new Set(referrals.map(r => companyKey(r.company)).filter(Boolean)).size],
    ["Contacted", reached], ["Got a reply", reply], ["Reply rate", pct1(reply, reached), "Replies out of the people you've contacted"],
    ["Meetings", referrals.filter(r => r.meeting_on || r.status === "Met").length],
    ["Referrals offered", offers, "Status is Referral Offered or Referred"], ["Referred", done],
  ]);
  $("#refFunnel").innerHTML = hbars([["People", n], ["Contacted", reached, pct1(reached, n)], ["Got a reply", reply, pct1(reply, n)],
    ["Referral offered", offers, pct1(offers, n)], ["Referred", done, pct1(done, n)]], "--refs");
  const byCompany = d3.rollups(referrals.filter(r => r.company), v => v.length, r => r.company.trim()).sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));
  $("#refCompanies").innerHTML = hbars(byCompany.slice(0, 8), "--refs") +
    (byCompany.length > 8 ? `<p class="sub" style="margin:6px 0 0;font-size:12px">Plus ${byCompany.length - 8} more companies.</p>` : "");
  const dates = referrals.map(r => r.first_contact);
  $("#refMonths").innerHTML = monthBars(monthSpan(dates), dates, "--refs", "First contacts") +
    (undated ? `<p class="sub" style="margin:0;font-size:12px">${undated} of ${n} people have no first contact date, so they aren't shown here.</p>` : "");
  $("#refRoles").innerHTML = hbars(d3.rollups(referrals, v => v.length, r => roleFamily(r.role)).sort((a, b) => b[1] - a[1]), "--refs");
}

function renderTogether() {
  const jobCo = new Set(jobs.map(j => companyKey(j.company)).filter(Boolean)), refCo = new Set(referrals.map(r => companyKey(r.company)).filter(Boolean));
  const shared = [...refCo].filter(c => jobCo.has(c));
  const atShared = jobs.filter(j => refCo.has(companyKey(j.company))), elsewhere = jobs.filter(j => !refCo.has(companyKey(j.company)));
  const reached = referrals.filter(contacted);
  const count = (list, f) => list.filter(f).length;
  $("#togStats").innerHTML = stats([
    ["Companies overall", new Set([...jobCo, ...refCo]).size], ["Companies in both", shared.length],
    ["Response rate, referral companies", `${pct1(count(atShared, responded), atShared.length)}<small> of ${atShared.length}</small>`,
      "Applications to companies where you also have a referral contact. This doesn't show the referral caused the response."],
    ["Response rate, other companies", `${pct1(count(elsewhere, responded), elsewhere.length)}<small> of ${elsewhere.length}</small>`, "Applications to every other company"],
  ]);
  $("#togCompare").innerHTML = [
    ["Total", jobs.length, referrals.length],
    ["Companies", jobCo.size, refCo.size],
    ["Last 30 days", count(jobs, j => recent(j.applied_on)), count(referrals, r => recent(r.first_contact))],
    ["Got a response", count(jobs, responded), count(referrals, replied)],
    ["Response rate", pct1(count(jobs, responded), jobs.length), pct1(count(reached, replied), reached.length)],
  ].map(([k, a, b]) => `<tr><td>${k}</td><td>${a}</td><td>${b}</td></tr>`).join("");

  const jobDates = jobs.map(j => j.applied_on), refDates = referrals.map(r => r.first_contact);
  const months = monthSpan([...jobDates, ...refDates]);
  $("#togMonths").innerHTML = `<h3><i class="swatch" style="background:var(--apps)"></i>Applications</h3>${monthBars(months, jobDates, "--apps", "Applications")}
    <h3><i class="swatch" style="background:var(--refs)"></i>Referral first contacts</h3>${monthBars(months, refDates, "--refs", "First contacts")}`;
  const undated = refDates.filter(d => !d).length;
  $("#togUndated").textContent = undated ? `${undated} referrals have no first contact date and aren't shown.` : "";

  const byLevel = $("#togGroup").value === "level";
  const nameOf = byLevel ? levelOf : roleFamily;
  const names = [...new Set([...jobs.map(j => nameOf(j.title)), ...referrals.map(r => nameOf(r.role))])];
  const groups = names.map(name => {
    const js = jobs.filter(j => nameOf(j.title) === name), rs = referrals.filter(r => nameOf(r.role) === name);
    return { name, js, rs, sent: rs.filter(contacted) };
  });
  if (byLevel) groups.sort((a, b) => GROUPS.level.order.indexOf(a.name) - GROUPS.level.order.indexOf(b.name));
  else groups.sort((a, b) => b.js.length + b.rs.length - a.js.length - a.rs.length);
  const maxJ = Math.max(1, ...groups.map(g => g.js.length)), maxR = Math.max(1, ...groups.map(g => g.rs.length));
  const cell = (n, max, color) => `<span class="bar"><i style="width:${100 * n / max}%;background:var(${color})"></i></span>${n}`;
  $("#togGroupHead").textContent = byLevel ? "Level" : "Role type";
  $("#togGroups").innerHTML = groups.map(g => `<tr><td><b>${esc(g.name)}</b></td>
    <td>${cell(g.js.length, maxJ, "--apps")}</td><td>${g.js.length ? pct1(count(g.js, responded), g.js.length) : "—"}</td>
    <td>${cell(g.rs.length, maxR, "--refs")}</td><td>${g.sent.length ? `${pct1(count(g.sent, replied), g.sent.length)} <span class="sub" style="margin:0">of ${g.sent.length}</span>` : "—"}</td></tr>`).join("");

  $("#bothCount").textContent = `(${shared.length})`;
  $("#bothRows").innerHTML = shared.map(key => ({ js: jobs.filter(j => companyKey(j.company) === key), rs: referrals.filter(r => companyKey(r.company) === key) }))
    .sort((a, b) => b.rs.length - a.rs.length || a.rs[0].company.localeCompare(b.rs[0].company))
    .map(({ js, rs }) => {
      const best = js.map(furthest).reduce((a, b) => STAGES.indexOf(b) > STAGES.indexOf(a) ? b : a, "Applied"), name = rs[0].company.trim();
      return `<tr><td><span class="link toApps" data-q="${esc(`company:"${name}"`)}" title="See these applications">${esc(name)}</span></td>
        <td>${js.length}</td><td><span class="pill" style="white-space:nowrap;border-color:${color(best)}">${esc(best)}</span></td>
        <td>${rs.map(r => `<span class="link openRef" data-ref="${r.id}">${esc(r.name)}</span> <span class="sub" style="margin:0">(${esc(r.status)})</span>`).join(", ")}</td></tr>`;
    }).join("");
}
$("#togGroup").addEventListener("change", renderTogether);
$("#bothRows").addEventListener("click", e => {
  if (e.target.matches(".openRef")) return openReferral(referrals.find(r => r.id === e.target.dataset.ref));
  if (e.target.matches(".toApps")) { setView("applications"); searchFor(e.target.dataset.q); }
});

// ---- Referrals: people who could refer you, kept separate from applications and their stats ----
let REF_STATUSES = [], referrals = [];
const refOptions = sel => REF_STATUSES.map(s => `<option ${s === sel ? "selected" : ""}>${s}</option>`).join("");
const webLink = u => /^https?:\/\//i.test(u || "") ? u : "";
// Sheet contacts come as emails, full URLs or bare "linkedin.com/in/…". Anything else stays plain text.
function contactLink(c) {
  const s = String(c || "").trim();
  if (/^[^\s@]+@[^\s@]+$/.test(s)) return `mailto:${s}`;
  return /^(www\.)?linkedin\.com\//i.test(s) ? `https://${s}` : webLink(s);
}
const lastContact = r => [r.first_contact, r.second_contact, r.meeting_on].filter(Boolean).sort().at(-1) || "";
// The latest date on a referral. Imported rows have no added date, so people with no dates at all sort last.
const lastActivity = r => [lastContact(r), r.added_on].filter(Boolean).sort().at(-1) || "";
const lastThenBlank = (a, b) => (a || "￿").localeCompare(b || "￿");
const REF_SORTS = {
  recent: (a, b) => lastActivity(b).localeCompare(lastActivity(a)),
  oldest: (a, b) => lastThenBlank(lastActivity(a), lastActivity(b)),
  added: (a, b) => (b.added_on || "").localeCompare(a.added_on || ""),
  name: () => 0,
  company: (a, b) => lastThenBlank(lc0(a.company).trim(), lc0(b.company).trim()),
  status: (a, b) => REF_STATUSES.indexOf(a.status) - REF_STATUSES.indexOf(b.status),
};

const renderReferrals = () => { renderRefCharts(); renderRefList(); };
function renderRefList() {
  const filter = $("#refFilter"), cur = filter.value;
  const counts = d3.rollup(referrals, v => v.length, r => r.status);
  filter.innerHTML = `<option value="">All statuses (${referrals.length})</option>` +
    REF_STATUSES.map(s => `<option value="${s}">${s} (${counts.get(s) || 0})</option>`).join("");
  filter.value = cur;
  const monthSel = $("#refMonth"), month = monthSel.value;
  const months = d3.rollups(referrals.filter(lastActivity), v => v.length, r => lastActivity(r).slice(0, 7)).sort((a, b) => b[0].localeCompare(a[0]));
  monthSel.innerHTML = `<option value="">Any month</option>` + months.map(([m, n]) =>
    `<option value="${m}">${new Date(`${m}-15T12:00`).toLocaleString(undefined, { month: "short", year: "numeric" })} (${n})</option>`).join("");
  monthSel.value = months.some(([m]) => m === month) ? month : "";
  const words = lc0($("#refQ").value).split(/\s+/).filter(Boolean), sortKey = $("#refSort").value, sorter = REF_SORTS[sortKey];
  // The list is stored newest first, so a same-day tie on a date sort keeps the newest person on top.
  const tie = ["recent", "added"].includes(sortKey) ? () => 0 : (a, b) => a.name.localeCompare(b.name);
  const shown = referrals
    .filter(r => (!cur || r.status === cur) && (!monthSel.value || lastActivity(r).startsWith(monthSel.value))
      && words.every(w => lc0([r.name, r.company, r.role, r.notes, r.contact, r.status, r.added_on, r.first_contact, r.second_contact, r.meeting_on].join(" ")).includes(w)))
    .sort((a, b) => sorter(a, b) || tie(a, b));
  $("#refInfo").textContent = shown.length === referrals.length ? `${shown.length} referrals` : `${shown.length} of ${referrals.length} referrals`;
  $("#refRows").innerHTML = shown.map(r => {
    const contact = contactLink(r.contact), url = webLink(r.url);
    return `<tr data-id="${r.id}">
      <td><span class="link openRef">${esc(r.name)}</span>${contact ? ` <a href="${esc(contact)}" target="_blank" rel="noopener" title="Contact ${esc(r.name)}">✉</a>` : ""}</td>
      <td>${esc(r.company) || "—"}</td>
      <td>${esc(r.role) || "—"}${url ? ` <a href="${esc(url)}" target="_blank" rel="noopener" title="Open role">↗</a>` : ""}</td>
      <td><select class="refStatus" aria-label="Status for ${esc(r.name)}">${refOptions(r.status)}</select></td>
      <td class="hide-sm" style="white-space:nowrap">${esc(lastActivity(r)) || "—"}${!lastContact(r) && r.added_on ? ` <span class="sub" style="margin:0">added</span>` : ""}</td>
      <td class="refNote"><textarea class="refNoteBox" data-saved="${esc(r.notes)}" aria-label="Notes for ${esc(r.name)}" placeholder="Add a note…">${esc(r.notes)}</textarea><span class="noteState" aria-live="polite"></span></td>
      <td><button class="ghost delRef" title="Delete" aria-label="Delete ${esc(r.name)}">✕</button></td>
    </tr>`; }).join("");
}
function replaceReferral(ref) { referrals[referrals.findIndex(r => r.id === ref.id)] = ref; render(); }

$("#refAdd").addEventListener("submit", async e => {
  e.preventDefault();
  const form = e.target, data = Object.fromEntries(new FormData(form));
  $("#refMsg").textContent = data.url ? "Fetching role details…" : "Saving…";
  const ref = await api("/api/referrals", { method: "POST", body: JSON.stringify(data) });
  if (ref.error) return void ($("#refMsg").textContent = `Error: ${ref.error}`);
  referrals.unshift(ref); form.reset();
  // Clear anything that could hide the new row, then show it.
  $("#refQ").value = $("#refFilter").value = $("#refMonth").value = "";
  render();
  const missing = ["company", "role"].filter(k => !ref[k]);
  $("#refMsg").textContent = `Added: ${ref.name}${ref.company ? ` at ${ref.company}` : ""}.` +
    (missing.length ? ` Couldn't fill in ${missing.join(" or ")}. Click their name to add ${missing.length > 1 ? "them" : "it"}.` : "");
  const row = [...$("#refRows").rows].find(tr => tr.dataset.id === ref.id);
  row?.classList.add("justAdded"); row?.scrollIntoView({ behavior: "smooth", block: "center" });
});
$("#refQ").addEventListener("input", renderRefList);
["#refFilter", "#refMonth", "#refSort"].forEach(s => $(s).addEventListener("change", renderRefList));
$("#refRows").addEventListener("change", async e => {
  if (!e.target.matches(".refStatus")) return;
  const ref = await api(`/api/referrals/${e.target.closest("tr").dataset.id}`, { method: "PATCH", body: JSON.stringify({ status: e.target.value }) });
  if (ref.error) return alert(ref.error);
  replaceReferral(ref);
});
// Row notes save shortly after you stop typing, and again when you leave the box.
const noteTimers = new WeakMap();
async function saveNote(box) {
  clearTimeout(noteTimers.get(box));
  const value = box.value, state = box.nextElementSibling;
  if (box.dataset.saved === value) return;
  box.dataset.saved = value;
  const res = await api(`/api/referrals/${box.closest("tr").dataset.id}`, { method: "PATCH", body: JSON.stringify({ notes: value }) })
    .catch(() => ({ error: "couldn't reach the app" }));
  if (res.error) delete box.dataset.saved; // the next edit or blur tries again; the text stays in the box
  state.textContent = res.error ? `Not saved: ${res.error}` : "Saved";
}
$("#refRows").addEventListener("input", e => {
  if (!e.target.matches(".refNoteBox")) return;
  const box = e.target;
  referrals.find(r => r.id === box.closest("tr").dataset.id).notes = box.value; // survives a re-render before the save lands
  box.nextElementSibling.textContent = "Saving…";
  clearTimeout(noteTimers.get(box));
  noteTimers.set(box, setTimeout(() => saveNote(box), 700));
});
$("#refRows").addEventListener("focusout", e => { if (e.target.matches(".refNoteBox")) saveNote(e.target); });
$("#refRows").addEventListener("click", async e => {
  const id = e.target.closest("tr")?.dataset.id, ref = referrals.find(r => r.id === id);
  if (e.target.matches(".openRef")) return openReferral(ref);
  if (!e.target.matches(".delRef") || !confirm(`Delete ${ref.name}${ref.company ? ` at ${ref.company}` : ""}?`)) return;
  await api(`/api/referrals/${id}`, { method: "DELETE" });
  referrals = referrals.filter(r => r.id !== id); render();
});
function openReferral(r) {
  const d = $("#refDetail");
  d.dataset.id = r.id;
  d.innerHTML = `
    <div class="row spread"><h2>${esc(r.name)}</h2><button class="ghost" data-act="closeRef">Close</button></div>
    <form class="grid2" style="margin-top:12px">
      <label class="noteField" style="grid-column:1/-1">Notes<textarea name="notes" placeholder="How you know them, what they said, next steps, when to follow up…">${esc(r.notes)}</textarea></label>
      <label>Referrer name<input name="name" value="${esc(r.name)}" required></label>
      <label>LinkedIn or email<input name="contact" value="${esc(r.contact)}"></label>
      <label>Company<input name="company" value="${esc(r.company)}"></label>
      <label>Role<input name="role" value="${esc(r.role)}"></label>
      <label>Role link<input type="url" name="url" value="${esc(r.url)}"></label>
      <label>Status<select name="status">${refOptions(r.status)}</select></label>
      <label>1st contact<input type="date" name="first_contact" value="${esc(r.first_contact)}"></label>
      <label>2nd contact<input type="date" name="second_contact" value="${esc(r.second_contact)}"></label>
      <label>Meeting date<input type="date" name="meeting_on" value="${esc(r.meeting_on)}"></label>
      <div style="grid-column:1/-1"><button>Save details</button></div>
    </form>`;
  d.showModal();
}
$("#refDetail").addEventListener("submit", async e => {
  e.preventDefault();
  const d = $("#refDetail");
  const ref = await api(`/api/referrals/${d.dataset.id}`, { method: "PATCH", body: JSON.stringify(Object.fromEntries(new FormData(e.target))) });
  if (ref.error) return alert(ref.error);
  replaceReferral(ref); d.close();
});
$("#refDetail").addEventListener("click", e => {
  if (e.target.dataset.act === "closeRef" || e.target === $("#refDetail")) $("#refDetail").close();
});

// ---- Activity & goals (saved per browser; the app works fine if storage is unavailable) ----
const GOAL_DEFAULTS = { on: true, day: 10, week: 50, month: 200 };
function loadGoals() { try { return { ...GOAL_DEFAULTS, ...JSON.parse(localStorage.getItem("goals") || "{}") }; } catch { return { ...GOAL_DEFAULTS }; } }
function saveGoals(g) { try { localStorage.setItem("goals", JSON.stringify(g)); } catch {} }
let goals = loadGoals();

const ymd = d => d.toLocaleDateString("en-CA"); // local YYYY-MM-DD
const isWeekday = d => d.getDay() % 6 !== 0;
const addDays = (d, n) => { const x = new Date(d); x.setDate(x.getDate() + n); return x; };
const weekdaysBetween = (a, b) => { let n = 0; for (let d = new Date(a); d <= b; d = addDays(d, 1)) if (isWeekday(d)) n++; return n; };

function ring(value, goal, size = 64) {
  const r = (size - 8) / 2, c = 2 * Math.PI * r, frac = goal ? Math.min(1, value / goal) : 0;
  const stroke = goal && value >= goal ? "var(--good)" : "var(--accent)";
  return `<svg width="${size}" height="${size}" viewBox="0 0 ${size} ${size}" aria-hidden="true">
    <circle cx="${size / 2}" cy="${size / 2}" r="${r}" fill="none" stroke="var(--line)" stroke-width="7"/>
    <circle cx="${size / 2}" cy="${size / 2}" r="${r}" fill="none" stroke="${stroke}" stroke-width="7" stroke-linecap="round"
      stroke-dasharray="${c}" stroke-dashoffset="${c * (1 - frac)}" transform="rotate(-90 ${size / 2} ${size / 2})"/>
    ${goal && value >= goal ? `<text x="50%" y="50%" dy=".35em" text-anchor="middle" fill="var(--good)" font-size="20">✓</text>` : ""}
  </svg>`;
}

function renderGoals() {
  const now = new Date(), today = ymd(now);
  const perDay = d3.rollup(jobs.filter(j => j.applied_on), v => v.length, j => j.applied_on);
  const n = d => perDay.get(ymd(d)) || 0;
  const monday = addDays(now, -((now.getDay() + 6) % 7)), sunday = addDays(monday, 6);
  const monthStart = new Date(now.getFullYear(), now.getMonth(), 1), monthEnd = new Date(now.getFullYear(), now.getMonth() + 1, 0);
  const sum = (a, b) => { let s = 0; for (let d = new Date(a); ymd(d) <= ymd(b); d = addDays(d, 1)) s += n(d); return s; };
  const todayN = perDay.get(today) || 0, weekN = sum(monday, now), monthN = sum(monthStart, now);
  const on = goals.on;

  // Pace: share of the goal you "should" have by now, counting weekdays elapsed (today included).
  const pace = (count, goal, start, end) => {
    const total = weekdaysBetween(start, end), done = weekdaysBetween(start, now);
    const expected = Math.round(goal * (total ? done / total : 1));
    if (count >= goal) return `<span class="ok">Goal hit</span>`;
    return count >= expected ? `<span class="ok">On pace</span> · ${goal - count} to go`
      : `<span class="warn">${expected - count} behind pace</span> · ${goal - count} to go`;
  };
  // Streak: consecutive weekdays meeting the daily goal (today counts once it's met).
  let streak = 0;
  for (let d = isWeekday(now) && todayN < goals.day ? addDays(now, -1) : new Date(now); ; d = addDays(d, -1)) {
    if (!isWeekday(d)) continue;
    if (n(d) >= goals.day && goals.day > 0) streak++; else break;
    if (streak > 365) break;
  }

  const tile = (label, count, goal, sub) => `<div class="goal">
      ${on ? ring(count, goal) : ""}
      <div><span class="sub" style="margin:0">${label}</span>
        <b>${count}${on && goal ? `<small> / ${goal}</small>` : ""}</b>
        ${on ? `<span class="sub" style="margin:0;font-size:12px">${sub}</span>` : ""}</div></div>`;
  const todaySub = !isWeekday(now) ? "Weekend — no daily goal" : todayN >= goals.day ? `<span class="ok">Goal hit</span>` : `${goals.day - todayN} to go today`;

  // Mon–Sun bars with the daily goal line.
  const days = d3.range(7).map(i => addDays(monday, i)), maxV = Math.max(goals.day * (on ? 1.2 : 0), ...days.map(n), 1);
  const cls = d => ymd(d) === today ? "today" : "";
  const vals = days.map(d => `<span class="${cls(d)}">${ymd(d) > today ? "" : n(d)}</span>`).join("");
  const cols = days.map(d => {
    const v = n(d), hit = on && isWeekday(d) && v >= goals.day;
    return `<div class="col" title="${d.toDateString()}: ${v} applied"><i style="height:${100 * v / maxV}%;background:${hit ? "var(--good)" : "var(--accent)"}"></i></div>`;
  }).join("");
  const lbls = days.map(d => `<span class="${cls(d)}">${d.toLocaleDateString(undefined, { weekday: "short" })}</span>`).join("");
  const goalLine = on && goals.day ? `<div class="goalline" style="bottom:${100 * goals.day / maxV}%"><span>${goals.day}/day</span></div>` : "";
  const bars = `<div class="wk-row">${vals}</div><div class="wk-plot">${cols}${goalLine}</div><div class="wk-row">${lbls}</div>`;

  $("#goals").innerHTML =
    tile("Today", todayN, isWeekday(now) ? goals.day : 0, todaySub) +
    tile("This week", weekN, goals.week, pace(weekN, goals.week, monday, sunday)) +
    tile(now.toLocaleDateString(undefined, { month: "long" }), monthN, goals.month, pace(monthN, goals.month, monthStart, monthEnd)) +
    `<div class="goal week"><div class="bars">${bars}</div>
      ${on ? `<span class="sub" style="margin:0;font-size:12px">${streak ? `🔥 ${streak}-weekday streak` : "Hit today's goal to start a streak"}</span>` : ""}</div>`;
  $("#goalsOn").checked = on;
  $("#editGoals").hidden = !on;
}
$("#goalsOn").addEventListener("change", e => { goals.on = e.target.checked; saveGoals(goals); $("#goalForm").hidden = true; renderGoals(); });
$("#editGoals").addEventListener("click", () => {
  const f = $("#goalForm"); f.hidden = !f.hidden;
  for (const k of ["day", "week", "month"]) f[k].value = goals[k];
});
$("#cancelGoals").addEventListener("click", () => { $("#goalForm").hidden = true; });
$("#goalForm").addEventListener("submit", e => {
  e.preventDefault();
  for (const k of ["day", "week", "month"]) goals[k] = Math.max(0, parseInt(e.target[k].value, 10) || 0);
  saveGoals(goals); e.target.hidden = true; renderGoals();
});

// ---- Salary: parsed from the free-text pay field (single number or range; k, $, /hr all fine) ----
// "120k" → 120000–120000 · "90-120k" → 90000–120000 · "$26–30/hr" → ×2080 · "?" → null
function parsePay(text) {
  const s = String(text || "").toLowerCase().replace(/,/g, "");
  const nums = [...s.matchAll(/(\d+(?:\.\d+)?)\s*(k|m(?![a-z]))?/g)].map(m => ({ v: +m[1], u: m[2] || "" }));
  if (!nums.length) return null;
  const anyK = nums.some(n => n.u === "k");
  const hourly = /\/\s*h(ou)?r|per hour|hourly|\bhr\b|an hour/.test(s) || (!anyK && Math.max(...nums.map(n => n.v)) < 50);
  let vals = nums.slice(0, 2).map(n => n.u === "k" ? n.v * 1e3 : n.u === "m" ? n.v * 1e6 : hourly ? n.v * 2080 : n.v < 1000 ? n.v * 1e3 : n.v);
  vals = vals.filter(v => v >= 15000 && v <= 2e6);
  if (!vals.length) return null;
  const [a, b = a] = vals, min = Math.round(Math.min(a, b)), max = Math.round(Math.max(a, b));
  return { min, max, mid: Math.round((min + max) / 2), hourly };
}
const salaryOf = j => parsePay(j.pay);
// Display: always the full amount, ranges as "$200,000-400,000". (Input stays however you typed it.)
const num = v => Math.round(v).toLocaleString("en-US");
const money = v => `$${num(v)}`;
const money1k = v => money(Math.round(v / 1000) * 1000); // averages/medians, rounded to the nearest $1,000
const range = (a, b, f = money) => Math.round(a) === Math.round(b) ? f(a) : `${f(a)}-${f(b).slice(1)}`;
const moneyRange = s => range(s.min, s.max);
const payShown = j => { const p = salaryOf(j); return p ? moneyRange(p) : (j.pay || ""); };
function payPreview(text) {
  if (!String(text || "").trim() || /^\?+$/.test(String(text).trim())) return "";
  const s = parsePay(text);
  return s ? `<span class="ok">= ${moneyRange(s)} / yr${s.hourly ? " (hourly × 2,080)" : ""}</span>`
    : `<span class="warn">can't read this — try 120k or 100–140k</span>`;
}
// salary:>120k · salary:<100k · salary:120k-140k (midpoint in range) · salary:130k (130K within the posted range)
function salaryMatch(s, v) {
  if (!s) return false;
  const k = x => { const n = parseFloat(x); return /k$/.test(x) || n < 1000 ? n * 1e3 : n; };
  let m;
  if ((m = v.match(/^>=?\s*([\d.]+k?)$/))) return s.mid >= k(m[1]);
  if ((m = v.match(/^<=?\s*([\d.]+k?)$/))) return s.mid < k(m[1]);
  if ((m = v.match(/^([\d.]+k?)\s*[-–]\s*([\d.]+k?)$/))) return s.mid >= k(m[1]) && s.mid < k(m[2]);
  if ((m = v.match(/^([\d.]+k?)$/))) return s.min <= k(m[1]) && k(m[1]) <= s.max;
  return false;
}

// Role type + level from titles, including your shorthand (SE, FSE, FDE, JSE, ASE, BE, TSE…).
const FAMILIES = [
  ["Forward Deployed", /forward[- ]?deployed|\bfde\b|\bfdse\b/],
  ["Support / Customer Eng", /support|\btse\b|\bcse\b|customer (success )?engineer|developer success|implementation|technical (solutions|account)|onboarding|integrations?\b/],
  ["Solutions / Sales Eng", /solutions? (engineer|architect|consultant)|sales engineer|pre-?sales/],
  ["AI / ML", /\bai\b|\bml\b|machine learning|\bllm\b|applied scien/],
  ["Product Engineer", /product engineer/],
  ["Frontend", /front[- ]?end|\bui engineer/],
  ["Backend", /back[- ]?end|\bbe\b|\bbse\b/],
  ["Full Stack", /full[- ]?stack|\bj?fse\b|\bfs\b/],
  ["DevOps / Infra", /devops|\bsre\b|infra|platform|cloud|reliability/],
  ["Software Engineer", /software|\bswe?\b|\bse\b|\bjse\b|\base\b|developer|engineer|programmer/],
];
const roleFamily = t => (FAMILIES.find(([, re]) => re.test(lc0(t))) || ["Other"])[0];
function levelOf(t) {
  const s = lc0(t);
  if (/\bintern(ship)?\b/.test(s)) return "Intern";
  if (/senior|\bsr\.?\b|staff|principal|\blead\b|\biii\b|\biv\b|founding|head of/.test(s)) return "Senior+";
  if (/junior|\bjr\.?\b|\bjse\b|\bjfse\b|\base\b|associate|entry|new grad|early career|graduate|apprentice|\bi\b/.test(s)) return "Junior / Entry";
  if (/\bii\b|mid[- ]level/.test(s)) return "Mid (II)";
  return "Unspecified";
}
const BANDS = [[0, 80e3, "Under $80,000"], [80e3, 100e3, "$80,000-100,000"], [100e3, 120e3, "$100,000-120,000"], [120e3, 140e3, "$120,000-140,000"],
  [140e3, 160e3, "$140,000-160,000"], [160e3, 200e3, "$160,000-200,000"], [200e3, Infinity, "$200,000+"]];
const bandOf = s => s ? BANDS.find(([a, b]) => s.mid >= a && s.mid < b)[2] : "No salary listed";
const bandQuery = label => { const [a, b] = BANDS.find(x => x[2] === label); return b === Infinity ? `salary:>=${a / 1e3}k` : a ? `salary:${a / 1e3}k-${b / 1e3}k` : `salary:<${b / 1e3}k`; };
const quantile = (arr, p) => d3.quantileSorted(arr, p);

const GROUPS = {
  family: { label: "Role type", key: j => roleFamily(j.title), q: g => `type:"${g}"` },
  level: { label: "Level", key: j => levelOf(j.title), q: g => `level:"${g}"`, order: ["Intern", "Junior / Entry", "Unspecified", "Mid (II)", "Senior+"] },
  city: { label: "Location", key: cityOf, q: g => `city:"${g}"` },
  band: { label: "Salary band", key: j => bandOf(salaryOf(j)), q: g => g === "No salary listed" ? "has:nosalary" : bandQuery(g), order: [...BANDS.map(b => b[2]), "No salary listed"] },
  stage: { label: "Furthest stage", key: j => furthest(j), q: g => `reached:"${g}"`, order: STAGES_ORDER() },
  title: { label: "Exact title", key: j => j.title.trim() || "(blank)", q: g => `role:"${g}"`, top: 25 },
};
function STAGES_ORDER() { return ["Applied", "Followed Up", "Recruiter Screen", "Hiring Manager", "Technical Interview", "Take-home", "Final Round", "Work Trial", "Offer", "Accepted"]; }

function renderSalary() {
  const list = visible(), withPay = list.map(j => [j, salaryOf(j)]).filter(([, s]) => s);
  const mids = withPay.map(([, s]) => s.mid).sort(d3.ascending);
  $("#salTitle").textContent = cityPick() ? `Salary · ${cityPick()}` : "Salary";
  if (!mids.length) { $("#salStats").innerHTML = `<p class="sub">No salaries in this view yet. Add one like 120k or 100–140k.</p>`; $("#salHist").innerHTML = $("#salRows").innerHTML = ""; return; }
  const top = withPay.reduce((a, b) => b[1].max > a[1].max ? b : a);
  $("#salStats").innerHTML = [
    ["Roles with salary", `${withPay.length}<small> / ${list.length}</small>`],
    ["Average", money1k(d3.mean(mids))], ["Median", money1k(quantile(mids, .5))],
    ["Middle 50%", range(quantile(mids, .25), quantile(mids, .75), money1k)],
    ["Highest posted", `${money(top[1].max)}<small> ${esc(top[0].company)}</small>`],
  ].map(([k, v]) => `<div class="stat"><b>${v}</b><span>${k}</span></div>`).join("");

  // Histogram of midpoints by band; click a bar to search that band.
  const byBand = d3.rollup(withPay, v => v.length, ([, s]) => bandOf(s)), maxB = Math.max(...byBand.values());
  $("#salHist").innerHTML = BANDS.map(([, , label]) => {
    const n = byBand.get(label) || 0;
    return `<button class="hbar" data-q="${esc(bandQuery(label))}" title="${n} roles · click to list them">
      <span class="hv">${n || ""}</span><span class="hcol"><i style="height:${100 * n / maxB}%"></i></span><span class="hl">${label}</span></button>`;
  }).join("");

  // Grouped table.
  const G = GROUPS[$("#salGroup").value];
  let groups = d3.groups(list, G.key).map(([name, jobs]) => {
    const s = jobs.map(salaryOf).filter(Boolean), m = s.map(x => x.mid).sort(d3.ascending);
    return { name, jobs, n: s.length, avg: d3.mean(m), med: m.length ? quantile(m, .5) : null,
      lo: m.length ? quantile(m, .25) : null, hi: m.length ? quantile(m, .75) : null,
      min: d3.min(s, x => x.min), max: d3.max(s, x => x.max),
      resp: jobs.filter(responded).length / jobs.length, sc: jobs.filter(screenedJ).length, iv: jobs.filter(pastScreenJ).length };
  });
  if (G.order) groups.sort((a, b) => G.order.indexOf(a.name) - G.order.indexOf(b.name));
  else groups.sort((a, b) => (b.med ?? -1) - (a.med ?? -1) || b.jobs.length - a.jobs.length);
  if (G.top) groups = groups.filter(g => g.n >= 2).slice(0, G.top);
  const scaleMax = quantile(withPay.map(([, s]) => s.max).sort(d3.ascending), .98) * 1.05, x = v => `${Math.min(100, 100 * v / scaleMax)}%`;
  $("#salHead").textContent = G.label;
  $("#salRows").innerHTML = groups.map(g => `<tr data-q="${esc(G.q(g.name))}">
    <td><b>${esc(g.name)}</b></td>
    <td>${g.jobs.length}${g.n !== g.jobs.length ? ` <span class="sub" style="margin:0">(${g.n} w/ pay)</span>` : ""}</td>
    <td>${g.n ? money1k(g.avg) : "—"}</td>
    <td>${g.n ? money1k(g.med) : "—"}</td>
    <td class="hide-sm">${g.n ? `<span class="range" title="Lowest ${money(g.min)} · middle 50% ${range(g.lo, g.hi, money1k)} · highest ${money(g.max)}">
        <span class="whisk" style="left:${x(g.min)};width:calc(${x(g.max)} - ${x(g.min)})"></span>
        <span class="iqr" style="left:${x(g.lo)};width:max(4px, calc(${x(g.hi)} - ${x(g.lo)}))"></span>
        <span class="med" style="left:${x(g.med)}"></span></span>` : ""}</td>
    <td>${Math.round(100 * g.resp)}%</td>
    <td>${pct1(g.sc, g.jobs.length)}</td>
    <td>${pct1(g.iv, g.jobs.length)}</td></tr>`).join("");
}
$("#salGroup").addEventListener("change", renderSalary);
// Clicking a histogram bar or table row lists those roles in the table below.
const searchFor = q => { $("#q").value = q; refilter(); $("#q").scrollIntoView({ behavior: "smooth", block: "center" }); };
$("#salHist").addEventListener("click", e => { const b = e.target.closest(".hbar"); if (b) searchFor(b.dataset.q); });
$("#salRows").addEventListener("click", e => { const tr = e.target.closest("tr"); if (tr) searchFor(tr.dataset.q); });

// Location inputs (add form + detail panel) only accept values from the list.
const canonLoc = v => LOCS.find(l => l.toLowerCase() === String(v).trim().toLowerCase());
function checkLoc(input) {
  const v = input.value.trim(), c = canonLoc(v);
  if (c && c !== input.value) input.value = c;
  input.setCustomValidity(!v || c ? "" : "Pick a location from the list (search or click the suggestions).");
}
document.addEventListener("input", e => { if (e.target.matches("input[name=location]")) checkLoc(e.target); });
document.addEventListener("change", e => { if (e.target.matches("input[name=location]")) { checkLoc(e.target); e.target.reportValidity(); } });

function renderApplications() {
  renderGoals(); renderCities(); renderStats(); renderChart(); renderSalary(); renderTable();
  $("#pipeTitle").textContent = cityPick() ? `Pipeline · ${cityPick()}` : "Pipeline";
}
function render() {
  $("#tabApps .count").textContent = jobs.length.toLocaleString();
  $("#tabRefs .count").textContent = referrals.length;
  ({ applications: renderApplications, referrals: renderReferrals, together: renderTogether })[view]();
}
function replaceJob(job) { jobs[jobs.findIndex(j => j.id === job.id)] = job; render(); }

async function addJob(form) {
  const data = Object.fromEntries(new FormData(form));
  if (!data.url && !data.company) { $("#msg").textContent = "Add a link or at least a company name."; return; }
  $("#msg").textContent = "Fetching job details…";
  const job = await api("/api/jobs", { method: "POST", body: JSON.stringify(data) });
  $("#msg").textContent = job.error ? `Error: ${job.error}` : `${job.duplicate ? "Already logged" : "Logged"}: ${job.company} — ${job.title}`;
  if (job.error) return;
  form.reset(); await load();
  // Heads-up when you've applied to this company before.
  const prior = jobs.filter(j => j.id !== job.id && job.company && lc0(j.company).trim() === lc0(job.company).trim());
  if (prior.length && !job.duplicate) {
    const last = prior.sort((a, b) => (b.applied_on || "").localeCompare(a.applied_on || ""))[0];
    $("#msg").insertAdjacentHTML("beforeend", ` · <span class="link" id="seePrior">You've applied to ${esc(job.company)} ${prior.length}× before</span>
      (latest ${esc(last.applied_on)}: ${esc(last.title)}, ${esc(stageOf(last))})`);
    $("#seePrior").onclick = () => { $("#q").value = `company:"${job.company}"`; refilter(); $("#q").scrollIntoView({ block: "center" }); };
  }
}
$("#add").addEventListener("submit", e => { e.preventDefault(); addJob(e.target); });
$("#openlog").addEventListener("click", () => { const f = $("#add"); if (!f.reportValidity()) return; if (f.url.value) window.open(f.url.value, "_blank"); addJob(f); });

// ---- City grouping: derived from each job's location text (no separate field) ----
// A named city wins over "remote" ("SF (remote at first)" is still an SF job), so Remote comes last.
const CITY_RULES = [
  [/\bsf\b|san francisco|bay area|palo alto|menlo park|mountain view|san mateo|redwood city|oakland|berkeley|san jose|sunnyvale|cupertino|santa clara|foster city|south san francisco/i, "SF Bay Area"],
  [/charleston|mount pleasant|mt\.? pleasant|summerville|goose creek|ladson|daniel island|johns island|hanahan|moncks corner/i, "Charleston"],
  [/new york|\bnyc\b|manhattan|brooklyn/i, "New York"],
  [/other-?town/i, "Other"],
  [/remote|anywhere|work from home|wfh/i, "Remote"],
];
function cityOf(j) {
  const loc = String(j.location || "").trim();
  if (!loc) return "Unknown";
  const rule = CITY_RULES.find(([re]) => re.test(loc));
  return rule ? rule[1] : loc.split(/[,(]/)[0].trim();
}
let cityInit = new URLSearchParams(location.search).get("city") || ""; // e.g. /?city=Charleston
const cityPick = () => $("#city").value;
const visible = () => cityPick() ? jobs.filter(j => cityOf(j) === cityPick()) : jobs;

const responded = j => path(j).some(h => !["Applied", "Followed Up", PENDING].includes(h.stage));
const interviewedJ = j => j.history.some(h => INTERVIEWS.has(h.stage)); // recruiter screen or further
const screenedJ = interviewedJ;
// A real interview past the recruiter screen (hiring manager, technical, take-home, final, trial, offer).
const pastScreenJ = j => j.history.some(h => INTERVIEWS.has(h.stage) && h.stage !== "Recruiter Screen");
const pct1 = (n, d) => d ? (n ? (100 * n / d).toFixed(1) : "0") + "%" : "—";
const furthest = j => path(j).filter(h => !ENDINGS.has(h.stage) && h.stage !== PENDING).at(-1)?.stage || "Applied";

function renderStats() {
  const list = visible();
  const reached = s => list.filter(j => j.history.some(h => h.stage === s)).length;
  const last30 = list.filter(j => j.applied_on && (Date.now() - new Date(j.applied_on)) < 30 * 864e5).length;
  const screens = list.filter(screenedJ).length, interviews = list.filter(pastScreenJ).length;
  $("#stats").innerHTML = [
    ["Total applied", list.length], ["Last 30 days", last30], ["Got a response", list.filter(responded).length],
    ["Recruiter screens", screens], ["Interviews", interviews], ["Final rounds", reached("Final Round")], ["Offers", reached("Offer")],
    ["Rejected", reached("Rejected")], ["Ghosted", reached("Ghosted")],
    ["Screen rate", pct1(screens, list.length), "Reached a recruiter screen or further"],
    ["Interview rate", pct1(interviews, list.length), "Got past the screen: hiring manager, technical, take-home, final round, trial or offer"],
    ["Screen → interview", pct1(interviews, screens), "Share of recruiter screens that turned into a real interview"],
  ].map(([k, v, tip]) => `<div class="stat"${tip ? ` title="${tip}"` : ""}><b>${v}</b><span>${k}</span></div>`).join("");
}

// City dropdown + "By location" breakdown (click a row to filter everything to that city).
function renderCities() {
  const groups = d3.groups(jobs, cityOf).sort((a, b) => b[1].length - a[1].length);
  const sel = $("#city"), cur = sel.value || cityInit; cityInit = "";
  sel.innerHTML = `<option value="">All locations (${jobs.length})</option>` +
    groups.map(([c, l]) => `<option value="${esc(c)}">${esc(c)} (${l.length})</option>`).join("");
  sel.value = groups.some(([c]) => c === cur) ? cur : "";
  const maxN = groups[0]?.[1].length || 1;
  $("#cities").innerHTML = groups.map(([c, l]) => {
    const sc = l.filter(screenedJ).length, iv = l.filter(pastScreenJ).length, rs = l.filter(responded).length;
    const cnt = n => `${n}${n ? ` <span class="sub" style="margin:0">(${pct1(n, l.length)})</span>` : ""}`;
    const best = l.map(furthest).reduce((a, b) => STAGES.indexOf(b) > STAGES.indexOf(a) ? b : a, "Applied");
    return `<tr data-city="${esc(c)}" class="${c === sel.value ? "on" : ""}">
      <td><b>${esc(c)}</b></td>
      <td><span class="bar"><i style="width:${100 * l.length / maxN}%"></i></span>${l.length}</td>
      <td>${Math.round(100 * rs / l.length)}%</td>
      <td>${cnt(sc)}</td>
      <td>${cnt(iv)}</td>
      <td><span class="pill" style="border-color:${color(best)};color:${color(best)}">${esc(best)}</span></td></tr>`;
  }).join("");
}
$("#cities").addEventListener("click", e => {
  const tr = e.target.closest("tr"); if (!tr) return;
  $("#city").value = $("#city").value === tr.dataset.city ? "" : tr.dataset.city;
  onCity();
});
function onCity() {
  const u = new URL(location); cityPick() ? u.searchParams.set("city", cityPick()) : u.searchParams.delete("city");
  history.replaceState(null, "", u);
  $("#drill").innerHTML = ""; render();
}
$("#city").addEventListener("change", onCity);

function chartJobs() {
  const days = +$("#range").value, scope = $("#scope").value;
  return visible().filter(j => {
    if (days && !(j.applied_on && (Date.now() - new Date(j.applied_on)) < days * 864e5)) return false;
    if (scope === "responded") return path(j).some(h => !["Applied", "Followed Up", PENDING].includes(h.stage));
    if (scope === "interviewed") return j.history.some(h => INTERVIEWS.has(h.stage));
    return true;
  });
}

function renderChart() {
  const subset = chartJobs(), flows = new Map();
  for (const j of subset) {
    const p = path(j);
    for (let i = 1; i < p.length; i++) {
      const k = p[i - 1].stage + "→" + p[i].stage;
      if (!flows.has(k)) flows.set(k, []);
      flows.get(k).push(j);
    }
  }
  const el = $("#chart");
  if (!flows.size) { el.innerHTML = `<p class="sub">Nothing in this view yet.</p>`; return; }
  const names = [...new Set([...flows.keys()].flatMap(k => k.split("→")))];
  const total = subset.length, pct = n => n / total < 0.01 && n ? "<1%" : `${Math.round(100 * n / total)}%`;
  // True per-stage counts (labels/tooltips always use these, even when widths are compressed).
  const counts = new Map();
  for (const j of subset) for (const h of path(j)) counts.set(h.stage, (counts.get(h.stage) || 0) + 1);
  const count = d => counts.get(d.name) || 0;
  // sqrt widths keep a 13-application stage visible next to 870 "no response" ones.
  const sizes = [...flows.values()].map(l => l.length);
  const compress = $("#compress").checked && Math.max(...sizes) > 20 * Math.min(...sizes), size = n => compress ? Math.sqrt(n) : n;
  const W = 1100, H = Math.max(360, Math.min(640, names.length * 56)), M = { t: 16, r: 200, b: 16, l: 8 };
  const { nodes, links } = d3.sankey().nodeId(d => d.name).nodeAlign(d3.sankeyLeft).nodeWidth(18).nodePadding(30)
    .nodeSort((a, b) => STAGES.indexOf(a.name) - STAGES.indexOf(b.name)).extent([[M.l, M.t], [W - M.r, H - M.b]])({
      nodes: names.map(name => ({ name })),
      links: [...flows].map(([k, list]) => { const [source, target] = k.split("→"); return { source, target, value: size(list.length), count: list.length, jobs: list }; }),
    });

  const svg = d3.create("svg").attr("viewBox", [0, 0, W, H]).attr("role", "img")
    .attr("aria-label", `Application pipeline: ${nodes.map(n => `${n.name} ${count(n)}`).join(", ")}`);
  const defs = svg.append("defs");
  // Each flow fades from its source stage's color to its target's.
  links.forEach((d, i) => {
    d.gid = `g${i}`;
    const g = defs.append("linearGradient").attr("id", d.gid).attr("gradientUnits", "userSpaceOnUse")
      .attr("x1", d.source.x1).attr("x2", d.target.x0);
    g.append("stop").attr("offset", "0%").attr("stop-color", color(d.source.name));
    g.append("stop").attr("offset", "100%").attr("stop-color", color(d.target.name));
  });
  defs.append("filter").attr("id", "glow").attr("x", "-50%").attr("width", "200%")
    .append("feDropShadow").attr("dx", 0).attr("dy", 0).attr("stdDeviation", 3).attr("flood-opacity", .35);

  const link = svg.append("g").attr("fill", "none").selectAll("path").data(links).join("path")
    .attr("class", "flow").attr("d", d3.sankeyLinkHorizontal()).attr("stroke", d => `url(#${d.gid})`)
    .attr("stroke-width", d => Math.max(3, d.width))
    .on("click", (_, d) => drill(`${d.source.name} → ${d.target.name}`, d.jobs, d.target.name));
  const node = svg.append("g").selectAll("g").data(nodes).join("g").attr("class", "node")
    .on("click", (_, d) => drill(d.name, subset.filter(j => path(j).some(h => h.stage === d.name)), d.name));
  node.append("rect").attr("x", d => d.x0).attr("y", d => d.y0).attr("width", d => d.x1 - d.x0)
    .attr("height", d => Math.max(4, d.y1 - d.y0)).attr("rx", 5).attr("fill", d => color(d.name)).attr("filter", "url(#glow)");
  const label = node.append("text").attr("x", d => d.x1 + 10).attr("y", d => (d.y0 + d.y1) / 2).attr("dy", "-0.15em");
  label.append("tspan").attr("class", "lname").text(d => d.name);
  label.append("tspan").attr("class", "lnum").attr("x", d => d.x1 + 10).attr("dy", "1.25em")
    .text(d => `${count(d).toLocaleString()} · ${pct(count(d))}`);

  // Hover: spotlight the hovered stage/flow and everything it touches.
  const tip = $("#tip");
  const focus = (keepLink, keepNode) => {
    link.classed("dim", l => !keepLink(l));
    node.classed("dim", n => !keepNode(n));
  };
  const clear = () => { link.classed("dim", false); node.classed("dim", false); tip.hidden = true; };
  const showTip = (e, html) => {
    tip.innerHTML = html; tip.hidden = false;
    const r = el.getBoundingClientRect(), x = e.clientX - r.left, y = e.clientY - r.top;
    tip.style.left = `${Math.min(x + 14, r.width - tip.offsetWidth - 4)}px`; tip.style.top = `${y + 14}px`;
  };
  node.on("mousemove", (e, d) => {
    focus(l => l.source === d || l.target === d, n => n === d || d.sourceLinks.some(l => l.target === n) || d.targetLinks.some(l => l.source === n));
    const out = [...d.sourceLinks].sort((a, b) => b.count - a.count)
      .map(l => `<div><i style="background:${color(l.target.name)}"></i>${esc(l.target.name)}<b>${l.count} · ${Math.round(100 * l.count / count(d))}%</b></div>`).join("");
    showTip(e, `<strong>${esc(d.name)}</strong><span>${count(d).toLocaleString()} applications · ${pct(count(d))} of all</span>${out ? `<hr>${out}` : ""}`);
  }).on("mouseleave", clear);
  link.on("mousemove", (e, d) => {
    focus(l => l === d, n => n === d.source || n === d.target);
    showTip(e, `<strong>${esc(d.source.name)} → ${esc(d.target.name)}</strong><span>${d.count} of ${count(d.source)} (${Math.round(100 * d.count / count(d.source))}%) went this way</span>`);
  }).on("mouseleave", clear);

  el.replaceChildren(svg.node(), tip);

  // Draw-in animation (skipped for reduced motion).
  if (!matchMedia("(prefers-reduced-motion: reduce)").matches) {
    link.each(function () { const len = this.getTotalLength(); d3.select(this).attr("stroke-dasharray", `${len} ${len}`).attr("stroke-dashoffset", len); })
      .transition().duration(900).delay(d => d.source.depth * 180).ease(d3.easeCubicOut).attr("stroke-dashoffset", 0)
      .on("end", function () { d3.select(this).attr("stroke-dasharray", null); });
    node.attr("opacity", 0).transition().duration(500).delay(d => d.depth * 180).attr("opacity", 1);
  }
}

// Lists the jobs behind a clicked node/flow, with that stage's date and note.
function drill(label, list, stage) {
  const ev = j => path(j).find(h => h.stage === stage) || {};
  const sorted = [...list].sort((a, b) => (ev(b).on || b.applied_on || "").localeCompare(ev(a).on || a.applied_on || ""));
  $("#drill").innerHTML = `<div class="row spread"><b>${esc(label)} · ${list.length}</b><button class="ghost" id="closeDrill">Close</button></div>` +
    sorted.slice(0, 200).map(j => `<div class="drill-item" data-id="${j.id}">
      <span class="sub" style="margin:0">${esc(ev(j).on || j.applied_on)}</span>
      <span><b>${esc(j.company)}</b> — ${esc(j.title)} <span class="pill">${esc(stageOf(j))}</span></span>
      ${ev(j).note ? `<span class="note">${esc(ev(j).note)}</span>` : ""}</div>`).join("") +
    (list.length > 200 ? `<p class="sub">Showing 200 of ${list.length}. Use the filters above to narrow it.</p>` : "");
  $("#drill").scrollIntoView({ behavior: "smooth", block: "nearest" });
}
$("#drill").addEventListener("click", e => {
  if (e.target.id === "closeDrill") return void ($("#drill").innerHTML = "");
  const item = e.target.closest(".drill-item"); if (item) openDetail(item.dataset.id);
});
$("#range").addEventListener("change", () => { $("#drill").innerHTML = ""; renderChart(); });
$("#scope").addEventListener("change", () => { $("#drill").innerHTML = ""; renderChart(); });
$("#compress").addEventListener("change", renderChart);

// ---- Search: free words + field filters, sortable, paged ----
const PAGE = 50;
let sortKey = "applied_on", sortDir = -1, page = 0, lastShown = [];

// `stripe company:"Acme Inc" -contract after:2026-03` → { words: [...], not: [...], f: { company: [...], ... } }
function parseQuery(q) {
  const out = { words: [], not: [], f: {} };
  for (const m of q.matchAll(/(-)?(?:(\w+):)?(?:"([^"]*)"|(\S+))/g)) {
    const [, neg, key, quoted, bare] = m, val = (quoted ?? bare ?? "").toLowerCase();
    if (!val) continue;
    if (key) (out.f[key.toLowerCase()] ||= []).push(val);
    else (neg ? out.not : out.words).push(val);
  }
  return out;
}
const hay = j => [j.company, j.title, j.notes, j.location, cityOf(j), j.pay, j.url, ...j.history.map(h => `${h.stage} ${h.note}`)].join(" ").toLowerCase();
function matches(j, { words, not, f }) {
  const h = hay(j), lc = s => String(s || "").toLowerCase(), any = (k, test) => !f[k] || f[k].every(test);
  return words.every(w => h.includes(w)) && !not.some(w => h.includes(w))
    && any("company", v => lc(j.company).includes(v))
    && any("role", v => lc(j.title).includes(v)) && any("title", v => lc(j.title).includes(v))
    && any("stage", v => lc(stageOf(j)).includes(v))
    && any("reached", v => j.history.some(e => lc(e.stage).includes(v)))
    && any("city", v => lc(cityOf(j)).includes(v)) && any("loc", v => lc(j.location).includes(v) || lc(cityOf(j)).includes(v))
    && any("after", v => (j.applied_on || "") >= v) && any("before", v => (j.applied_on || "9") < v)
    && any("has", v => v === "notes" ? !!(j.notes || j.history.some(e => e.note)) : v === "link" ? !!j.url : v === "pay" || v === "salary" ? !!salaryOf(j) : v === "nosalary" ? !salaryOf(j) : true)
    && any("type", v => lc(roleFamily(j.title)).includes(v)) && any("level", v => lc(levelOf(j.title)).includes(v))
    && any("salary", v => salaryMatch(salaryOf(j), v));
}
const SORTS = {
  applied_on: j => j.applied_on || "", company: j => lc0(j.company), title: j => lc0(j.title),
  city: j => lc0(cityOf(j)), pay: j => salaryOf(j)?.mid ?? -1, stage: j => STAGES.indexOf(stageOf(j)),
};
const lc0 = s => String(s || "").toLowerCase();

// How many times each company appears, for the ×N badge.
const companyCounts = () => d3.rollup(jobs, v => v.length, j => lc0(j.company).trim());

function renderMonths() {
  const sel = $("#month"), cur = sel.value;
  const months = d3.rollups(visible().filter(j => j.applied_on), v => v.length, j => j.applied_on.slice(0, 7)).sort((a, b) => b[0].localeCompare(a[0]));
  const fmt = m => new Date(m + "-15").toLocaleString(undefined, { month: "short", year: "numeric" });
  sel.innerHTML = `<option value="">Any month</option>` + months.map(([m, n]) => `<option value="${m}">${fmt(m)} (${n})</option>`).join("");
  sel.value = months.some(([m]) => m === cur) ? cur : "";
}

function renderTable() {
  renderMonths();
  const query = parseQuery($("#q").value), sf = $("#stageFilter").value, month = $("#month").value, iv = $("#ivOnly").checked;
  const key = SORTS[sortKey];
  const shown = visible().filter(j => (!sf || stageOf(j) === sf) && (!month || (j.applied_on || "").startsWith(month))
    && (!iv || interviewedJ(j)) && matches(j, query))
    .sort((a, b) => { const x = key(a), y = key(b); return (x < y ? -1 : x > y ? 1 : 0) * sortDir; });
  lastShown = shown;
  const pages = Math.max(1, Math.ceil(shown.length / PAGE));
  page = Math.min(page, pages - 1);
  const from = page * PAGE, slice = shown.slice(from, from + PAGE), counts = companyCounts();

  $("#resultInfo").textContent = shown.length
    ? `${from + 1}–${from + slice.length} of ${shown.length.toLocaleString()}${shown.length !== visible().length ? ` (filtered from ${visible().length.toLocaleString()})` : ""}`
    : "No matches";
  $("#pager").innerHTML = pages > 1 ? `<button class="ghost" data-pg="first" ${page ? "" : "disabled"}>«</button>
    <button class="ghost" data-pg="prev" ${page ? "" : "disabled"}>‹ Prev</button>
    <span class="sub" style="margin:0">Page ${page + 1} / ${pages}</span>
    <button class="ghost" data-pg="next" ${page < pages - 1 ? "" : "disabled"}>Next ›</button>
    <button class="ghost" data-pg="last" ${page < pages - 1 ? "" : "disabled"}>»</button>` : "";
  document.querySelectorAll("#sortRow th[data-sort]").forEach(th =>
    th.dataset.dir = th.dataset.sort === sortKey ? (sortDir > 0 ? "asc" : "desc") : "");

  $("#rows").innerHTML = slice.map(j => {
    const n = counts.get(lc0(j.company).trim()) || 0;
    return `
    <tr data-id="${j.id}">
      <td>${esc(j.applied_on)}</td>
      <td><span class="link open">${esc(j.company) || "(no company)"}</span>${n > 1 ? ` <span class="pill cmp" data-company="${esc(j.company)}" title="Show all ${n} applications to ${esc(j.company)}">×${n}</span>` : ""}</td>
      <td><span class="edit" data-f="title" contenteditable>${esc(j.title)}</span></td>
      <td class="hide-sm"><span class="link open" title="Change in the detail panel">${esc(j.location) || "—"}</span></td>
      <td class="hide-sm" style="white-space:nowrap"><span class="edit" data-f="pay" contenteditable data-shown="${esc(payShown(j))}">${esc(payShown(j))}</span></td>
      <td><select class="stage">${options(stageOf(j))}</select></td>
      <td class="notes hide-sm"><span class="edit" data-f="notes" contenteditable>${esc(j.notes)}</span></td>
      <td style="white-space:nowrap">${j.url ? `<a href="${esc(j.url)}" target="_blank" rel="noopener" title="Open posting">↗</a> ` : ""}<button class="ghost del" title="Delete">✕</button></td>
    </tr>`; }).join("");
}

const refilter = () => { page = 0; renderTable(); };
let qTimer;
$("#q").addEventListener("input", () => { clearTimeout(qTimer); qTimer = setTimeout(refilter, 120); });
$("#stageFilter").addEventListener("change", refilter);
$("#month").addEventListener("change", refilter);
$("#ivOnly").addEventListener("change", refilter);
$("#pager").addEventListener("click", e => {
  const pg = e.target.dataset.pg; if (!pg) return;
  const pages = Math.ceil(lastShown.length / PAGE);
  page = { first: 0, prev: page - 1, next: page + 1, last: pages - 1 }[pg];
  renderTable(); $(".table-wrap").scrollTop = 0;
});
$("#sortRow").addEventListener("click", e => {
  const k = e.target.closest("th")?.dataset.sort; if (!k) return;
  sortDir = k === sortKey ? -sortDir : (k === "applied_on" || k === "stage" ? -1 : 1);
  sortKey = k; refilter();
});
// ×N badge → show every application to that company.
$("#rows").addEventListener("click", e => {
  if (!e.target.matches(".cmp")) return;
  $("#q").value = `company:"${e.target.dataset.company}"`; refilter();
});
// Keyboard: "/" focuses search, Enter opens a single match, Esc clears.
document.addEventListener("keydown", e => {
  if (e.key === "/" && !e.target.closest("input, textarea, select, [contenteditable], dialog")) { e.preventDefault(); $("#q").focus(); }
});
$("#q").addEventListener("keydown", e => {
  if (e.key === "Escape") { $("#q").value = ""; refilter(); }
  if (e.key === "Enter") { clearTimeout(qTimer); refilter(); if (lastShown.length === 1) openDetail(lastShown[0].id); }
});

$("#rows").addEventListener("change", async e => {
  if (!e.target.matches(".stage")) return;
  const id = e.target.closest("tr").dataset.id;
  replaceJob(await api(`/api/jobs/${id}`, { method: "PATCH", body: JSON.stringify({ stage: e.target.value }) }));
});
$("#rows").addEventListener("focusout", async e => {
  if (!e.target.matches(".edit")) return;
  const id = e.target.closest("tr").dataset.id, f = e.target.dataset.f, val = e.target.innerText.trim();
  const job = byId(id);
  if (val === (e.target.dataset.shown ?? job[f])) return; // just focused, nothing typed
  if (job[f] !== val) { job[f] = val; await api(`/api/jobs/${id}`, { method: "PATCH", body: JSON.stringify({ [f]: val }) }); }
});
$("#rows").addEventListener("click", async e => {
  const tr = e.target.closest("tr"); if (!tr) return;
  if (e.target.matches(".open")) return openDetail(tr.dataset.id);
  if (!e.target.matches(".del")) return;
  const job = byId(tr.dataset.id);
  if (!confirm(`Delete ${job.company} — ${job.title}?`)) return;
  await api(`/api/jobs/${job.id}`, { method: "DELETE" });
  jobs = jobs.filter(j => j !== job); render();
});

// ---- Detail panel: job info + editable timeline ----
function openDetail(id) {
  const j = byId(id), d = $("#detail");
  d.dataset.id = id;
  d.innerHTML = `
    <div class="row spread"><h2>${esc(j.company)}</h2><button class="ghost" data-act="close">Close</button></div>
    <form data-act="info" class="grid2" style="margin-top:12px">
      <label>Company<input name="company" value="${esc(j.company)}"></label>
      <label>Role<input name="title" value="${esc(j.title)}"></label>
      <label>Location<input name="location" list="cityList" value="${esc(j.location)}"></label>
      <label>Salary <span class="payPreview">${payPreview(j.pay)}</span>
        <input name="pay" value="${esc(j.pay)}" placeholder="120k · 100–140k · $45/hr"></label>
      <label>Applied on<input type="date" name="applied_on" value="${esc(j.applied_on)}"></label>
      <label>Posting link<input name="url" value="${esc(j.url)}"></label>
      <label style="grid-column:1/-1">Notes<textarea name="notes">${esc(j.notes)}</textarea></label>
      <div><button>Save details</button></div>
    </form>
    <h2 style="margin-top:18px">Timeline</h2>
    <ul class="timeline">${j.history.map((h, i) => `
      <li style="--dot:${color(h.stage)}"><form class="ev" data-act="event" data-i="${i}">
        <select name="stage">${options(h.stage)}</select>
        <input type="date" name="on" value="${esc(h.on)}">
        <span class="row"><button>Save</button><button type="button" class="ghost" data-act="delev" data-i="${i}">✕</button></span>
        <textarea name="note" placeholder="What happened? Who did you talk to, what did they ask, next steps…">${esc(h.note)}</textarea>
      </form></li>`).join("")}
    </ul>
    <h2>Add a step</h2>
    <form class="timeline ev" data-act="addev" style="border:none;padding:0">
      <select name="stage">${options(nextStage(j))}</select>
      <input type="date" name="on" value="${new Date().toISOString().slice(0, 10)}">
      <button>Add</button>
      <textarea name="note" placeholder="Notes for this step"></textarea>
    </form>`;
  if (!d.open) d.showModal();
}
const nextStage = j => STAGES[Math.min(STAGES.indexOf(stageOf(j)) + 1, STAGES.indexOf("Accepted"))] || "Recruiter Screen";

$("#detail").addEventListener("submit", async e => {
  e.preventDefault();
  const id = $("#detail").dataset.id, f = e.target, data = Object.fromEntries(new FormData(f));
  const req = { info: [`/api/jobs/${id}`, "PATCH"], event: [`/api/jobs/${id}/events/${f.dataset.i}`, "PATCH"], addev: [`/api/jobs/${id}/events`, "POST"] }[f.dataset.act];
  const job = await api(req[0], { method: req[1], body: JSON.stringify(data) });
  if (job.error) return alert(job.error);
  replaceJob(job); openDetail(id);
});
$("#detail").addEventListener("click", async e => {
  const act = e.target.dataset.act;
  if (act === "close" || e.target === $("#detail")) return $("#detail").close();
  if (act !== "delev" || !confirm("Remove this step?")) return;
  const id = $("#detail").dataset.id;
  const job = await api(`/api/jobs/${id}/events/${e.target.dataset.i}`, { method: "DELETE" });
  if (job.error) return alert(job.error);
  replaceJob(job); openDetail(id);
});

const scope = new URLSearchParams(location.search).get("scope"); // e.g. /?scope=interviewed
if (scope) $("#scope").value = scope;
showView();
load();
addEventListener("themechange", () => { if (jobs.length) render(); }); // charts read colors when they draw

// Live salary preview in the detail panel (an event listener, since the page allows no inline handlers).
document.addEventListener("input", e => {
  const preview = e.target.previousElementSibling;
  if (e.target.name === "pay" && preview?.classList.contains("payPreview")) preview.innerHTML = payPreview(e.target.value);
});
