const state = {
activeTab: "aging",
detailPage: 1,
detailTotalRows: 0,
detailSortField: null,
detailSortDirection: "DESC"
};
const $ = id => document.getElementById(id);
function selectedValues(select) {
const value = select.value;
return value ? [value] : [];
}
function topAgeSubrangeValues() {
const container = $("topAgeSubrange");
if (!container) return ["all"];
const checked = Array.from(container.querySelectorAll('input[type="checkbox"]:checked'))
.map(input => input.value)
.filter(Boolean);
return checked.length ? checked : ["all"];
}
function updateTopAgeSubrangeSummary() {
const container = $("topAgeSubrange");
const text = $("topAgeSubrangeText");
if (!container || !text) return;
const inputs = Array.from(container.querySelectorAll('input[type="checkbox"]'));
const allInput = inputs.find(item => item.value === "all");
if (allInput && allInput.checked) {
text.textContent = "全部（0～365天）";
text.title = "全部（0～365天）";
return;
}
const labels = inputs
.filter(item => item.value !== "all" && item.checked)
.map(item => item.closest("label")?.querySelector("span")?.textContent?.trim() || item.value);
const fullText = labels.join("、") || "全部（0～365天）";
text.textContent = labels.length <= 2 ? fullText : `已選 ${labels.length} 個區間`;
text.title = fullText;
}
function setTopAgeSubrangeMenuOpen(open) {
const trigger = $("topAgeSubrangeTrigger");
const menu = $("topAgeSubrangeMenu");
if (!trigger || !menu) return;
menu.classList.toggle("hidden", !open);
trigger.classList.toggle("open", open);
trigger.setAttribute("aria-expanded", open ? "true" : "false");
}
function resetTopAgeSubranges() {
const container = $("topAgeSubrange");
if (!container) return;
container.querySelectorAll('input[type="checkbox"]').forEach(input => {
input.checked = input.value === "all";
});
updateTopAgeSubrangeSummary();
setTopAgeSubrangeMenuOpen(false);
}
function initTopAgeSubrangeMultiSelect() {
const container = $("topAgeSubrange");
const trigger = $("topAgeSubrangeTrigger");
const menu = $("topAgeSubrangeMenu");
if (!container || !trigger || !menu) return;
const inputs = Array.from(container.querySelectorAll('input[type="checkbox"]'));
trigger.addEventListener("click", event => {
event.stopPropagation();
setTopAgeSubrangeMenuOpen(menu.classList.contains("hidden"));
});
menu.addEventListener("click", event => event.stopPropagation());
for (const input of inputs) {
input.addEventListener("change", () => {
const allInput = inputs.find(item => item.value === "all");
if (input.value === "all" && input.checked) {
inputs.forEach(item => { if (item !== input) item.checked = false; });
} else {
if (input.value !== "all" && input.checked && allInput) allInput.checked = false;
const selectedBuckets = inputs.filter(item => item.value !== "all" && item.checked);
if (selectedBuckets.length === 0 && allInput) allInput.checked = true;
}
updateTopAgeSubrangeSummary();
});
}
document.addEventListener("click", event => {
if (!container.contains(event.target)) setTopAgeSubrangeMenuOpen(false);
});
document.addEventListener("keydown", event => {
if (event.key === "Escape") setTopAgeSubrangeMenuOpen(false);
});
updateTopAgeSubrangeSummary();
}
function searchableSelectedValues(id) {
const instance = detailSearchSelects[id];
if (!instance) return selectedValues($(id));
const selected = String(instance.select.value || "").trim();
if (selected) return [selected];
// Dynamic searchable filters must also accept text typed directly by the user.
// Previously the input event cleared the hidden native <select>, so pressing
// 查詢 without clicking a dropdown option silently removed the filter.
if (instance.dynamic) {
const typed = String(instance.input.value || "").trim();
return typed ? [typed] : [];
}
return [];
}
function fillSelect(select, values, includeBlank = true, blankText = "全部") {
select.replaceChildren();
if (includeBlank) {
const blank = document.createElement("option");
blank.value = "";
blank.textContent = blankText;
select.appendChild(blank);
}
for (const item of values || []) {
const option = document.createElement("option");
if (item && typeof item === "object") {
option.value = item.value;
option.textContent = item.label;
} else {
option.value = item;
option.textContent = item;
}
select.appendChild(option);
}
}
const detailSearchSelects = {};
class SearchableSelect {
constructor(select, config = {}) {
this.select = select;
this.config = config;
this.dynamic = typeof config.loadOptions === "function";
this.localOptions = [];
this.remoteOptions = [];
this.highlightIndex = -1;
this.requestSerial = 0;
this.debounceTimer = null;
this.wrapper = document.createElement("div");
this.wrapper.className = "searchable-select";
this.input = document.createElement("input");
this.input.type = "text";
this.input.className = "searchable-select-input";
this.input.autocomplete = "off";
this.input.spellcheck = false;
this.input.placeholder = config.placeholder || "全部（可輸入搜尋）";
this.input.setAttribute("role", "combobox");
this.input.setAttribute("aria-autocomplete", "list");
this.input.setAttribute("aria-expanded", "false");
this.toggleButton = document.createElement("button");
this.toggleButton.type = "button";
this.toggleButton.className = "searchable-select-toggle";
this.toggleButton.textContent = "▾";
this.toggleButton.title = "顯示選項";
this.toggleButton.setAttribute("aria-label", "顯示選項");
this.menu = document.createElement("div");
this.menu.className = "searchable-select-menu hidden";
this.menu.setAttribute("role", "listbox");
this.wrapper.append(this.input, this.toggleButton, this.menu);
this.select.classList.add("searchable-native-select");
this.select.insertAdjacentElement("afterend", this.wrapper);
this.readLocalOptions();
this.syncFromSelect();
this.bindEvents();
this.syncDisabled();
}
readLocalOptions() {
this.localOptions = Array.from(this.select.options)
.filter(option => option.value !== "")
.map(option => ({
value: option.value,
label: option.textContent || option.value
}));
}
syncFromSelect() {
const option = this.select.selectedOptions[0];
this.input.value = option && option.value
? (option.textContent || option.value)
: "";
}
syncDisabled() {
const disabled = Boolean(this.select.disabled);
this.input.disabled = disabled;
this.toggleButton.disabled = disabled;
this.wrapper.classList.toggle("is-disabled", disabled);
if (disabled) this.close();
}
setDisabled(disabled) {
this.select.disabled = disabled;
this.syncDisabled();
}
clear() {
this.select.value = "";
this.input.value = "";
this.highlightIndex = -1;
this.close();
}
setLocalOptions(values) {
fillSelect(this.select, values, true);
this.readLocalOptions();
this.clear();
}
getCurrentOptions() {
return this.dynamic ? this.remoteOptions : this.localOptions;
}
filterLocalOptions(keyword) {
const prefix = String(keyword || "").trim().toLocaleUpperCase("zh-TW");
if (!prefix) return this.localOptions.slice(0, 100);
return this.localOptions
.filter(item => item.label.toLocaleUpperCase("zh-TW").startsWith(prefix)
|| item.value.toLocaleUpperCase("zh-TW").startsWith(prefix))
.slice(0, 100);
}
async refreshOptions(keyword = "") {
if (this.select.disabled) return;
if (!this.dynamic) {
this.remoteOptions = this.filterLocalOptions(keyword);
this.renderOptions(this.remoteOptions);
return;
}
const serial = ++this.requestSerial;
this.renderStatus("讀取中...");
try {
const values = await this.config.loadOptions(keyword);
if (serial !== this.requestSerial) return;
this.remoteOptions = (values || []).map(item => (
item && typeof item === "object"
? {value: String(item.value ?? ""), label: String(item.label ?? item.value ?? "")}
: {value: String(item ?? ""), label: String(item ?? "")}
)).filter(item => item.value);
this.renderOptions(this.remoteOptions);
} catch (error) {
if (serial !== this.requestSerial) return;
this.renderStatus(error.message || "選項讀取失敗", true);
}
}
renderStatus(message, isError = false) {
this.menu.replaceChildren();
const row = document.createElement("div");
row.className = `searchable-select-status${isError ? " is-error" : ""}`;
row.textContent = message;
this.menu.appendChild(row);
this.open();
}
renderOptions(options) {
this.menu.replaceChildren();
this.highlightIndex = -1;
if (!options.length) {
this.renderStatus("沒有符合的選項");
return;
}
const all = document.createElement("button");
all.type = "button";
all.className = "searchable-select-option is-all";
all.dataset.value = "";
all.textContent = "全部";
all.addEventListener("mousedown", event => event.preventDefault());
all.addEventListener("click", () => this.choose("", ""));
this.menu.appendChild(all);
for (const item of options) {
const button = document.createElement("button");
button.type = "button";
button.className = "searchable-select-option";
button.dataset.value = item.value;
button.textContent = item.label;
button.title = item.label;
button.setAttribute("role", "option");
button.addEventListener("mousedown", event => event.preventDefault());
button.addEventListener("click", () => this.choose(item.value, item.label));
this.menu.appendChild(button);
}
this.open();
}
choose(value, label) {
let option = Array.from(this.select.options).find(item => item.value === value);
if (!option) {
option = document.createElement("option");
option.value = value;
option.textContent = label || value;
this.select.appendChild(option);
}
this.select.value = value;
this.input.value = value ? (label || option.textContent || value) : "";
this.select.dispatchEvent(new Event("change", {bubbles: true}));
this.close();
}
open() {
if (this.select.disabled) return;
this.menu.classList.remove("hidden");
this.wrapper.classList.add("is-open");
this.input.setAttribute("aria-expanded", "true");
}
close() {
this.menu.classList.add("hidden");
this.wrapper.classList.remove("is-open");
this.input.setAttribute("aria-expanded", "false");
this.highlightIndex = -1;
}
moveHighlight(direction) {
const options = Array.from(
this.menu.querySelectorAll(".searchable-select-option")
);
if (!options.length) return;
this.highlightIndex += direction;
if (this.highlightIndex < 0) this.highlightIndex = options.length - 1;
if (this.highlightIndex >= options.length) this.highlightIndex = 0;
options.forEach((option, index) => {
option.classList.toggle("is-highlighted", index === this.highlightIndex);
});
options[this.highlightIndex].scrollIntoView({block: "nearest"});
}
bindEvents() {
this.input.addEventListener("focus", () => {
this.refreshOptions(this.input.value);
});
this.input.addEventListener("input", () => {
this.select.value = "";
clearTimeout(this.debounceTimer);
this.debounceTimer = setTimeout(
() => this.refreshOptions(this.input.value),
220
);
});
this.input.addEventListener("keydown", event => {
if (event.key === "ArrowDown") {
event.preventDefault();
if (this.menu.classList.contains("hidden")) {
this.refreshOptions(this.input.value);
} else {
this.moveHighlight(1);
}
} else if (event.key === "ArrowUp") {
event.preventDefault();
this.moveHighlight(-1);
} else if (event.key === "Enter") {
const highlighted = this.menu.querySelector(
".searchable-select-option.is-highlighted"
);
if (highlighted) {
event.preventDefault();
highlighted.click();
}
} else if (event.key === "Escape") {
this.close();
}
});
this.toggleButton.addEventListener("click", () => {
if (this.menu.classList.contains("hidden")) {
this.input.focus();
this.refreshOptions(this.input.value);
} else {
this.close();
}
});
}
}
function initDetailSearchableSelects() {
const dynamicConfig = {
itemNos: "item_no",
warehouses: "warehouse",
colorNos: "color_no",
zeroProjects: "zero_project",
salespersons: "salesperson",
businessDepartments: "business_department",
grades: "grade",
reasonCodes: "reason_code",
customers: "customer",
orderTypes: "order_type"
};
for (const [id, field] of Object.entries(dynamicConfig)) {
detailSearchSelects[id] = new SearchableSelect($(id), {
placeholder: "全部（可輸入搜尋）",
loadOptions: async keyword => {
const type = $("inventoryType").value;
const params = new URLSearchParams({
type,
field,
keyword: String(keyword || "").trim(),
operating_center: $("operatingCenters").value || "",
limit: "100"
});
const response = await fetch(
`/api/detail/option-search?${params.toString()}`,
{cache: "no-store"}
);
if (!response.ok) throw new Error(await readError(response));
const data = await response.json();
return data.options || [];
}
});
}
detailSearchSelects.greigeTypes = new SearchableSelect($("greigeTypes"), {
placeholder: "全部（可輸入搜尋）"
});
detailSearchSelects.project302Flags = new SearchableSelect($("project302Flags"), {
placeholder: "全部（可輸入搜尋）"
});
}
function closeAllSearchableSelects(except = null) {
for (const instance of Object.values(detailSearchSelects)) {
if (instance !== except) instance.close();
}
}
function setLoading(active) {
$("loading").classList.toggle("hidden", !active);
}
function showError(message) {
$("errorBox").textContent = message || "發生未預期錯誤。";
$("errorBox").classList.remove("hidden");
}
function clearError() {
$("errorBox").classList.add("hidden");
}
async function readError(response) {
try {
const data = await response.json();
return data.detail || JSON.stringify(data);
} catch (_) {
return `${response.status} ${response.statusText}`;
}
}
function formatCell(value, columnName = "") {
if (value === null || value === undefined || value === "") return "";
const text = String(value);
if (columnName === "儲位" || columnName === "儲位名稱") {
return text;
}
const numeric = Number(text);
if (Number.isFinite(numeric)) {
if (columnName.includes("百分比") || columnName.includes("提列率")) {
return `${numeric.toLocaleString("zh-TW", {maximumFractionDigits: 2})}%`;
}
return numeric.toLocaleString("zh-TW", {maximumFractionDigits: 2});
}
return text;
}
function renderTable(containerId, columns, rows, sortable = false) {
const container = $(containerId);
container.replaceChildren();
const table = document.createElement("table");
const thead = document.createElement("thead");
const tbody = document.createElement("tbody");
const header = document.createElement("tr");
for (const column of columns || []) {
const name = column.name || column;
const label = column.label || name;
const th = document.createElement("th");
th.textContent = label;
if (sortable) {
th.title = "點擊排序";
th.addEventListener("click", () => {
if (state.detailSortField === name) {
state.detailSortDirection =
state.detailSortDirection === "ASC" ? "DESC" : "ASC";
} else {
state.detailSortField = name;
state.detailSortDirection = "ASC";
}
state.detailPage = 1;
searchDetail();
});
}
header.appendChild(th);
}
thead.appendChild(header);
for (const row of rows || []) {
const tr = document.createElement("tr");
const summaryValue = String(
row["排行"] || row["料件編號"] || row["類型分類"] || row["庫齡區間"] || ""
);
if (!sortable && (
["總計", "其他"].includes(summaryValue)
|| summaryValue.endsWith("合計")
|| summaryValue.includes("大數量小計")
)) {
tr.classList.add("summary-row");
}
for (const column of columns || []) {
const name = column.name || column;
const td = document.createElement("td");
const value = formatCell(row[name], name);
td.textContent = value;
td.title = value;
tr.appendChild(td);
}
tbody.appendChild(tr);
}
table.appendChild(thead);
table.appendChild(tbody);
container.appendChild(table);
}
function dashboardPayload() {
return {
snapshot_date: null,
base_snapshot_date: $("baseSnapshotDate").value || null,
compare_snapshot_date: $("compareSnapshotDate").value || null,
inventory_types: selectedValues($("inventoryTypes")),
fabric_types: selectedValues($("fabricTypes")),
elastic_flags: selectedValues($("elasticFlags")),
project_flags: selectedValues($("projectFlags")),
top_n: $("topN").value === "all" ? null : Number($("topN").value),
top_type: $("topType") ? ($("topType").value || "2") : "2",
top_age_from: $("topAgeFrom") && $("topAgeFrom").value !== "" ? Number($("topAgeFrom").value) : 0,
top_age_to: $("topAgeTo") && $("topAgeTo").value !== "" ? Number($("topAgeTo").value) : null,
top_age_subrange: topAgeSubrangeValues()
};
}
async function postJson(url, payload) {
const response = await fetch(url, {
method: "POST",
headers: {"Content-Type": "application/json"},
body: JSON.stringify(payload)
});
if (!response.ok) throw new Error(await readError(response));
return response.json();
}
async function loadDashboardOptions() {
const response = await fetch("/api/dashboard/options", {cache: "no-store"});
if (!response.ok) throw new Error(await readError(response));
const data = await response.json();
const mapping = data.mapping || {};
$("dashboardSource").textContent =
`分析來源：${data.analysis_source || "未辨識"}`
+ `；資料範圍：${data.data_scope || "CXCR002 月結庫存 Fact"}`
+ `；最新月份：${data.latest_report_period || data.latest_snapshot_date || "無"}`
+ `；提列口徑：${data.provision_mode || "未辨識"}`;
const snapshotOptions = (data.snapshot_dates || []).map(value => ({
value,
label: value
}));
if (data.snapshot_enabled) {
fillSelect($("baseSnapshotDate"), snapshotOptions, false);
fillSelect($("compareSnapshotDate"), snapshotOptions, false);
$("baseSnapshotDate").value =
data.previous_snapshot_date || data.latest_snapshot_date || "";
$("compareSnapshotDate").value = data.latest_snapshot_date || "";
} else {
fillSelect($("baseSnapshotDate"), [], true, "不足兩個可比較月份");
fillSelect($("compareSnapshotDate"), [], true, "不足兩個可比較月份");
$("baseSnapshotDate").disabled = true;
$("compareSnapshotDate").disabled = true;
}
fillSelect($("inventoryTypes"), data.options.inventory_type, true);
fillSelect($("fabricTypes"), data.options.fabric_type, true);
fillSelect($("elasticFlags"), data.options.elastic_flag, true);
fillSelect($("projectFlags"), data.options.project_302, true);
const available = data.available_filters || {};
const elasticField = $("elasticFlags").closest(".field");
if (elasticField) {
elasticField.classList.toggle("hidden", available.elastic_flag === false);
}
const projectField = $("projectFlags").closest(".field");
if (projectField) {
projectField.classList.toggle("hidden", available.project_302 === false);
}
}
function updateTopAgeSubrangeVisibility() {
const field = document.querySelector(".age-subrange-field");
if (!field) return;
const isTopN = state.activeTab === "topn" || state.activeTab === "responsibility";
const fromValue = $("topAgeFrom") ? $("topAgeFrom").value : "";
const toValue = $("topAgeTo") ? $("topAgeTo").value : "";
const show = isTopN && fromValue === "0" && toValue === "1";
field.classList.toggle("hidden", !show);
if (!show) setTopAgeSubrangeMenuOpen(false);
}

function updateDashboardFilterVisibility() {
const isComparison = state.activeTab === "comparison";
const isTopN = state.activeTab === "topn" || state.activeTab === "responsibility";
const isStructure = state.activeTab === "aging" || state.activeTab === "category";
document.querySelectorAll(".comparison-only").forEach(
node => node.classList.toggle("hidden", !isComparison)
);
document.querySelectorAll(".topn-only").forEach(
node => node.classList.toggle("hidden", !isTopN)
);
document.querySelectorAll(".topn-page-only").forEach(
node => node.classList.toggle("hidden", state.activeTab !== "topn")
);
document.querySelectorAll(".structure-only").forEach(
node => node.classList.toggle("hidden", !isStructure)
);
updateTopAgeSubrangeVisibility();
$("dashboardFilterPanel").classList.toggle("hidden", state.activeTab === "detail");
}
function clearComparisonTables(message = "") {
renderTable("comparisonYarnTable", [], []);
renderTable("comparisonGreigeTable", [], []);
$("comparisonSummary").textContent = message;
}
async function searchDashboard() {
clearError();
setLoading(true);
const payload = dashboardPayload();
try {
if (state.activeTab === "aging") {
const data = await postJson("/api/dashboard/aging", payload);
renderTable("agingTable", data.columns, data.rows);
} else if (state.activeTab === "category") {
const data = await postJson("/api/dashboard/category", payload);
renderTable("categoryTable", data.columns, data.rows);
} else if (state.activeTab === "comparison") {
const data = await postJson("/api/dashboard/period-comparison", payload);
if (!data.available) {
clearComparisonTables(data.message || "目前無法執行兩期存貨差異。 ");
} else {
$("comparisonSummary").textContent =
`基準月份：${data.base_snapshot_date}；比較月份：${data.compare_snapshot_date}`
+ `；差異＝${data.difference_definition}`;
renderTable("comparisonYarnTable", data.yarn.columns, data.yarn.rows);
renderTable("comparisonGreigeTable", data.knit.columns, data.knit.rows);
}
} else if (state.activeTab === "topn") {
const data = await postJson("/api/dashboard/top-items", payload);
renderTable("topnFlatTable", data.flat.columns, data.flat.rows);
renderTable("topnKnitTable", data.knit.columns, data.knit.rows);
if ($("topnFlatTitle")) {
$("topnFlatTitle").textContent =
`胚布${data.top_n_label === "全部" ? "全部" : `前 ${data.top_n_label || payload.top_n} 大`}：平織`;
}
if ($("topnKnitTitle")) {
$("topnKnitTitle").textContent =
`胚布${data.top_n_label === "全部" ? "全部" : `前 ${data.top_n_label || payload.top_n} 大`}：針織`;
}
$("topnNote").textContent =
`CXCR002 ${data.report_period}；類型：胚布`
+ `；庫齡：${data.age_label || "0～2年"}`
+ `；平織／針織各自獨立排名`;
} else if (state.activeTab === "responsibility") {
const data = await postJson("/api/dashboard/responsibility", payload);
renderTable(
"responsibilityFlatTable",
data.flat.columns,
data.flat.rows
);
renderTable(
"responsibilityKnitTable",
data.knit.columns,
data.knit.rows
);
if ($("responsibilityFlatTitle")) {
$("responsibilityFlatTitle").textContent =
`胚布${data.top_n_label === "全部" ? "全部" : `前 ${data.top_n_label || payload.top_n} 大`}：平織－責任歸屬與庫齡分析`;
}
if ($("responsibilityKnitTitle")) {
$("responsibilityKnitTitle").textContent =
`胚布${data.top_n_label === "全部" ? "全部" : `前 ${data.top_n_label || payload.top_n} 大`}：針織－責任歸屬與庫齡分析`;
}
$("responsibilityNote").textContent =
`CXCR002 ${data.report_period}；庫齡：${data.age_label || "0～2年"}`
+ `；Top ${data.top_n_label || data.top_n || payload.top_n || "全部"}；使用 Fact 權責歸屬欄位`;
}
} catch (error) {
showError(error.message);
} finally {
setLoading(false);
}
}
async function exportDashboardXlsx() {
clearError();
if (state.activeTab === "detail") return;
const button = $("dashboardExportXlsxBtn");
const originalText = button ? button.textContent : "";
const controller = new AbortController();
const timeoutId = setTimeout(() => controller.abort(), 5 * 60 * 1000);
try {
if (button) {
button.disabled = true;
button.textContent = "匯出中...";
}
setLoading(true);
const response = await fetch(
`/api/dashboard/export/xlsx/${encodeURIComponent(state.activeTab)}`,
{
method: "POST",
headers: {"Content-Type": "application/json"},
body: JSON.stringify(dashboardPayload()),
signal: controller.signal,
cache: "no-store"
}
);
if (!response.ok) throw new Error(await readError(response));
const blob = await response.blob();
if (!blob || blob.size === 0) throw new Error("伺服器已回應，但匯出檔案內容為空。");
const disposition = response.headers.get("Content-Disposition") || "";
let filename = "dashboard_export.xlsx";
const utf8Match = disposition.match(/filename\*=UTF-8''([^;]+)/i);
const normalMatch = disposition.match(/filename="?([^";]+)"?/i);
if (utf8Match && utf8Match[1]) {
filename = decodeURIComponent(utf8Match[1]);
} else if (normalMatch && normalMatch[1]) {
filename = normalMatch[1];
}
const url = URL.createObjectURL(blob);
const link = document.createElement("a");
link.href = url;
link.download = filename;
link.style.display = "none";
document.body.appendChild(link);
link.click();
setTimeout(() => {
URL.revokeObjectURL(url);
link.remove();
}, 3000);
} catch (error) {
const message = error.name === "AbortError"
? "匯出逾時，請縮小查詢條件後再試。"
: (error.message || "匯出失敗。");
showError(message);
} finally {
clearTimeout(timeoutId);
setLoading(false);
if (button) {
button.disabled = false;
button.textContent = originalText;
}
}
}

function clearDashboardFilters() {
for (const select of [
$("inventoryTypes"), $("fabricTypes"), $("elasticFlags"), $("projectFlags")
]) {
select.value = "";
}
$("topN").value = "20";
if ($("topType")) $("topType").value = "2";
if ($("topAgeFrom")) $("topAgeFrom").value = "0";
if ($("topAgeTo")) $("topAgeTo").value = "2";
resetTopAgeSubranges();
updateTopAgeSubrangeVisibility();
if ($("topnFlatTitle")) $("topnFlatTitle").textContent = "胚布前 N 大：平織";
if ($("topnKnitTitle")) $("topnKnitTitle").textContent = "胚布前 N 大：針織";
}
async function loadDetailSchemaAndOptions() {
clearError();
const type = $("inventoryType").value;
const isType2 = type === "2";
if (detailSearchSelects.greigeTypes) {
detailSearchSelects.greigeTypes.setDisabled(!isType2);
if (!isType2) detailSearchSelects.greigeTypes.clear();
} else {
$("greigeTypes").disabled = !isType2;
if (!isType2) $("greigeTypes").value = "";
}
for (const [id, instance] of Object.entries(detailSearchSelects)) {
if (id !== "greigeTypes") instance.clear();
}
try {
const schemaResponse = await fetch(
`/api/detail/schema?type=${encodeURIComponent(type)}`,
{cache: "no-store"}
);
if (!schemaResponse.ok) throw new Error(await readError(schemaResponse));
const schema = await schemaResponse.json();
$("viewName").textContent =
`${schema.view_name}（已隱藏：${schema.hidden_columns.join("、")}）`;
const mapping = schema.mapping || {};
$("operatingCenters").disabled = !mapping.operating_center;
if ($("operatingCenters").disabled) {
$("operatingCenters").value = "";
}
const filterControlMap = {
itemNos: "item_no",
warehouses: "warehouse",
colorNos: "color_no",
zeroProjects: "zero_project",
salespersons: "salesperson",
businessDepartments: "business_department",
grades: "grade",
reasonCodes: "reason_code",
customers: "customer",
orderTypes: "order_type"
};
for (const [id, field] of Object.entries(filterControlMap)) {
const instance = detailSearchSelects[id];
if (!instance) continue;
const disabled = !mapping[field];
instance.setDisabled(disabled);
if (disabled) instance.clear();
}
} catch (error) {
showError(error.message);
}
}
function detailPayload() {
return {
type: $("inventoryType").value,
operating_centers: selectedValues($("operatingCenters")),
item_nos: searchableSelectedValues("itemNos"),
warehouses: searchableSelectedValues("warehouses"),
color_nos: searchableSelectedValues("colorNos"),
zero_projects: searchableSelectedValues("zeroProjects"),
project_302_flags: selectedValues($("project302Flags")),
salespersons: searchableSelectedValues("salespersons"),
business_departments: searchableSelectedValues("businessDepartments"),
grades: searchableSelectedValues("grades"),
reason_codes: searchableSelectedValues("reasonCodes"),
customers: searchableSelectedValues("customers"),
order_types: searchableSelectedValues("orderTypes"),
greige_types: $("inventoryType").value === "2"
? selectedValues($("greigeTypes"))
: [],
inbound_date_start: $("dateStart").value || null,
inbound_date_end: $("dateEnd").value || null,
page: state.detailPage,
page_size: Number($("pageSize").value),
sort_field: state.detailSortField,
sort_direction: state.detailSortDirection
};
}
function updatePagination() {
const pageSize = Number($("pageSize").value);
const totalPages = Math.max(1, Math.ceil(state.detailTotalRows / pageSize));
$("pageLabel").textContent = `第 ${state.detailPage} / ${totalPages} 頁`;
$("prevBtn").disabled = state.detailPage <= 1;
$("nextBtn").disabled = state.detailPage >= totalPages;
}
async function searchDetail() {
clearError();
setLoading(true);
try {
const data = await postJson("/api/detail/search", detailPayload());
state.detailTotalRows = data.total_rows;
$("resultSummary").textContent =
`共 ${data.total_rows.toLocaleString("zh-TW")} 筆，本頁 ${data.rows.length.toLocaleString("zh-TW")} 筆`;
renderTable("detailTable", data.columns, data.rows, true);
updatePagination();
} catch (error) {
showError(error.message);
} finally {
setLoading(false);
}
}
function clearDetailFilters() {
$("dateStart").value = "";
$("dateEnd").value = "";
$("operatingCenters").value = "";
for (const instance of Object.values(detailSearchSelects)) {
instance.clear();
}
state.detailPage = 1;
state.detailSortField = null;
state.detailSortDirection = "DESC";
}
async function exportDetail(path, buttonId) {
clearError();
const button = $(buttonId);
const originalText = button ? button.textContent : "";
const controller = new AbortController();
const timeoutId = setTimeout(
() => controller.abort(),
5 * 60 * 1000
);
try {
if (button) {
button.disabled = true;
button.textContent = "匯出中...";
}
setLoading(true);
const payload = detailPayload();
payload.page = 1;
const response = await fetch(path, {
method: "POST",
headers: {
"Content-Type": "application/json"
},
body: JSON.stringify(payload),
signal: controller.signal,
cache: "no-store"
});
if (!response.ok) {
throw new Error(await readError(response));
}
const blob = await response.blob();
if (!blob || blob.size === 0) {
throw new Error("伺服器已回應，但匯出檔案內容為空。");
}
const disposition =
response.headers.get("Content-Disposition") || "";
let filename = path.endsWith("/xlsx")
? "inventory_export.xlsx"
: "inventory_export.csv";
const utf8Match =
disposition.match(/filename\*=UTF-8''([^;]+)/i);
const normalMatch =
disposition.match(/filename="([^"]+)"/i);
if (utf8Match && utf8Match[1]) {
filename = decodeURIComponent(utf8Match[1]);
} else if (normalMatch && normalMatch[1]) {
filename = normalMatch[1];
}
const url = URL.createObjectURL(blob);
const link = document.createElement("a");
link.href = url;
link.download = filename;
link.style.display = "none";
document.body.appendChild(link);
link.click();
setTimeout(() => {
URL.revokeObjectURL(url);
link.remove();
}, 3000);
} catch (error) {
const message =
error.name === "AbortError"
? "匯出逾時，請縮小查詢條件後再試。"
: (error.message || "匯出失敗。");
showError(message);
const errorBox = $("errorBox");
if (errorBox) {
errorBox.scrollIntoView({
behavior: "smooth",
block: "center"
});
}
} finally {
clearTimeout(timeoutId);
setLoading(false);
if (button) {
button.disabled = false;
button.textContent = originalText;
}
}
}
async function checkHealth() {
const badge = $("healthBadge");
const controller = new AbortController();
const timeoutId = setTimeout(() => controller.abort(), 15000);
try {
const response = await fetch("/api/health", {
signal: controller.signal,
cache: "no-store"
});
if (!response.ok) throw new Error(await readError(response));
badge.textContent = "資料庫連線正常";
badge.className = "badge badge-ok";
} catch (error) {
badge.textContent = "資料庫連線失敗";
badge.className = "badge badge-error";
const message = error.name === "AbortError"
? "資料庫連線逾時，請檢查 .env、SQL Server 網路與 ODBC Driver。"
: error.message;
showError(message);
} finally {
clearTimeout(timeoutId);
}
}
function switchTab(tabName) {
state.activeTab = tabName;
document.querySelectorAll(".tab").forEach(
button => button.classList.toggle("active", button.dataset.tab === tabName)
);
document.querySelectorAll(".tab-page").forEach(
page => page.classList.toggle("active", page.id === tabName)
);
updateDashboardFilterVisibility();
if (tabName !== "detail") {
searchDashboard();
}
}
document.addEventListener("click", event => {
const clickedInstance = Object.values(detailSearchSelects).find(
instance => instance.wrapper.contains(event.target)
);
closeAllSearchableSelects(clickedInstance || null);
});
initDetailSearchableSelects();
document.querySelectorAll(".tab").forEach(button => {
button.addEventListener("click", () => {
if (!button.disabled) switchTab(button.dataset.tab);
});
});
$("dashboardSearchBtn").addEventListener("click", searchDashboard);
$("dashboardClearBtn").addEventListener("click", clearDashboardFilters);
$("dashboardExportXlsxBtn").addEventListener("click", exportDashboardXlsx);
if ($("topAgeFrom")) $("topAgeFrom").addEventListener("change", updateTopAgeSubrangeVisibility);
if ($("topAgeTo")) $("topAgeTo").addEventListener("change", updateTopAgeSubrangeVisibility);
initTopAgeSubrangeMultiSelect();
$("operatingCenters").addEventListener("change", () => {
for (const [id, instance] of Object.entries(detailSearchSelects)) {
if (id !== "greigeTypes" && id !== "project302Flags") {
instance.clear();
}
}
state.detailPage = 1;
state.detailSortField = null;
state.detailSortDirection = "DESC";
});
$("inventoryType").addEventListener("change", async () => {
clearDetailFilters();
await loadDetailSchemaAndOptions();
});
$("detailSearchBtn").addEventListener("click", () => {
state.detailPage = 1;
searchDetail();
});
$("detailClearBtn").addEventListener("click", clearDetailFilters);
$("exportXlsxBtn").addEventListener(
"click",
event => {
event.preventDefault();
exportDetail(
"/api/detail/export/xlsx",
"exportXlsxBtn"
);
}
);
$("exportCsvBtn").addEventListener(
"click",
event => {
event.preventDefault();
exportDetail(
"/api/detail/export/csv",
"exportCsvBtn"
);
}
);
$("prevBtn").addEventListener("click", () => {
if (state.detailPage > 1) {
state.detailPage -= 1;
searchDetail();
}
});
$("nextBtn").addEventListener("click", () => {
state.detailPage += 1;
searchDetail();
});
$("pageSize").addEventListener("change", () => {
state.detailPage = 1;
searchDetail();
});
$("detailCollapseBtn").addEventListener("click", () => {
const body = $("detailFilterBody");
const button = $("detailCollapseBtn");
const collapsed = body.classList.toggle("collapsed");
button.textContent = collapsed ? "展開查詢條件" : "收合查詢條件";
button.setAttribute("aria-expanded", String(!collapsed));
$("detailFilterPanel").classList.toggle("is-collapsed", collapsed);
});
(async function init() {
await checkHealth();
try {
await loadDashboardOptions();
} catch (error) {
showError(error.message);
}
await loadDetailSchemaAndOptions();
updateDashboardFilterVisibility();
await searchDashboard();
})();
