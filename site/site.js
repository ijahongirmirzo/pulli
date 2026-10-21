// Pulli website: header shadow, copy button, reveal on scroll, and the resume illustration.

const nav = document.getElementById("nav");
const onScroll = () => nav.classList.toggle("scrolled", window.scrollY > 8);
window.addEventListener("scroll", onScroll, { passive: true });
onScroll();

document.querySelectorAll("[data-copy]").forEach((button) => {
  button.addEventListener("click", async () => {
    const text = document.getElementById(button.dataset.copy).textContent;
    try {
      await navigator.clipboard.writeText(text);
      button.textContent = "Copied";
    } catch {
      button.textContent = "Select it";
    }
    setTimeout(() => (button.textContent = "Copy"), 1600);
  });
});

const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

if ("IntersectionObserver" in window && !reducedMotion) {
  const io = new IntersectionObserver((entries) => {
    entries.forEach((entry) => {
      if (entry.isIntersecting) {
        entry.target.classList.add("in");
        io.unobserve(entry.target);
      }
    });
  }, { rootMargin: "0px 0px -8% 0px" });
  document.querySelectorAll(".reveal").forEach((el) => io.observe(el));
} else {
  document.querySelectorAll(".reveal").forEach((el) => el.classList.add("in"));
}

// The block strip: a video copies in blocks, the cable comes out, Pulli waits, then carries on
// from the last saved block. It plays only while on screen.
(() => {
  const host = document.getElementById("blocks");
  if (!host) return;
  const COUNT = 40, CUT = 24, TOTAL_MB = 385;
  const blocks = Array.from({ length: COUNT }, () => host.appendChild(document.createElement("i")));
  const status = document.getElementById("strip-status");
  const text = document.getElementById("strip-text");
  const size = document.getElementById("strip-size");

  const setStatus = (state, label) => { status.dataset.state = state; text.textContent = label; };
  const setSize = (n) => { size.textContent = `${Math.round((n / COUNT) * TOTAL_MB)} MB of ${TOTAL_MB} MB`; };
  const paint = (filled, head) => blocks.forEach((b, i) => {
    b.className = i < filled ? "on" : "";
    if (i === head) b.className = "head";
  });

  if (reducedMotion) {
    paint(CUT, -1);
    blocks[CUT].className = "cut";
    setSize(CUT);
    setStatus("paused", "Cable pulled - continues from here");
    return;
  }

  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  let visible = false, running = false;
  const waitVisible = async () => { while (!visible) await sleep(250); };

  async function play() {
    running = true;
    for (;;) {
      paint(0, -1); setSize(0); setStatus("copying", "Copying · 31 MB/s");
      await sleep(600);
      for (let i = 0; i < CUT; i++) { await waitVisible(); paint(i, i); setSize(i); await sleep(110); }
      paint(CUT, -1); setSize(CUT);
      blocks[CUT].className = "cut";
      setStatus("paused", "Cable pulled · waiting for myGalaxy");
      await sleep(2600);
      setStatus("copying", `Phone is back · continuing from ${Math.round((CUT / COUNT) * TOTAL_MB)} MB`);
      blocks[CUT].className = "";
      await sleep(1300);
      for (let i = CUT; i < COUNT; i++) { await waitVisible(); paint(i, i); setSize(i); await sleep(110); }
      paint(COUNT, -1); setSize(COUNT);
      setStatus("done", "Copied and checked");
      await sleep(3200);
    }
  }

  new IntersectionObserver(([entry]) => {
    visible = entry.isIntersecting;
    if (visible && !running) play();
  }).observe(host);
})();

// After a download starts, say what to do next: the visitor stays on this page.
const toast = document.createElement("div");
toast.className = "toast";
toast.setAttribute("role", "status");
toast.innerHTML = "<b>Downloading Pulli…</b> Open the disk image and drag Pulli to Applications.";
document.body.appendChild(toast);
let toastTimer;
document.querySelectorAll('a[href="/download"]').forEach((link) => {
  link.addEventListener("click", () => {
    toast.classList.add("show");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => toast.classList.remove("show"), 7000);
  });
});
