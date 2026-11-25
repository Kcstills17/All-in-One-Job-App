// Upcoming interviews and their .ics calendar files. Pure, so test/calendar.test.js can check it.
const MEETING_STAGES = ["Recruiter Screen", "Hiring Manager", "Technical Interview", "Take-home", "Final Round", "Work Trial"];

// Interview steps dated today or later, soonest first. Steps without a time sort after timed ones that day.
function upcomingInterviews(jobs, today) {
  return jobs.flatMap(job => job.history.map((step, i) => ({ job, step, i })))
    .filter(({ step }) => MEETING_STAGES.includes(step.stage) && step.on && step.on >= today)
    .sort((a, b) => (a.step.on + (a.step.at || "99")).localeCompare(b.step.on + (b.step.at || "99")));
}

// RFC 5545 text: escape \ ; , and newlines, then fold lines at 75 octets.
const icsText = s => String(s ?? "").replace(/\\/g, "\\\\").replace(/;/g, "\\;").replace(/,/g, "\\,").replace(/\r?\n/g, "\\n");
function fold(line) {
  const out = []; let cur = "", bytes = 0;
  for (const ch of line) {
    const n = new TextEncoder().encode(ch).length;
    if (bytes + n > 75) { out.push(cur); cur = " "; bytes = 1; }
    cur += ch; bytes += n;
  }
  return [...out, cur].join("\r\n");
}

// One event. With a time it's a one-hour block in the calendar's own timezone (floating local time);
// without one it's an all-day event. `now` is the DTSTAMP, passed in so tests are stable.
function icsFor(job, step, i, now = new Date()) {
  const d = step.on.replaceAll("-", "");
  const when = step.at
    ? [`DTSTART:${d}T${step.at.replace(":", "")}00`, "DURATION:PT1H"]
    : [`DTSTART;VALUE=DATE:${d}`, `DTEND;VALUE=DATE:${new Date(Date.parse(step.on) + 864e5).toISOString().slice(0, 10).replaceAll("-", "")}`];
  const stamp = now.toISOString().replace(/[-:]/g, "").replace(/\.\d+/, "");
  const lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Job Tracker//EN", "BEGIN:VEVENT",
    `UID:job-${job.id}-step-${i}@job-tracker`, `DTSTAMP:${stamp}`, ...when,
    `SUMMARY:${icsText(`${step.stage}: ${job.company}${job.title ? ` — ${job.title}` : ""}`)}`,
    ...(step.note || job.url ? [`DESCRIPTION:${icsText([step.note, job.url].filter(Boolean).join("\n\n"))}`] : []),
    ...(/^https?:\/\//.test(job.url || "") ? [`URL:${job.url}`] : []),
    "END:VEVENT", "END:VCALENDAR"];
  return lines.map(fold).join("\r\n") + "\r\n";
}

if (typeof module === "object") module.exports = { upcomingInterviews, icsFor };
