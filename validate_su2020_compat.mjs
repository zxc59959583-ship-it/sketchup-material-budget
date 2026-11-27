import fs from "node:fs/promises";

const root = "src";
const loader = await fs.readFile(`${root}/su_material_budget.rb`, "utf8");
const ruby = await fs.readFile(`${root}/su_material_budget/main.rb`, "utf8");
const html = await fs.readFile(`${root}/su_material_budget/dialog_v07.html`, "utf8");
const scriptMatch = html.match(/<script>([\s\S]*?)<\/script>/i);
if (!scriptMatch) throw new Error("dialog script missing");
new Function(scriptMatch[1]);

if (ruby.includes(".filter_map")) throw new Error("Ruby 2.7 filter_map remains");
if (/^\s*def\s+\w+[!?=]?\s*=\s*[^\n]+$/m.test(ruby)) throw new Error("endless method syntax remains");
if (/\b_1\b/.test(ruby)) throw new Error("numbered block parameter remains");
if (/\.\.\s*[\]\)]/.test(ruby)) throw new Error("Ruby 2.6+ endless range syntax remains");
if (/\[\s*\.\./.test(ruby)) throw new Error("Ruby 2.7+ beginless range syntax remains");

const forbiddenJs = ["replaceAll(", "?.", "??", "Promise.allSettled", ".flatMap(", "Object.fromEntries("];
for (const token of forbiddenJs) {
  if (html.includes(token)) throw new Error(`CEF 64 incompatible JavaScript remains: ${token}`);
}

for (const token of ["MINIMUM_SKETCHUP_VERSION = 20", "Sketchup.version.to_i < MINIMUM_SKETCHUP_VERSION", "SU 2020+"]) {
  if (!(loader + html).includes(token)) throw new Error(`missing compatibility marker: ${token}`);
}

console.log(JSON.stringify({
  target: "SketchUp 2020+",
  rubyTarget: "2.5.x",
  htmlDialogTarget: "CEF 64 baseline",
  ruby27OnlyTokens: "absent",
  modernJsTokens: "absent",
  javascriptSyntax: "ok",
  minimumVersionGuard: "ok"
}, null, 2));
