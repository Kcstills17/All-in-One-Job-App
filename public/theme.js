// Dark mode. Loaded in <head> so a saved choice applies before the page paints (no white flash).
// It follows the device until the toggle picks a theme, which this browser then remembers.
// ponytail: remembered per browser; save it on the account when settings get their own table.
(() => {
  const root = document.documentElement;
  let saved = null;
  try { saved = localStorage.getItem("theme"); } catch {}
  if (saved === "dark" || saved === "light") root.dataset.theme = saved;
  const system = matchMedia("(prefers-color-scheme: dark)");
  const isDark = () => (root.dataset.theme ? root.dataset.theme === "dark" : system.matches);

  // 7×7 pixel art for the knob. Switching themes fades each pixel out and back in, rippling from the center.
  const SUN = ["...X...", ".X...X.", "..XXX..", "X.XXX.X", "..XXX..", ".X...X.", "...X..."];
  const MOON = ["..XXX..", ".XXX...", "XXX....", "XXX..X.", "XXX....", ".XXX...", "..XXX.."];

  addEventListener("DOMContentLoaded", () => {
    const btn = document.getElementById("themeToggle");
    if (!btn) return;
    const pixels = Array.from({ length: 49 }, (_, i) => {
      const px = document.createElement("i");
      const r = Math.floor(i / 7), c = i % 7;
      px.style.transitionDelay = `${Math.max(Math.abs(r - 3), Math.abs(c - 3)) * 45 + (i % 3) * 15}ms`;
      btn.querySelector(".px-grid").append(px);
      return px;
    });
    const paint = () => {
      const dark = isDark(), art = dark ? MOON : SUN;
      btn.setAttribute("aria-checked", String(dark));
      pixels.forEach((px, i) => px.classList.toggle("on", art[Math.floor(i / 7)][i % 7] === "X"));
      dispatchEvent(new Event("themechange")); // charts pick up the new colors
    };
    btn.addEventListener("click", () => {
      root.dataset.theme = isDark() ? "light" : "dark";
      try { localStorage.setItem("theme", root.dataset.theme); } catch {}
      paint();
    });
    system.addEventListener("change", paint);
    paint();
    requestAnimationFrame(() => btn.classList.add("ready")); // animate clicks, not the first paint
  });
})();
