// ---- Inbox: Gmail suggestions waiting for review (see apps_script/ and GmailIngest) ----
// Loaded after app.js; uses its helpers (api, esc, jobs, options, stageOf, replaceJob, toast…).
let gmailMatches = [];
const ENDING = ["Rejected", "Ghosted", "Withdrawn"];

async function loadInbox() { gmailMatches = await api("/api/gmail/matches").catch(() => []); }

// Mirrors the server: Rejected for rejections, else the stage after the furthest real progress.
// When the email names the step, that wins if it's further along (same list as the server).
const NAMED_STAGES = [[/final round|onsite|on-site/i, "Final Round"], [/work trial|paid trial/i, "Work Trial"],
  [/take[- ]home|coding (challenge|assessment)|online assessment/i, "Take-home"],
  [/technical interview|technical screen|pairing|live coding/i, "Technical Interview"],
  [/hiring manager/i, "Hiring Manager"], [/phone screen|recruiter (call|screen)|intro call/i, "Recruiter Screen"]];
function suggestedStage(m, job) {
  if (m.category === "rejected") return "Rejected";
  const furthest = job.history.map(h => h.stage).filter(s => !ENDING.includes(s)).sort((a, b) => STAGES.indexOf(a) - STAGES.indexOf(b)).at(-1);
  const after = !furthest || ["Applied", "Followed Up"].includes(furthest) ? "Recruiter Screen"
    : STAGES[Math.min(STAGES.indexOf(furthest) + 1, STAGES.indexOf("Accepted"))];
  const named = NAMED_STAGES.find(([re]) => re.test(`${m.subject} ${m.sentence}`))?.[1];
  return named && STAGES.indexOf(named) > STAGES.indexOf(after) ? named : after;
}

const jobLabel = j => `${j.company || "(no company)"} · ${j.title || "—"}${j.applied_on ? ` · ${j.applied_on}` : ""}`;
const words = s => String(s || "").toLowerCase().split(/[^a-z0-9]+/).filter(w => w.length >= 3);
// Words that say nothing about which company an email is from.
const NOISE = new Set(["the", "and", "for", "you", "your", "our", "with", "from", "thank", "thanks", "applying", "application",
  "applications", "update", "hiring", "team", "recruiting", "recruiter", "talent", "careers", "career", "jobs", "job", "noreply",
  "reply", "mail", "email", "com", "info", "interest", "regarding", "about", "important", "information", "position", "role",
  "opportunity", "next", "steps", "status", "inc", "llc", "group", "acquisition", "people", "workday", "greenhouse", "lever",
  "ashbyhq", "ashby", "rippling", "icims", "indeed", "linkedin", "gmail", "support"]);

// Likely applications for an unmatched email: the server's candidates, else applications whose company
// shares a word with the sender's name, address or subject; most recent first.
function likelyJobs(m) {
  const fromServer = m.candidates.map(id => jobs.find(j => j.id === id)).filter(Boolean);
  if (fromServer.length) return fromServer;
  const hints = new Set(words(`${m.sender} ${m.subject}`).filter(w => !NOISE.has(w)));
  return jobs.filter(j => !appliedAfter(j, m)).map(j => [j, words(j.company).filter(w => hints.has(w)).length])
    .filter(([, n]) => n > 0)
    .sort((a, b) => b[1] - a[1] || (b[0].applied_on || "").localeCompare(a[0].applied_on || ""))
    .slice(0, 6).map(([j]) => j);
}

// An email can't be about an application sent after it.
const appliedAfter = (j, m) => j.applied_on && m.email_on && j.applied_on > m.email_on;

// Search box results: every word typed must appear in the company, role or date.
function searchJobs(q) {
  const ws = words(q);
  if (!ws.length) return [];
  return jobs.filter(j => { const hay = `${j.company} ${j.title} ${j.applied_on}`.toLowerCase(); return ws.every(w => hay.includes(w)); })
    .sort((a, b) => (b.applied_on || "").localeCompare(a.applied_on || "")).slice(0, 8);
}
const pickButtons = list => list.map(c => `<button type="button" class="ghost inCand" data-id="${c.id}">${esc(jobLabel(c))}</button>`).join("");

function renderInbox() {
  const list = Array.isArray(gmailMatches) ? gmailMatches : [];
  const groups = [["rejected", "Rejections"], ["moving_on", "Moving on"]];
  $("#inboxEmpty").hidden = list.length > 0;
  $("#inboxGroups").innerHTML = groups.map(([cat, label]) => {
    const items = list.filter(m => m.category === cat);
    if (!items.length) return "";
    const matched = items.filter(m => m.application_id && jobs.some(j => j.id === m.application_id)).length;
    return `<section class="inbox-group"><div class="row spread"><h3>${label} (${items.length})</h3>
      ${matched ? `<button type="button" class="ghost inApproveAll" data-cat="${cat}">Approve all ${matched} matched</button>` : ""}</div>
      <ul class="inbox-list">${items.map(inboxItem).join("")}</ul></section>`;
  }).join("");
}

function inboxItem(m) {
  const job = jobs.find(j => j.id === m.application_id);
  const likely = job ? [] : likelyJobs(m);
  const target = job
    ? `<span class="sub" style="margin:0">→ <span class="link" data-open="${job.id}">${esc(jobLabel(job))}</span> · now ${esc(stageOf(job))}</span>`
    : `<div class="inPicker"><span class="sub" style="margin:0">Which application? <span class="inChosen"></span></span>
        ${likely.length ? `<span class="inCands"><span class="sub" style="margin:0">Likely:</span>${pickButtons(likely)}</span>` : ""}
        <input type="search" class="inPick" placeholder="Search by company, role or date" aria-label="Search your applications for this email" autocomplete="off">
        <span class="inCands inResults"></span></div>`;
  return `<li data-id="${m.id}" data-job="${job?.id || ""}">
    <div class="inbox-head"><b>${esc(m.email_on || "")}</b> · ${esc(m.sender)} <a href="${esc(m.gmail_url)}" target="_blank" rel="noopener">Open in Gmail ↗</a></div>
    <div><b>${esc(m.subject)}</b></div>
    <div class="iv-quote">${esc(m.sentence)}</div>
    ${target}
    <div class="row inbox-actions">
      <select class="inStage" aria-label="Stage to add">${options(job ? suggestedStage(m, job) : (m.category === "rejected" ? "Rejected" : "Recruiter Screen"))}</select>
      <button type="button" class="inApprove">Approve</button>
      <button type="button" class="ghost inDismiss">Dismiss</button>
    </div></li>`;
}

async function inboxAct(li, action) {
  const id = li.dataset.id, buttons = li.querySelectorAll("button");
  buttons.forEach(b => b.disabled = true);
  const body = action === "approve" ? { application_id: li.dataset.job, stage: li.querySelector(".inStage").value } : {};
  const res = await api(`/api/gmail/matches/${id}/${action}`, { method: "POST", body: JSON.stringify(body) });
  if (res.error) { buttons.forEach(b => b.disabled = false); return alert(res.error); }
  gmailMatches = gmailMatches.filter(m => m.id !== id);
  if (res.job) replaceJob(res.job); else render();
}

$("#view-inbox").addEventListener("click", async e => {
  const li = e.target.closest("li[data-id]");
  if (e.target.dataset.open) return openDetail(e.target.dataset.open);
  if (e.target.matches(".inApproveAll")) {
    const cat = e.target.dataset.cat;
    if (!confirm(`Add a step to every matched ${cat === "rejected" ? "rejection" : "next-steps email"}?`)) return;
    e.target.disabled = true;
    const res = await api("/api/gmail/matches/approve-all", { method: "POST", body: JSON.stringify({ category: cat }) });
    if (res.error) return alert(res.error);
    toast(`Approved ${res.approved}.`); await load();
    return;
  }
  if (!li) return;
  if (e.target.matches(".inCand")) choose(li, e.target.dataset.id);
  if (e.target.matches(".inApprove")) {
    if (!li.dataset.job) return alert("Pick the application this email is about first.");
    inboxAct(li, "approve");
  }
  if (e.target.matches(".inDismiss")) inboxAct(li, "dismiss");
});
// Picking an application: remember it, show it, and suggest the stage for that application.
function choose(li, jobId) {
  const job = jobs.find(j => j.id === jobId);
  li.dataset.job = jobId;
  li.querySelectorAll(".inCand").forEach(b => b.setAttribute("aria-pressed", String(b.dataset.id === jobId)));
  const m = gmailMatches.find(x => x.id === li.dataset.id);
  li.querySelector(".inChosen").innerHTML = `→ <b>${esc(jobLabel(job))}</b> · now ${esc(stageOf(job))}` +
    (appliedAfter(job, m) ? ` <span class="inWarn">applied after this email (${esc(m.email_on)}), so it's probably a different one</span>` : "");
  li.querySelector(".inStage").value = suggestedStage(gmailMatches.find(m => m.id === li.dataset.id), job);
}
// Typing in the search box lists matching applications as buttons right under it.
$("#view-inbox").addEventListener("input", e => {
  if (!e.target.matches(".inPick")) return;
  const li = e.target.closest("li"), found = searchJobs(e.target.value);
  li.querySelector(".inResults").innerHTML = e.target.value.trim()
    ? (found.length ? pickButtons(found) : `<span class="sub" style="margin:0">No applications match.</span>`) : "";
  if (li.dataset.job) li.querySelectorAll(".inResults .inCand").forEach(b => b.setAttribute("aria-pressed", String(b.dataset.id === li.dataset.job)));
});
