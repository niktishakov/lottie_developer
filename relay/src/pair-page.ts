// Страница короткого входа: lottie-relay…/pair, только PIN. Та же разметка, что у страницы на айфоне (CompanionRoutes.pairHTML).
export const PAIR_HTML = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Pair with iPhone</title>
<style>
  :root { color-scheme: light dark; --bg:#f5f5f7; --fg:#1d1d1f; --card:#fff; --muted:#6e6e73; --accent:#0a84ff; --err:#d70015; }
  @media (prefers-color-scheme: dark) { :root { --bg:#111; --fg:#f5f5f7; --card:#1c1c1e; --muted:#98989d; --err:#ff453a; } }
  body { margin:0; font:15px/1.45 -apple-system,Segoe UI,Roboto,sans-serif; background:var(--bg); color:var(--fg);
         display:flex; min-height:100vh; align-items:center; justify-content:center; padding:16px; box-sizing:border-box; }
  .card { background:var(--card); border-radius:14px; padding:28px; max-width:560px; width:100%; box-shadow:0 4px 24px rgba(0,0,0,.08); }
  h1 { margin:0 0 6px; font-size:22px; } p { margin:6px 0 16px; color:var(--muted); }
  input { font:600 28px ui-monospace,Consolas,monospace; letter-spacing:8px; width:100%; box-sizing:border-box; padding:10px 14px;
          border:1px solid #8884; border-radius:10px; background:transparent; color:var(--fg); text-align:center; }
  button, a.btn { font:600 15px inherit; border:0; border-radius:10px; padding:10px 18px; background:var(--accent); color:#fff;
          cursor:pointer; text-decoration:none; display:inline-block; margin-top:12px; }
  textarea { width:100%; box-sizing:border-box; font:13px ui-monospace,Consolas,monospace; padding:10px; border-radius:10px;
             border:1px solid #8884; background:transparent; color:var(--fg); resize:none; height:96px; }
  .err { color:var(--err); min-height:1.4em; margin-top:8px; } .hidden { display:none; } .row { display:flex; gap:10px; flex-wrap:wrap; }
</style></head><body>
<div class="card">
  <div id="step1">
    <h1>Pair with iPhone</h1>
    <p>Enter the 6-digit PIN from the Claude tab of Lottie Developer on your iPhone. Keep the app open on the iPhone.</p>
    <form id="f"><input id="pin" inputmode="numeric" autocomplete="one-time-code" maxlength="6" placeholder="000000" autofocus>
    <button type="submit">Pair</button></form>
    <div class="err" id="err"></div>
  </div>
  <div id="step2" class="hidden">
    <h1>Paired</h1>
    <p>Paste this command into PowerShell (Windows) or Terminal (Mac) and press Enter. Then quit Claude completely and open it again.</p>
    <textarea id="cmd" readonly></textarea>
    <div class="row"><button id="copy" type="button">Copy</button><a class="btn" href="/">Open viewer</a></div>
  </div>
</div>
<script>
const $ = (id) => document.getElementById(id);
$("f").onsubmit = async (e) => {
  e.preventDefault(); $("err").textContent = "";
  try {
    const r = await fetch("/pair", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ pin: $("pin").value.trim() }) });
    const j = await r.json();
    if (!r.ok) { $("err").textContent = j.error || "Pairing failed"; return; }
    $("cmd").value = j.mcpCommand; $("step1").classList.add("hidden"); $("step2").classList.remove("hidden");
  } catch (err) { $("err").textContent = "Cannot reach the iPhone: " + err; }
};
$("copy").onclick = async () => {
  const t = $("cmd");
  try { await navigator.clipboard.writeText(t.value); } catch { t.select(); document.execCommand("copy"); }
  $("copy").textContent = "Copied";
  setTimeout(() => $("copy").textContent = "Copy", 1500);
};
</script></body></html>`;
