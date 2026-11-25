// ---- Interviews tab: every interview step, a prep workspace for the selected one, and the prep library ----
// Loaded after app.js and calendar.js; uses their helpers (api, esc, jobs, referrals, upcomingInterviews, icsFor…).
let companies = [], prepLib = [], checklist = [], ivPick = "";
const companyOf = name => companies.find(c => c.name.trim().toLowerCase() === String(name || "").trim().toLowerCase());
const ivKey = (job, i) => `${job.id}:${i}`;
const enc = encodeURIComponent;

async function loadPrep() {
  const [cs, prep] = await Promise.all([api("/api/companies"), api("/api/prep")]);
  companies = cs; ({ notes: prepLib, checklist } = prep);
}

// Upcoming soonest first, then past (and undated) most recent first.
function allInterviews() {
  const today = ymd(new Date());
  const all = jobs.flatMap(job => job.history.map((step, i) => ({ job, step, i })))
    .filter(({ step }) => MEETING_STAGES.includes(step.stage));
  const up = upcomingInterviews(jobs, today);
  const past = all.filter(x => !(x.step.on && x.step.on >= today))
    .sort((a, b) => (b.step.on + (b.step.at || "")).localeCompare(a.step.on + (a.step.at || "")));
  return { up, past };
}

function renderInterviews() {
  const { up, past } = allInterviews();
  const row = x => `<li data-k="${ivKey(x.job, x.i)}" class="${ivKey(x.job, x.i) === ivPick ? "picked" : ""}">
    <button type="button" class="iv-pick"><b>${esc(x.step.on ? whenText(x.step.on, x.step.at) : "No date")}</b> · ${esc(x.step.stage)}
      <span class="sub">${esc(x.job.company) || "(no company)"}${x.job.title ? ` · ${esc(x.job.title)}` : ""}</span></button></li>`;
  if (!ivPick || ![...up, ...past].some(x => ivKey(x.job, x.i) === ivPick)) ivPick = (up[0] || past[0]) ? ivKey((up[0] || past[0]).job, (up[0] || past[0]).i) : "";
  $("#ivUp").innerHTML = up.map(row).join("") || `<li class="sub" style="margin:0">Nothing scheduled.</li>`;
  $("#ivPast").innerHTML = past.map(row).join("") || `<li class="sub" style="margin:0">No past interviews yet.</li>`;
  $("#ivPastHead").textContent = `Past (${past.length})`;
  document.querySelectorAll("#ivLists li[data-k]").forEach(li => li.classList.toggle("picked", li.dataset.k === ivPick));
  renderWorkspace();
  renderPrepLib();
}

function renderWorkspace() {
  const ws = $("#ivWork");
  const [id, i] = ivPick.split(":"), job = jobs.find(j => j.id === id), step = job?.history[i];
  if (!step) {
    ws.innerHTML = `<p class="sub">No interviews yet. Open a job and add an interview step to its timeline (Recruiter Screen, Technical Interview, Final Round…) with a date and time.</p>`;
    return;
  }
  const company = companyOf(job.company), key = companyKey(job.company);
  const contacts = key ? referrals.filter(r => companyKey(r.company) === key) : [];
  const others = key ? jobs.filter(j => j.id !== job.id && companyKey(j.company) === key) : [];
  const pastSteps = others.flatMap(j => j.history.filter(h => MEETING_STAGES.includes(h.stage)).map(h => ({ j, h })));
  const q = enc(job.company || "");
  const ticked = new Set(step.checked || []);
  ws.dataset.job = id; ws.dataset.i = i;
  ws.innerHTML = `
    <div class="row spread">
      <div><h2 style="margin:0">${esc(step.stage)}${step.on ? ` · ${esc(whenText(step.on, step.at))}` : ""}</h2>
        <p class="sub" style="margin:4px 0 0"><span class="link open">${esc(job.company) || "(no company)"}</span>${job.title ? ` · ${esc(job.title)}` : ""}
          ${[job.location, payShown(job)].filter(Boolean).map(s => ` · ${esc(s)}`).join("")}
          ${webLink(job.url) ? ` · <a href="${esc(job.url)}" target="_blank" rel="noopener">Posting ↗</a>` : ""}</p></div>
      ${step.on ? `<button type="button" class="ghost ivIcs">Add to calendar</button>` : ""}
    </div>

    <div class="iv-grid">
      <section>
        <h3>Day-of checklist</h3>
        <ul class="iv-check">${checklist.map(item => `<li><label><input type="checkbox" value="${esc(item)}" ${ticked.has(item) ? "checked" : ""}> ${esc(item)}</label></li>`).join("")}</ul>
        <details class="iv-edit"><summary>Edit checklist</summary>
          <textarea id="ivChecklistEdit" aria-label="Checklist items, one per line">${esc(checklist.join("\n"))}</textarea>
          <button type="button" class="ghost" id="ivChecklistSave">Save checklist</button></details>
      </section>
      <section>
        <h3>Research</h3>
        <p class="iv-links">
          <a href="https://www.google.com/search?q=${q}" target="_blank" rel="noopener">Website & news</a>
          <a href="https://www.linkedin.com/search/results/people/?keywords=${q}" target="_blank" rel="noopener">People on LinkedIn</a>
          <a href="https://www.glassdoor.com/Search/results.htm?keyword=${q}" target="_blank" rel="noopener">Glassdoor</a>
          <a href="https://www.google.com/search?q=${enc(`${job.company || ""} site:levels.fyi`)}" target="_blank" rel="noopener">Levels.fyi pay</a>
          <a href="https://www.google.com/search?q=${enc(`${job.company || ""} ${step.stage} interview questions`)}" target="_blank" rel="noopener">Interview questions</a>
        </p>
        <h3>Contacts there</h3>
        ${contacts.length ? `<ul class="iv-mini">${contacts.map(r => { const c = contactLink(r.contact); return `<li>${esc(r.name)}${r.role ? ` · ${esc(r.role)}` : ""} <span class="sub">${esc(r.status)}</span>${c ? ` <a href="${esc(c)}" target="_blank" rel="noopener" title="Contact ${esc(r.name)}">✉</a>` : ""}</li>`; }).join("")}</ul>`
          : `<p class="sub">No referral contacts at ${esc(job.company) || "this company"}.</p>`}
        <h3>History there</h3>
        ${others.length ? `<ul class="iv-mini">${others.map(j => `<li><span class="link" data-open="${j.id}">${esc(j.title) || "(no title)"}</span> <span class="sub">${esc(j.applied_on) || "no date"} · ${esc(stageOf(j))}</span></li>`).join("")}</ul>`
          : `<p class="sub">First application here.</p>`}
        ${pastSteps.length ? `<details><summary>Earlier interviews here (${pastSteps.length})</summary><ul class="iv-mini">${pastSteps.map(({ j, h }) =>
          `<li><b>${esc(h.stage)}</b> <span class="sub">${esc(h.on)} · ${esc(j.title)}</span>${h.note ? `<div class="iv-quote">${esc(h.note)}</div>` : ""}</li>`).join("")}</ul></details>` : ""}
      </section>
    </div>

    <label class="iv-note">Notes for this interview <span class="sub">Who you met, what they asked, how it went</span>
      <textarea data-save="step" data-saved="${esc(step.note)}">${esc(step.note)}</textarea><span class="noteState" aria-live="polite"></span></label>
    <label class="iv-note">Role notes & prep <span class="sub">This role only: requirements, your pitch, questions about the team</span>
      <textarea data-save="prep" data-saved="${esc(job.prep)}">${esc(job.prep)}</textarea><span class="noteState" aria-live="polite"></span></label>
    <label class="iv-note">Company notes <span class="sub">Shared with every application to ${esc(job.company) || "this company"}</span>
      <textarea data-save="company" data-saved="${esc(company?.notes || "")}" ${job.company ? "" : "disabled placeholder=\"Give this job a company name first\""}>${esc(company?.notes || "")}</textarea><span class="noteState" aria-live="polite"></span></label>`;
}

// Autosave: a short pause in typing (or leaving the box) saves it. The page isn't re-rendered while you type.
const ivTimers = new WeakMap();
const stateOf = box => box.dataset.save === "prep-note" ? box.closest("[data-prep]").querySelector(".noteState") : box.nextElementSibling;
async function ivSave(box) {
  clearTimeout(ivTimers.get(box));
  const value = box.value, state = stateOf(box);
  if (box.dataset.saved === value) return;
  box.dataset.saved = value;
  let res;
  if (box.dataset.save === "prep-note") {
    const n = prepLib.find(p => p.id === box.closest("[data-prep]").dataset.prep); n[box.name] = value;
    res = await api(`/api/prep/${n.id}`, { method: "PATCH", body: JSON.stringify({ [box.name]: value }) }).catch(() => ({ error: "couldn't reach the app" }));
  } else {
    const ws = $("#ivWork"), job = jobs.find(j => j.id === ws.dataset.job), i = ws.dataset.i;
    const req = {
      step: () => { job.history[i].note = value; return api(`/api/jobs/${job.id}/events/${i}`, { method: "PATCH", body: JSON.stringify({ note: value }) }); },
      prep: () => { job.prep = value; return api(`/api/jobs/${job.id}`, { method: "PATCH", body: JSON.stringify({ prep: value }) }); },
      company: () => api("/api/companies", { method: "PUT", body: JSON.stringify({ name: job.company, notes: value }) })
        .then(c => { if (!c.error) companies = [...companies.filter(x => x.id !== c.id), c]; return c; }),
    }[box.dataset.save];
    res = await req().catch(() => ({ error: "couldn't reach the app" }));
  }
  if (res.error) delete box.dataset.saved;
  state.textContent = res.error ? `Not saved: ${res.error}` : "Saved";
}
for (const sel of ["#ivWork", "#prepLib"]) {
  $(sel).addEventListener("input", e => {
    const box = e.target; if (!box.dataset.save) return;
    stateOf(box).textContent = "Saving…";
    clearTimeout(ivTimers.get(box)); ivTimers.set(box, setTimeout(() => ivSave(box), 700));
  });
  $(sel).addEventListener("focusout", e => { if (e.target.dataset.save) ivSave(e.target); });
}

$("#ivLists").addEventListener("click", e => {
  const li = e.target.closest("li[data-k]"); if (!li) return;
  ivPick = li.dataset.k; renderInterviews();
  if (innerWidth < 900) $("#ivWork").scrollIntoView({ behavior: "smooth", block: "start" });
});

$("#ivWork").addEventListener("click", async e => {
  const ws = $("#ivWork"), job = jobs.find(j => j.id === ws.dataset.job), i = Number(ws.dataset.i);
  if (e.target.matches(".open")) return openDetail(job.id);
  if (e.target.dataset.open) return openDetail(e.target.dataset.open);
  if (e.target.matches(".ivIcs")) {
    const a = document.createElement("a");
    a.href = URL.createObjectURL(new Blob([icsFor(job, job.history[i], i)], { type: "text/calendar" }));
    a.download = `${(job.company || "interview").replace(/[^\w-]+/g, "-")}-${job.history[i].on}.ics`;
    a.click(); setTimeout(() => URL.revokeObjectURL(a.href), 1000);
  }
  if (e.target.id === "ivChecklistSave") {
    const res = await api("/api/prep/checklist", { method: "PUT", body: JSON.stringify({ items: $("#ivChecklistEdit").value }) });
    if (!res.error) { checklist = res.checklist; renderWorkspace(); }
  }
});
$("#ivWork").addEventListener("change", async e => {
  if (!e.target.matches(".iv-check input")) return;
  const ws = $("#ivWork"), job = jobs.find(j => j.id === ws.dataset.job), i = ws.dataset.i;
  const checked = [...ws.querySelectorAll(".iv-check input:checked")].map(b => b.value);
  const res = await api(`/api/jobs/${job.id}/events/${i}`, { method: "PATCH", body: JSON.stringify({ checked }) });
  if (!res.error) jobs[jobs.findIndex(j => j.id === job.id)] = res;
});

// ---- Prep library: titled notes reused across interviews (STAR stories, answers, questions to ask) ----
function renderPrepLib() {
  $("#prepList").innerHTML = prepLib.map(n => `<details data-prep="${n.id}"><summary>${esc(n.title)}</summary>
    <input name="title" data-save="prep-note" data-saved="${esc(n.title)}" value="${esc(n.title)}" aria-label="Title">
    <textarea name="body" data-save="prep-note" data-saved="${esc(n.body)}" aria-label="${esc(n.title)}">${esc(n.body)}</textarea>
    <span class="noteState" aria-live="polite"></span>
    <button type="button" class="ghost prepDel">Delete</button></details>`).join("")
    || `<p class="sub">Nothing here yet. Add STAR stories, answers to common questions, or questions to ask.</p>`;
}
$("#prepAdd").addEventListener("submit", async e => {
  e.preventDefault();
  const data = Object.fromEntries(new FormData(e.target));
  const note = await api("/api/prep", { method: "POST", body: JSON.stringify(data) });
  if (note.error) return alert(note.error);
  prepLib.push(note); e.target.reset(); renderPrepLib();
  $(`#prepList [data-prep="${note.id}"]`).open = true;
});
$("#prepList").addEventListener("click", async e => {
  if (!e.target.matches(".prepDel") || !confirm("Delete this prep note?")) return;
  const id = e.target.closest("[data-prep]").dataset.prep;
  await api(`/api/prep/${id}`, { method: "DELETE" });
  prepLib = prepLib.filter(n => n.id !== id); renderPrepLib();
});
