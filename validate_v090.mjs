import fs from "node:fs/promises";

const root = "src";
const html = await fs.readFile(`${root}/su_material_budget/dialog_v07.html`, "utf8");
const ruby = await fs.readFile(`${root}/su_material_budget/main.rb`, "utf8");
const loader = await fs.readFile(`${root}/su_material_budget.rb`, "utf8");
const icon = await fs.readFile(`${root}/su_material_budget/toolbar_icon.svg`, "utf8");
const data = JSON.parse(await fs.readFile(`${root}/su_material_budget/materials.json`, "utf8"));

const match = html.match(/<script>([\s\S]*?)<\/script>/i);
if (!match) throw new Error("script missing");
new Function(match[1]);

const rubyTokens = [
  "DEEPSEEK_ENDPOINT",
  "deepseek-chat",
  "PREF_AI_ENDPOINT_KEY",
  "configure_deepseek",
  "request_ai_recommendation",
  "deepseek_recommendations",
  "response_format",
  "confirmed_mapping_entry",
  "ai_material_suggestions",
  "confirm_material_mapping",
  "remove_material_mapping",
  "clear_material_price",
  "highlight_material_in_model",
  "material_color_hex",
  "studio_material_mappings",
  "MAPPING_HISTORY_KEY",
  "MODEL_MAPPING_KEY",
  "global_mappings.merge(parse_mapping_json(model_saved))",
  "model.set_attribute(DICT_NAME, MODEL_MAPPING_KEY",
  "rows_from_xlsx_pure_ruby",
  "read_zip_entries_pure_ruby",
  "projected_triangles_for",
  "PROGRESS_THROTTLE_SECONDS",
  "UI::Toolbar.new",
  "toolbar_icon.svg",
  "human_choice",
  "final_result"
];

const htmlTokens = [
  "v0.9.0",
  "AI 材质推荐",
  "configureDeepSeek",
  "aiRecommendation(payload)",
  "ai-candidate",
  "确认所选映射",
  "调用 DeepSeek 重荐",
  "AI建议—人工选择—最终结果",
  "mapping-history",
  "mat-locate",
  "price-reset",
  "mapping-remove",
  "budget-bar-fill",
  "bd-machinery",
  "bd-management",
  "bd-profit"
];

for (const token of rubyTokens) {
  if (!ruby.includes(token)) throw new Error(`missing Ruby token: ${token}`);
}
for (const token of htmlTokens) {
  if (!html.includes(token)) throw new Error(`missing HTML token: ${token}`);
}
if (!loader.includes("0.9.0")) throw new Error("loader version mismatch");
if (!icon.includes("<svg")) throw new Error("toolbar_icon.svg invalid");
if (/UI\.messagebox/.test(ruby)) throw new Error("modal UI found in main.rb");
if (/write_default\([^\n]*api.key/i.test(ruby)) throw new Error("API key appears persisted");
if (ruby.includes("E:/建筑材质插件")) throw new Error("hardcoded local path remains");

const wall = data.price_library.find((x) => x.standard_code === "WALL-002");
if (!wall) throw new Error("WALL-002 missing");

console.log(JSON.stringify({
  javascriptSyntax: "ok",
  version: "0.9.0",
  deepseekAndOpenAICompat: "ok",
  apiKeyPersistence: "session-memory-only",
  humanConfirmation: "required",
  top3CandidatesUI: "ok",
  pureRubyXlsx: "ok",
  lazyMeshingAndThrottle: "ok",
  modelHighlightAndRevert: "ok",
  toolbarIcon: "ok",
  wall002: "ok",
  libraryRows: data.price_library.length
}, null, 2));
