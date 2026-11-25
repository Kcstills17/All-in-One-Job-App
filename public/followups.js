// Which applications and referrals are due for a follow-up. Pure, so test/followups.test.js can check it.
// Due = still waiting on a reply, last touched 7 to 60 days ago. Older ones are left alone (a later
// Gmail scan will sort out the rejections), and a "Followed up" today restarts the clock.
const FOLLOW_UP = { from: 7, to: 60 };
const WAITING_STAGES = ["Applied", "Followed Up"];
const WAITING_REFS = ["Messaged", "Followed Up"];

// Whole days between two YYYY-MM-DD dates (both read as UTC midnight, so no timezone drift).
const daysBetween = (from, to) => Math.round((Date.parse(to) - Date.parse(from)) / 864e5);
const latest = dates => dates.filter(Boolean).sort().at(-1) || "";

function dueFollowUps(jobs, referrals, today) {
  const due = (last) => {
    if (!last) return null;
    const days = daysBetween(last, today);
    return days >= FOLLOW_UP.from && days <= FOLLOW_UP.to ? days : null;
  };
  const apps = jobs
    .filter(j => WAITING_STAGES.includes(j.history.at(-1).stage))
    .map(j => ({ job: j, days: due(latest([j.applied_on, ...j.history.map(h => h.on)])) }))
    .filter(x => x.days !== null);
  const refs = referrals
    .filter(r => WAITING_REFS.includes(r.status))
    .map(r => ({ ref: r, days: due(latest([r.first_contact, r.second_contact, r.meeting_on])) }))
    .filter(x => x.days !== null);
  // Most recent first: a fresher follow-up has the best odds.
  const byDays = (a, b) => a.days - b.days;
  return { apps: apps.sort(byDays), refs: refs.sort(byDays) };
}

if (typeof module === "object") module.exports = { dueFollowUps, FOLLOW_UP };
