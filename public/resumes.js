// Which resume version an application used, and how each version did. Pure, so test/resumes.test.js can check it.
// A pinned version wins; otherwise it's the latest version started on or before the applied date.
function resumeFor(job, resumes) {
  if (job.resume_id) return resumes.find(r => r.id === job.resume_id) || null;
  if (!job.applied_on) return null;
  return resumes.filter(r => r.started_on <= job.applied_on)
    .sort((a, b) => a.started_on.localeCompare(b.started_on) || a.id - b.id).at(-1) || null;
}

// One row per version (newest first) plus "No version" for applications before the first one.
// `responded` and `interviewed` are the page's own definitions, passed in.
function resumeStats(jobs, resumes, responded, interviewed) {
  const rows = new Map([...resumes].sort((a, b) => b.started_on.localeCompare(a.started_on)).map(r => [r.id, { resume: r, sent: 0, responses: 0, interviews: 0 }]));
  const none = { resume: null, sent: 0, responses: 0, interviews: 0 };
  for (const j of jobs) {
    const row = rows.get(resumeFor(j, resumes)?.id) || none;
    row.sent++; if (responded(j)) row.responses++; if (interviewed(j)) row.interviews++;
  }
  return [...rows.values(), ...(none.sent ? [none] : [])];
}

if (typeof module === "object") module.exports = { resumeFor, resumeStats };
