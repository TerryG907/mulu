// pdfjs_legacy.mjs -- outline via OLD pdf.js releases (2.16 / 3.11 / 4.10), as shipped in older
// Firefox ESR / Electron apps / web viewers.  usage: node pdfjs_legacy.mjs <2|3|4> <file.pdf>...
// prints one JSON line per file: {"file","ok","pages","outline":[{title,level,page_index}],"warnings"}
import { readFile } from "node:fs/promises";
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const [ver, ...files] = process.argv.slice(2);
const warnings = [];
const cap = (...a) => warnings.push(a.map(String).join(" "));
const realOut = (o) => process.stdout.write(JSON.stringify(o) + "\n");
console.log = cap; console.warn = cap; console.info = cap;
let pdfjs;
if (ver === "4") pdfjs = await import("pdfjs4/legacy/build/pdf.mjs");
else pdfjs = require(`pdfjs${ver}/legacy/build/pdf.js`);
for (const file of files) {
  warnings.length = 0;
  try {
    const data = new Uint8Array(await readFile(file));
    const doc = await pdfjs.getDocument({ data, verbosity: 1, isEvalSupported: false, disableFontFace: true,
                                          stopAtErrors: false }).promise;
    const items = [];
    async function resolve(dest) {
      if (typeof dest === "string") dest = await doc.getDestination(dest);
      if (!Array.isArray(dest) || !dest.length) return -1;
      const r = dest[0];
      if (r && typeof r === "object") { try { return await doc.getPageIndex(r); } catch { return -1; } }
      return Number.isInteger(r) ? r : -1;
    }
    async function walk(list, lvl) {
      for (const it of list || []) {
        items.push({ title: it.title, level: lvl, page_index: await resolve(it.dest) });
        await walk(it.items, lvl + 1);
      }
    }
    await walk(await doc.getOutline(), 0);
    realOut({ file, ok: true, pages: doc.numPages, outline: items, warnings: [...warnings] });
    await doc.destroy();
  } catch (e) {
    realOut({ file, ok: false, error: String(e?.message ?? e), warnings: [...warnings] });
  }
}
