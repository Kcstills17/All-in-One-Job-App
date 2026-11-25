const test = require("node:test");
const assert = require("node:assert");
const { upcomingInterviews, icsFor } = require("../public/calendar.js");

const TODAY = "2026-11-25";
const job = (id, company, history, extra = {}) => ({ id, company, title: "Engineer", url: "", history, ...extra });

test("upcoming = interview steps from today on, soonest first, untimed after timed", () => {
  const jobs = [
    job("1", "Past", [{ stage: "Technical Interview", on: "2026-11-24", at: "10:00" }]),
    job("2", "Later", [{ stage: "Applied", on: "2026-11-01" }, { stage: "Final Round", on: "2026-12-03", at: "" }]),
    job("3", "TodayNoTime", [{ stage: "Recruiter Screen", on: TODAY, at: "" }]),
    job("4", "TodayNine", [{ stage: "Hiring Manager", on: TODAY, at: "09:00" }]),
    job("5", "Offer", [{ stage: "Offer", on: "2026-12-01", at: "" }]),
    job("6", "NoDate", [{ stage: "Technical Interview", on: "", at: "" }]),
  ];
  assert.deepStrictEqual(upcomingInterviews(jobs, TODAY).map(x => [x.job.company, x.i]),
    [["TodayNine", 0], ["TodayNoTime", 0], ["Later", 1]]);
});

const NOW = new Date("2026-11-25T15:04:05.123Z");

test("a timed step is a one-hour block in local time", () => {
  const ics = icsFor(job("7", "Acme, Inc.", []), { stage: "Technical Interview", on: "2026-12-02", at: "14:30", note: "Bring; laptop\nAsk about team" }, 2, NOW);
  assert.ok(ics.endsWith("\r\n") && !/[^\r]\n/.test(ics), "CRLF line endings");
  for (const line of ["DTSTART:20261202T143000", "DURATION:PT1H", "UID:job-7-step-2@job-tracker", "DTSTAMP:20261125T150405Z",
    "SUMMARY:Technical Interview: Acme\\, Inc. — Engineer", "DESCRIPTION:Bring\\; laptop\\nAsk about team"])
    assert.ok(ics.includes(`${line}\r\n`), line);
});

test("an untimed step is an all-day event, even at month end", () => {
  const ics = icsFor(job("8", "Acme", []), { stage: "Final Round", on: "2026-11-30", at: "" }, 0, NOW);
  assert.ok(ics.includes("DTSTART;VALUE=DATE:20261130\r\nDTEND;VALUE=DATE:20261201\r\n"));
});

test("long lines fold at 75 bytes", () => {
  const ics = icsFor(job("9", "Acme", []), { stage: "Final Round", on: "2026-12-02", at: "", note: "é".repeat(100) }, 0, NOW);
  for (const line of ics.split("\r\n")) assert.ok(new TextEncoder().encode(line).length <= 75, line);
  assert.ok(ics.includes("\r\n é"), "continuation lines start with a space");
});
