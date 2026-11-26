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

function renderInbox() {
  const list = Array.isArray(gmailMatches) ? gmailMatches : [];
  const groups = [["rejected", "Rejections"], ["moving_on", "Moving on"]];
  $("#inboxEmpty").hidden = list.length > 0;
  if (!$("#inboxJobs").options.length) $("#inboxJobs").innerHTML = jobs.map(j => `<option value="${esc(jobLabel(j))}">`).join("");
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
  const candidates = m.candidates.map(id => jobs.find(j => j.id === id)).filter(Boolean);
  const target = job
    ? `<span class="sub" style="margin:0">→ <span class="link" data-open="${job.id}">${esc(jobLabel(job))}</span> · now ${esc(stageOf(job))}</span>`
    : `<label class="sub" style="margin:0">Which application?
        <input list="inboxJobs" class="inPick" placeholder="${candidates.length ? "Pick one of the likely ones or search" : "Search your applications"}" aria-label="Application for this email">
        ${candidates.length ? `<span class="inCands">${candidates.map(c => `<button type="button" class="ghost inCand" data-id="${c.id}">${esc(jobLabel(c))}</button>`).join("")}</span>` : ""}</label>`;
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
  if (e.target.matches(".inCand")) { li.dataset.job = e.target.dataset.id; li.querySelector(".inPick").value = e.target.textContent;
    li.querySelector(".inStage").value = suggestedStage(gmailMatches.find(m => m.id === li.dataset.id), jobs.find(j => j.id === e.target.dataset.id)); }
  if (e.target.matches(".inApprove")) {
    if (!li.dataset.job) return alert("Pick the application this email is about first.");
    inboxAct(li, "approve");
  }
  if (e.target.matches(".inDismiss")) inboxAct(li, "dismiss");
});
// Typing in the search box: a full match from the list picks that application.
$("#view-inbox").addEventListener("input", e => {
  if (!e.target.matches(".inPick")) return;
  const li = e.target.closest("li"), job = jobs.find(j => jobLabel(j) === e.target.value);
  li.dataset.job = job?.id || "";
  if (job) li.querySelector(".inStage").value = suggestedStage(gmailMatches.find(m => m.id === li.dataset.id), job);
});
