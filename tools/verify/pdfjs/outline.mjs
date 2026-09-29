// outline.mjs -- pdf.js (pdfjs-dist) outline reader for the mulu verification harness.
//
// usage: node outline.mjs <file.pdf>
// prints {"ok":true,"pages":n,"outline":[{"title","level","page_index"}],"warnings":[...]}
// Outline items are resolved with getOutline() -> dest (explicit array or named) -> getPageIndex(ref).
// pdf.js silently rebuilds broken xref tables; its warnings (e.g. "Indexing all PDF objects")
// are captured so the harness can flag repairs that did not happen on the input.
import { readFile } from "node:fs/promises";
import { createRequire } from "node:module";
import path from "node:path";

const warnings = [];
const origLog = console.log;
const origWarn = console.warn;
const capture = (...a) => warnings.push(a.map(String).join(" "));
console.log = capture;   // pdf.js warn()/info() go through console.log
console.warn = capture;

function out(obj) {
  process.stdout.write(JSON.stringify(obj) + "\n");
}

const file = process.argv[2];
if (!file) {
  process.stderr.write("usage: node outline.mjs <file.pdf>\n");
  process.exit(64);
}

try {
  const pdfjs = await import("pdfjs-dist/legacy/build/pdf.mjs");
  const require = createRequire(import.meta.url);
  const pkgDir = path.dirname(require.resolve("pdfjs-dist/package.json"));
  const data = new Uint8Array(await readFile(file));
  const task = pdfjs.getDocument({
    data,
    verbosity: pdfjs.VerbosityLevel.WARNINGS,
    isEvalSupported: false,
    disableFontFace: true,
    useSystemFonts: false,
    stopAtErrors: false,
    standardFontDataUrl: path.join(pkgDir, "standard_fonts") + path.sep,
    cMapUrl: path.join(pkgDir, "cmaps") + path.sep,
    cMapPacked: true,
  });
  const doc = await task.promise;
  const outline = (await doc.getOutline()) || [];
  const items = [];
  async function resolve(dest) {
    if (typeof dest === "string") dest = await doc.getDestination(dest);
    if (!Array.isArray(dest) || dest.length === 0) return -1;
    const ref = dest[0];
    if (ref && typeof ref === "object") {
      try { return await doc.getPageIndex(ref); } catch { return -1; }
    }
    if (Number.isInteger(ref)) return ref;
    return -1;
  }
  async function walk(list, level) {
    for (const it of list) {
      items.push({ title: it.title, level, page_index: await resolve(it.dest) });
      if (it.items && it.items.length) await walk(it.items, level + 1);
    }
  }
  await walk(outline, 0);
  const pages = doc.numPages;
  await doc.destroy();
  out({ ok: true, pages, outline: items, warnings });
} catch (e) {
  out({ ok: false, error: String(e && e.message ? e.message : e), warnings });
}
console.log = origLog;
console.warn = origWarn;
