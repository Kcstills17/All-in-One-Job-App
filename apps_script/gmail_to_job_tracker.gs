// Job Tracker Gmail script. Runs in your own Google account (script.google.com), searches your Gmail for
// likely job emails, and sends them to your Job Tracker, which sorts them into suggestions for you to
// review. The tracker keeps only the sender, subject and the deciding sentence, never the email itself.
//
// Install it in the Google account where your job emails arrive; it can differ from your tracker login.
// Setup: set APP_URL and TOKEN below (the token comes from the tracker's Account page), save, then run
// `setup` once and allow access when Google asks. To stop: Disconnect on the Account page, or delete
// this project.

const APP_URL = "https://YOUR-APP.onrender.com"; // your tracker's address, no trailing slash
const TOKEN = "PASTE-YOUR-TOKEN-HERE";           // from Account → Gmail → Connect Gmail
const ONLY_TO = "";                              // optional: only read mail sent to this address, e.g. "you@gmail.com"
const START = "2026/01/01";                      // the first scan goes back to here (before your first application)

// Gmail search: likely job email, minus promotions, social and what you sent.
// With ONLY_TO, only mail addressed or delivered to that address counts (another Gmail forwarded here).
const QUERY = (ONLY_TO ? `(to:${ONLY_TO} OR deliveredto:${ONLY_TO}) ` : "") + '-category:promotions -category:social -in:sent ' +
  '(subject:(application OR applying OR applied OR interview OR candidacy OR opportunity OR position OR role) ' +
  'OR "other candidates" OR "moving forward" OR "move forward" OR "next steps" OR "your application" OR "regret to inform")';
const PAGE = 50;       // threads per search
const BATCH = 100;     // emails per request (the tracker's limit)
const BODY = 20000;    // characters of each email's text to send

// Run once: checks every hour from now on, and does the first scan right away. Running it again starts
// over with a full scan from START (the tracker ignores emails it already has).
function setup() {
  PropertiesService.getScriptProperties().deleteAllProperties();
  ScriptApp.getProjectTriggers().forEach(t => ScriptApp.deleteTrigger(t));
  ScriptApp.newTrigger("sync").timeBased().everyHours(1).create();
  sync();
}

// Sends new job emails. The first scan can take a few runs (a run stops before Google's 6-minute limit
// and the next one picks up where it left off); the tracker ignores emails it has already seen.
function sync() {
  const props = PropertiesService.getScriptProperties();
  const since = props.getProperty("since") || START;
  let start = Number(props.getProperty("cursor") || 0);
  const startedOn = new Date();
  // You: this account plus every address it can send as (e.g. another Gmail you forward here). Blank
  // entries are dropped: some accounts report an empty address, which would otherwise match every sender.
  const me = new Set([mailbox(), ...GmailApp.getAliases()].map(a => a.toLowerCase().trim()).filter(Boolean));
  const seen = { threads: 0, messages: 0, older: 0, mine: 0, sent: 0 };
  console.log(`Scanning mail since ${since} (resuming at thread ${start}); skipping mail from: ${[...me].join(", ") || "(none)"}`);
  const deadline = Date.now() + 4.5 * 60 * 1000;
  const sinceDate = new Date(since.replace(/\//g, "-") + "T00:00:00");
  wake();
  while (Date.now() < deadline) {
    const threads = GmailApp.search(`after:${since} ${QUERY}`, start, PAGE);
    if (!threads.length) {
      console.log(`Done: ${JSON.stringify(seen)}`);
      send([]); // tells the tracker this sync finished, even when there was nothing new
      // Next time, only look from the day before this run (overlap is fine, repeats are ignored).
      props.setProperty("since", Utilities.formatDate(new Date(startedOn.getTime() - 86400000), "UTC", "yyyy/MM/dd"));
      props.deleteProperty("cursor");
      return;
    }
    const emails = [];
    seen.threads += threads.length;
    threads.forEach(t => t.getMessages().forEach(m => {
      seen.messages++;
      const from = (m.getFrom().match(/<([^>]+)>/) || [, m.getFrom()])[1].toLowerCase().trim();
      if (m.getDate() < sinceDate) return seen.older++;
      if (me.has(from)) return seen.mine++;
      emails.push({ id: m.getId(), from: m.getFrom(), subject: m.getSubject(), date: m.getDate().toISOString(),
                    body: m.getPlainBody().slice(0, BODY) });
    }));
    for (let i = 0; i < emails.length; i += BATCH) send(emails.slice(i, i + BATCH));
    seen.sent += emails.length;
    start += threads.length;
    props.setProperty("cursor", String(start));
  }
  console.log(`Paused before Google's time limit at thread ${start}: ${JSON.stringify(seen)}. The next run continues.`);
}

// The address of the account this script runs in.
function mailbox() {
  return Session.getActiveUser().getEmail() || Session.getEffectiveUser().getEmail() || "";
}

// The tracker's free plan sleeps when idle; one request wakes it before the real ones.
function wake() {
  try { UrlFetchApp.fetch(APP_URL + "/login", { muteHttpExceptions: true }); } catch (e) { Utilities.sleep(20000); }
}

function send(emails) {
  const options = { method: "post", contentType: "application/json", muteHttpExceptions: true,
                    headers: { Authorization: "Bearer " + TOKEN },
                    payload: JSON.stringify({ emails, mailbox: mailbox() }) };
  for (let attempt = 1; attempt <= 3; attempt++) {
    const res = UrlFetchApp.fetch(APP_URL + "/gmail/ingest", options);
    if (res.getResponseCode() === 200) { console.log(res.getContentText()); return; }
    if (res.getResponseCode() === 401) throw new Error("The tracker doesn't know this token. Make a new one on the Account page and paste it into TOKEN.");
    Utilities.sleep(15000 * attempt);
  }
  throw new Error("The tracker didn't accept the emails after 3 tries; the next hourly run will try again.");
}
