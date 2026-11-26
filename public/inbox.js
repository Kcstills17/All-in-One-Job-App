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
  "ashbyhq", "ashby", "rippling", "icims", "indeed", "linkedin", "gmail", "support",
  // role words: they name the job, not the company
  "software", "engineer", "engineering", "developer", "junior", "senior", "full", "stack", "fullstack", "backend",
  "frontend", "technical", "specialist", "associate", "intern", "platform", "data", "systems", "solutions", "services",
  "analyst", "manager", "customer", "success", "operations", "product", "remote", "hybrid"]);
// Job sites and mail services: their domain isn't the company.
const SENDER_HOSTS = /^(myworkday|workday|greenhouse|greenhouse-mail|ashbyhq|rippling|icims|smartrecruiters|workablemail|workable|lever|bamboohr|pinpoint|gem|appreview|hireflix|criteriacorp|successfactors|ultipro|jobvite|breezy|recruitee|teamtailor|indeed|linkedin|gmail|googlemail|outlook|yahoo|hotmail)$/i;

// Likely applications for an unmatched email: the server's candidates, else applications whose company
// shares a word with the sender's name, address or subject; most recent first.
function likelyJobs(m) {
  const fromServer = m.candidates.map(id => jobs.find(j => j.id === id)).filter(Boolean);
  if (fromServer.length) return fromServer;
  const common = commonCompanyWords();
  const hints = new Set(words(`${m.sender} ${m.subject}`).filter(w => !NOISE.has(w) && !common.has(w)));
  return jobs.filter(j => !appliedAfter(j, m)).map(j => [j, words(j.company).filter(w => hints.has(w)).length])
    .filter(([, n]) => n > 0)
    .sort((a, b) => b[1] - a[1] || (b[0].applied_on || "").localeCompare(a[0].applied_on || ""))
    .slice(0, 6).map(([j]) => j);
}

// Words in more than three different companies' names ("health", "software", "capital") don't
// point at any one of them.
let commonWords;
function commonCompanyWords() {
  if (commonWords) return commonWords;
  const seen = new Map();
  for (const name of new Set(jobs.map(j => String(j.company || "").trim().toLowerCase())))
    for (const w of new Set(words(name))) seen.set(w, (seen.get(w) || 0) + 1);
  return commonWords = new Set([...seen].filter(([, n]) => n > 3).map(([w]) => w));
}

// For "Add to tracker": a company and role guessed from the email, both editable before saving.
const titleCase = w => w ? w[0].toUpperCase() + w.slice(1) : "";
const HIRING_WORDS = /\s*\b(hiring team|recruiting team|talent( acquisition| team)?|recruiting|careers|career opportunities|hr|human resources|people ops)\b.*$/i;
function guessFromEmail(m) {
  const [name, address = ""] = String(m.sender).includes(" · ") ? String(m.sender).split(" · ") : ["", String(m.sender)];
  // Lowercase the lead-in words so "Update From Alkira" reads like "update from Alkira".
  const LEAD = /\b(applying to|applied to|application to|application with|application at|applying at|interest in|update from|thank you from|thanks from|applying)\b/gi;
  const subject = String(m.subject).replace(LEAD, w => w.toLowerCase());
  const ROLE = /\b(engineer|developer|specialist|analyst|manager|associate|intern|representative|technician|designer|scientist|consultant|administrator|coordinator)\b/i;
  // 1. "Atlas Hiring Team", "NielsenIQ Recruiting": the name before the hiring words.
  const hiring = HIRING_WORDS.test(name) ? name.replace(HIRING_WORDS, "").replace(/\s+via\s+.*$/i, "").trim() : "";
  // 2. The subject: "application to Ramp", "Interest in Acrisure", "Higher Logic - Thank you", "Applying DentalXChange".
  const subjectName = [/\b(?:applying to|applied to|application to|application with|application at|applying at|interest in|update from|thank you from|thanks from|applying)\s+([A-Z][\w&.'-]*(?:\s+[A-Z][\w&.'-]*){0,3})/,
    /^([A-Z][\w&.']*(?:\s+[A-Z][\w&.']*){0,3})\s+[-|:–]\s/, /\bat\s+([A-Z][\w&.'-]*(?:\s+[A-Z][\w&.'-]*){0,2})/]
    .map(re => (subject.match(re) || [])[1])
    // "Junior Software Engineer - Rokt": the role comes first, so the company is after the dash.
    .map(c => c && ROLE.test(c) ? ((subject.split(/\s[-|:–]\s/)[1] || "").match(/^[A-Z][\w&.'-]*(?:\s+[A-Z][\w&.'-]*){0,2}/) || [""])[0] : c)
    .find(c => c && !/^(your|you|the|our|this|thank|thanks|zane)\b/i.test(c)) || "";
  // "Rokt via Hireflix": the name before "via" is the company.
  const via = (name.match(/^(.+?)\s+via\s+/i) || [])[1] || "";
  // 3. A sender name that isn't a person ("Brivo", "StrongMind, Inc.").
  const person = /^[A-Z][a-z]+(?:\s+[A-Z][a-z'-]+){1,2}$/.test(name.trim());
  const plainName = !person && !/@|no.?reply|do not reply/i.test(name) ? name.replace(/\s+via\s+.*$/i, "").trim() : "";
  // 4. The address: the company's own domain (peopleops.geotab.com -> Geotab), or the name before the @ at a job site.
  const [local, host = ""] = address.toLowerCase().split("@");
  const labels = host.split("."), site = labels.at(-2) || "";
  const fromAddress = SENDER_HOSTS.test(site) || SENDER_HOSTS.test(labels[0] || "")
    ? (/no.?reply|notifications|jobs|careers|talent|recruiting|users|workday|hr|candidates/.test(local) ? "" : local.split(/[+._-]/)[0])
    : site;
  const company = hiring || via || subjectName || plainName || (fromAddress && !NOISE.has(fromAddress) ? titleCase(fromAddress) : "");
  const title = (subject.match(/(?:for|-|–|\|)\s+(?:the\s+)?([A-Z][^|!(]*?(?:Engineer|Developer|Specialist|Analyst|Manager|Associate|Intern|Representative|Technician|Support|Designer|Scientist|Consultant|Administrator|Coordinator))\b/) || [])[1] || "";
  const lead = subject.split(/\s[-|:–]\s/)[0];
  const roleFirst = !title && ROLE.test(lead) && lead.length < 60 ? lead.trim() : "";
  return { company: company.replace(/[,.]+$/, "").trim(), title: (title || roleFirst).replace(new RegExp(`^${company}\\b\\s*`, "i"), "").trim() };
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
        <span class="inCands inResults"></span>
        ${addForm(m, likely.length)}</div>`;
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
  if (e.target.matches(".inCreate")) {
    const box = e.target.closest(".inAdd"), data = Object.fromEntries([...box.querySelectorAll("input")].map(i => [i.name, i.value.trim()]));
    if (!data.company) return alert("Add a company name first.");
    e.target.disabled = true;
    const job = await api("/api/jobs", { method: "POST", body: JSON.stringify(data) });
    e.target.disabled = false;
    if (job.error) return alert(job.error);
    jobs.unshift(job); commonWords = null;
    box.open = false; box.querySelector("summary").textContent = `Added ${jobLabel(job)}`;
    choose(li, job.id);
  }
  if (e.target.matches(".inApprove")) {
    if (!li.dataset.job) return alert("Pick the application this email is about first.");
    inboxAct(li, "approve");
  }
  if (e.target.matches(".inDismiss")) inboxAct(li, "dismiss");
});
// Not in the tracker yet: make the application from the email, then approve adds the step to it.
function addForm(m, hasLikely) {
  const g = guessFromEmail(m);
  return `<details class="inAdd"${hasLikely ? "" : " open"}><summary>${hasLikely ? "None of these? Add it to your tracker" : "Not in your tracker? Add it"}</summary>
    <div class="row" style="gap:6px;margin-top:6px">
      <input name="company" value="${esc(g.company)}" placeholder="Company" aria-label="Company">
      <input name="title" value="${esc(g.title)}" placeholder="Role (optional)" aria-label="Role">
      <label class="sub" style="margin:0;display:flex;gap:6px;align-items:center">Applied <input type="date" name="applied_on" value="${esc(m.email_on)}"></label>
      <button type="button" class="ghost inCreate">Add application</button>
    </div></details>`;
}

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
