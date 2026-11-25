const test = require("node:test");
const assert = require("node:assert");
const { resumeFor, resumeStats } = require("../public/resumes.js");

const v1 = { id: "1", name: "v1", started_on: "2026-01-15" };
const v2 = { id: "2", name: "v2", started_on: "2026-09-01" };
const resumes = [v2, v1];
const job = (applied_on, extra = {}) => ({ applied_on, resume_id: null, ...extra });

test("by date: the latest version started on or before the applied date", () => {
  assert.strictEqual(resumeFor(job("2026-01-15"), resumes), v1, "the start day counts");
  assert.strictEqual(resumeFor(job("2026-08-31"), resumes), v1);
  assert.strictEqual(resumeFor(job("2026-09-01"), resumes), v2);
  assert.strictEqual(resumeFor(job("2025-12-31"), resumes), null, "before any version");
  assert.strictEqual(resumeFor(job(""), resumes), null, "no applied date");
});

test("a pinned version wins over the date", () => {
  assert.strictEqual(resumeFor(job("2026-10-01", { resume_id: "1" }), resumes), v1);
  assert.strictEqual(resumeFor(job("2026-10-01", { resume_id: "gone" }), resumes), null);
});

test("stats per version, newest first, with a No version row only when needed", () => {
  const jobs = [job("2026-02-01", { r: true, i: true }), job("2026-03-01", { r: true }), job("2026-10-01"), job("2025-06-01")];
  const rows = resumeStats(jobs, resumes, j => !!j.r, j => !!j.i);
  assert.deepStrictEqual(rows.map(x => [x.resume?.name ?? null, x.sent, x.responses, x.interviews]),
    [["v2", 1, 0, 0], ["v1", 2, 2, 1], [null, 1, 0, 0]]);
  assert.deepStrictEqual(resumeStats([job("2026-10-01")], resumes, () => false, () => false).map(x => x.resume?.name), ["v2", "v1"]);
});
