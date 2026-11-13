// Stáhne stavové stránky ČSSZ, eZdraví a ePreskripce a uloží souhrn do out/status.json
import { chromium } from "playwright";
import fs from "fs";

const lines = t => t.split("\n").map(s => s.replace(/\s+/g, " ").trim()).filter(Boolean);
const METRIC = /^(\d|[<>]?\s*\d)|%$|https?:\/\/|^(Posledních|Volání|Chybovost|Odmítnuto|Podíl|Dostupnost|Reálný|Test |Celkem|Průměr)/i;

function nameBefore(L, i, statusRe) {
  for (let k = i - 1; k >= Math.max(0, i - 8); k--) {
    if (!METRIC.test(L[k]) && !statusRe.test(L[k]) && L[k].length > 2 && L[k].length < 120) return L[k];
  }
  return "?";
}
function noteAfter(L, i) {
  for (let k = i + 1; k <= Math.min(L.length - 1, i + 5); k++)
    if (/hlásí|výpad|omezen|nedostup|snížen|odstáv|porucha/i.test(L[k])) return L[k];
  return "";
}

// eZdraví: řádek "Název<TAB>verze<TAB>URL", na dalším řádku stav (V pořádku / Ke sledování / Problém / …)
function parseEzdravi({ text }) {
  const raw = text.split("\n").map(s => s.trim()).filter(Boolean);
  const items = [];
  raw.forEach((l, i) => {
    if (!/https?:\/\//.test(l) || !/\t/.test(l)) return;
    const [name, ver] = l.split("\t").map(x => x.trim());
    const status = (raw[i + 1] || "").replace(/\s+/g, " ");
    if (!status || /https?:\/\//.test(status) || status.length > 40) return;
    const note = noteAfter(raw, i + 1);
    const level = /^v pořádku$/i.test(status) ? "ok" : /ke sledování/i.test(status) ? "warn" : "bad";
    items.push({ name: `${name}${ver ? " " + ver : ""}`, status, level, note });
  });
  return { checked: items.length, issues: items.filter(x => x.level !== "ok") };
}

// ČSSZ: stavy V POŘÁDKU / VÝSKYT CHYB / MNOHO CHYB (legendu přeskakujeme)
function parseCssz({ text }) {
  const L = lines(text);
  const ST = /^(v pořádku|výskyt chyb|mnoho chyb|nedostupn\S*|výpadek|odstávka|mimo provoz)$/i;
  const items = []; let section = "";
  L.forEach((l, i) => {
    if (/^služby\s/i.test(l) || /^eportál$/i.test(l)) section = l.replace(/^služby\s+/i, "");
    if (!ST.test(l)) return;
    const name = nameBefore(L, i, ST), resp = /odezv/i.test(L[i + 1] || "") ? L[i + 1] : "";
    const st = l.toUpperCase();
    let level = st === "V POŘÁDKU" ? "ok" : st === "VÝSKYT CHYB" ? "warn" : "bad";
    let status = l;
    if (resp && !/normální/i.test(resp)){ status = level === "ok" ? resp : `${l} · ${resp}`; if (level === "ok") level = "warn"; }
    items.push({ name: section ? `${section}: ${name}` : name, status, level, note: "" });
  });
  const issues = items.filter(x => x.level !== "ok");
  return { checked: items.length, issues };
}

// ePreskripce: banner "STAV SYSTÉMU …"
function parseEpreskripce({ text }) {
  const L = lines(text);
  const i = L.findIndex(l => /stav systému/i.test(l));
  if (i < 0) return { checked: 0, issues: [] };
  const head = L[i], detail = L[i + 1] || "";
  const ok = /bez omezení/i.test(head + " " + detail);
  return { checked: 1, issues: ok ? [] : [{ name: "eRecept", level: "bad", status: head.replace(/^stav systému:?\s*/i, "") || head, note: detail.slice(0, 200) }] };
}

const SOURCES = [
  { id: "cssz", name: "ČSSZ", url: "https://www.cssz.gov.cz/status.html", parse: parseCssz, waitFor: "Stav platný" },
  { id: "ezdravi", name: "eZdraví", url: "https://www.ezdravi.gov.cz/katalog-sluzeb/dostupnost", parse: parseEzdravi, waitFor: "api.csez.gov.cz" },
  { id: "epreskripce", name: "eRecept", url: "https://epreskripce.gov.cz/", parse: parseEpreskripce, waitFor: "STAV SYSTÉMU" },
];

fs.mkdirSync("out/debug", { recursive: true });
const browser = await chromium.launch();
const ctx = await browser.newContext({ locale: "cs-CZ", timezoneId: "Europe/Prague",
  userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0 Safari/537.36" });
const result = { updated: new Date().toISOString(), sources: {} };

for (const s of SOURCES) {
  const page = await ctx.newPage();
  const xhr = [];
  page.on("response", async r => {
    const ct = r.headers()["content-type"] || "";
    if (/json/.test(ct)) { try { xhr.push({ url: r.url(), body: (await r.text()).slice(0, 4000) }); } catch {} }
  });
  try {
    const resp = await page.goto(s.url, { waitUntil: "domcontentloaded", timeout: 60000 });
    try { await page.waitForLoadState("networkidle", { timeout: 15000 }); } catch {}
    if (s.waitFor) {
      try { await page.waitForFunction(t => document.body && document.body.innerText.toLowerCase().includes(t.toLowerCase()), s.waitFor, { timeout: 45000 }); }
      catch { /* obsah se nenačetl – parse to vyhodnotí jako „nelze ověřit“ */ }
    }
    await page.waitForTimeout(2000);
    const text = await page.evaluate(() => document.body.innerText);
    fs.writeFileSync(`out/debug/${s.id}.txt`, text);
    fs.writeFileSync(`out/debug/${s.id}-xhr.json`, JSON.stringify(xhr, null, 1));
    const r = s.parse({ text, xhr });
    result.sources[s.id] = { name: s.name, url: s.url, http: resp?.status(), ok: r.issues.length === 0,
      parsed: r.checked > 0, checked: r.checked, issues: r.issues };
  } catch (e) {
    result.sources[s.id] = { name: s.name, url: s.url, ok: null, error: String(e.message || e).slice(0, 200) };
  }
  await page.close();
}
await browser.close();
fs.writeFileSync("out/status.json", JSON.stringify(result, null, 1));
console.log(JSON.stringify(result, null, 1));
