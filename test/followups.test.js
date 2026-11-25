// node --test test/  (run by `bundle exec rake` when node is installed)
const test = require("node:test");
const assert = require("node:assert");
const { dueFollowUps } = require("../public/followups.js");

const TODAY = "2026-11-25";
const job = (id, applied_on, history) => ({ id, applied_on, history });

test("applications waiting 7 to 60 days are due, most recent first", () => {
  const jobs = [
    job("6d", "2026-11-19", [{ stage: "Applied", on: "2026-11-19" }]),
    job("7d", "2026-11-18", [{ stage: "Applied", on: "2026-11-18" }]),
    job("60d", "2026-09-26", [{ stage: "Applied", on: "2026-09-26" }]),
    job("61d", "2026-09-25", [{ stage: "Applied", on: "2026-09-25" }]),
    job("noDate", "", [{ stage: "Applied", on: "" }]),
    job("rejected", "2026-11-01", [{ stage: "Applied", on: "2026-11-01" }, { stage: "Rejected", on: "2026-11-10" }]),
    job("screen", "2026-11-01", [{ stage: "Applied", on: "2026-11-01" }, { stage: "Recruiter Screen", on: "" }]),
  ];
  const { apps } = dueFollowUps(jobs, [], TODAY);
  assert.deepStrictEqual(apps.map(a => [a.job.id, a.days]), [["7d", 7], ["60d", 60]]);
});

test("a follow-up today restarts the clock", () => {
  const jobs = [
    job("followed", "2026-11-01", [{ stage: "Applied", on: "2026-11-01" }, { stage: "Followed Up", on: TODAY }]),
    job("followedLongAgo", "2026-10-01", [{ stage: "Applied", on: "2026-10-01" }, { stage: "Followed Up", on: "2026-11-15" }]),
  ];
  assert.deepStrictEqual(dueFollowUps(jobs, [], TODAY).apps.map(a => [a.job.id, a.days]), [["followedLongAgo", 10]]);
});

test("referrals waiting on a reply use their latest contact date", () => {
  const refs = [
    { id: "msg", status: "Messaged", first_contact: "2026-11-10", second_contact: "", meeting_on: "" },
    { id: "fresh", status: "Followed Up", first_contact: "2026-10-01", second_contact: "2026-11-24", meeting_on: "" },
    { id: "replied", status: "Replied", first_contact: "2026-11-10", second_contact: "", meeting_on: "" },
    { id: "toContact", status: "To Contact", first_contact: "", second_contact: "", meeting_on: "" },
  ];
  assert.deepStrictEqual(dueFollowUps([], refs, TODAY).refs.map(r => [r.ref.id, r.days]), [["msg", 15]]);
});
