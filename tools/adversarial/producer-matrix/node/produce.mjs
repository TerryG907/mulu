// produce.mjs -- JavaScript PDF producers for the mulu producer-matrix run.
//
// usage: node produce.mjs <kind> <out.pdf> <pages> [cjk-font.ttf|otf]
//   kind: pdflib-objstm | pdflib-classic | pdflib-cjk | jspdf | pdfkitjs | pdfkitjs-outline
import { writeFile, readFile } from "node:fs/promises";
import { createWriteStream } from "node:fs";

const [kind, out, pagesArg, fontPath] = process.argv.slice(2);
const pages = Number(pagesArg || 8);
if (!kind || !out) {
  process.stderr.write("usage: node produce.mjs <kind> <out.pdf> <pages> [font]\n");
  process.exit(64);
}

const lines = (p) => [
  `Page ${p} of ${pages} - produced by ${kind}`,
  "Incremental updates (ISO 32000-1 7.5.6) append new objects after %%EOF.",
  "The outline tree uses /First, /Last, /Next, /Prev and /Parent links.",
];

async function pdflib(useObjectStreams, cjk) {
  const { PDFDocument, StandardFonts } = await import("pdf-lib");
  const doc = await PDFDocument.create();
  doc.setTitle("pdf-lib 矩阵 producer matrix");
  doc.setAuthor("mulu adversarial");
  doc.setProducer("pdf-lib (https://github.com/Hopding/pdf-lib)");
  let font;
  if (cjk && fontPath) {
    const fontkit = (await import("@pdf-lib/fontkit")).default;
    doc.registerFontkit(fontkit);
    font = await doc.embedFont(await readFile(fontPath), { subset: true });
  } else {
    font = await doc.embedFont(StandardFonts.Helvetica);
  }
  for (let p = 1; p <= pages; p++) {
    const pg = doc.addPage([595, 842]);
    let y = 780;
    const ls = cjk ? [`第 ${p} 页 · 中文 pdf-lib 子集字体`, ...lines(p)] : lines(p);
    for (const l of ls) {
      pg.drawText(l, { x: 50, y, size: 12, font });
      y -= 22;
    }
  }
  const bytes = await doc.save({ useObjectStreams });
  await writeFile(out, bytes);
}

async function jspdf() {
  const { jsPDF } = await import("jspdf");
  const doc = new jsPDF({ unit: "pt", format: "a4", compress: true });
  doc.setProperties({ title: "jsPDF producer matrix", author: "mulu adversarial" });
  for (let p = 1; p <= pages; p++) {
    if (p > 1) doc.addPage();
    let y = 60;
    for (const l of lines(p)) {
      doc.text(l, 50, y);
      y += 22;
    }
  }
  await writeFile(out, Buffer.from(doc.output("arraybuffer")));
}

async function pdfkitjs(withOutline) {
  const PDFDocument = (await import("pdfkit")).default;
  const doc = new PDFDocument({ autoFirstPage: false, info: { Title: "PDFKit-js 矩阵", Author: "mulu" } });
  const stream = createWriteStream(out);
  doc.pipe(stream);
  if (fontPath) doc.registerFont("cjk", fontPath);
  const outline = doc.outline;
  for (let p = 1; p <= pages; p++) {
    doc.addPage({ size: "A4" });
    if (fontPath) doc.font("cjk");
    doc.fontSize(18).text(`第 ${p} 页 Page ${p}`);
    doc.fontSize(11);
    for (const l of lines(p)) doc.text(l);
    if (withOutline && p <= 3) {
      const top = outline.addItem(`旧书签 old ${p}`);
      top.addItem(`旧子项 child ${p}.1`);
    }
  }
  doc.end();
  await new Promise((res, rej) => { stream.on("finish", res); stream.on("error", rej); });
}

switch (kind) {
  case "pdflib-objstm": await pdflib(true, false); break;
  case "pdflib-classic": await pdflib(false, false); break;
  case "pdflib-cjk": await pdflib(true, true); break;
  case "jspdf": await jspdf(); break;
  case "pdfkitjs": await pdfkitjs(false); break;
  case "pdfkitjs-outline": await pdfkitjs(true); break;
  default:
    process.stderr.write(`unknown kind ${kind}\n`);
    process.exit(64);
}
