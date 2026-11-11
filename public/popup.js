// The bookmarklet popup closes itself after a successful save (no inline scripts allowed).
const done = document.querySelector("[data-close-after]");
if (done) setTimeout(() => window.close(), Number(done.dataset.closeAfter));
