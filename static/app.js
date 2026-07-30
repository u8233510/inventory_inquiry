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
            // 尚未選到正式項目時，實際查詢值維持空白。
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
        salespersons: "salesperson",
        businessDepartments: "business_department",
        grades: "grade",
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
        const th = document.createElement("th");
        th.textContent = name;
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
            row["料件編號"] || row["類型分類"] || row["庫齡區間"] || ""
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
        // 一般分析永遠查目前最新庫存；保留欄位是為了日後重新啟用兩期差異。
        snapshot_date: null,
        base_snapshot_date: $("baseSnapshotDate").value || null,
        compare_snapshot_date: $("compareSnapshotDate").value || null,
        inventory_types: selectedValues($("inventoryTypes")),
        fabric_types: selectedValues($("fabricTypes")),
        elastic_flags: selectedValues($("elasticFlags")),
        project_flags: selectedValues($("projectFlags")),
        top_n: Number($("topN").value)
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
        + `；資料範圍：目前最新庫存`
        + `；彈性欄位：${mapping.elastic_flag || "缺少"}`
        + `；提列口徑：${data.provision_mode || "未辨識"}`;

    const snapshotOptions = (data.snapshot_dates || []).map(value => ({
        value,
        label: value
    }));

    // 兩期差異程式保留，但頁籤暫停。一般分析不再提供快照日篩選。
    if (data.snapshot_enabled) {
        fillSelect($("baseSnapshotDate"), snapshotOptions, false);
        fillSelect($("compareSnapshotDate"), snapshotOptions, false);

        $("baseSnapshotDate").value =
            data.previous_snapshot_date || data.latest_snapshot_date || "";
        $("compareSnapshotDate").value = data.latest_snapshot_date || "";
    } else {
        fillSelect($("baseSnapshotDate"), [], true, "沒有快照日期欄位");
        fillSelect($("compareSnapshotDate"), [], true, "沒有快照日期欄位");
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
    document.querySelectorAll(".structure-only").forEach(
        node => node.classList.toggle("hidden", !isStructure)
    );

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
                    `基準快照日：${data.base_snapshot_date}；比較快照日：${data.compare_snapshot_date}`
                    + `；差異＝${data.difference_definition}`;
                renderTable("comparisonYarnTable", data.yarn.columns, data.yarn.rows);
                renderTable("comparisonGreigeTable", data.greige.columns, data.greige.rows);
            }
        } else if (state.activeTab === "topn") {
            const data = await postJson("/api/dashboard/top-items", payload);
            renderTable("topnFlatTable", data.flat.columns, data.flat.rows);
            renderTable("topnKnitTable", data.knit.columns, data.knit.rows);
            $("topnNote").textContent = data.received_greige_exclusion_applied
                ? "3年以內，已排除已收胚款資料；對應 PDF 第 5 頁"
                : "3年以內；來源沒有已收胚款欄位，未套用該排除條件；對應 PDF 第 5 頁";
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
            $("responsibilityNote").textContent =
                `3年以內 Top ${payload.top_n}；對應 PDF 第 6～7 頁`;
        }
    } catch (error) {
        showError(error.message);
    } finally {
        setLoading(false);
    }
}

function clearDashboardFilters() {
    for (const select of [
        $("inventoryTypes"), $("fabricTypes"), $("elasticFlags"), $("projectFlags")
    ]) {
        select.value = "";
    }
    $("topN").value = "20";
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
    } catch (error) {
        showError(error.message);
    }
}

function detailPayload() {
    return {
        type: $("inventoryType").value,
        item_nos: selectedValues($("itemNos")),
        warehouses: selectedValues($("warehouses")),
        color_nos: selectedValues($("colorNos")),
        salespersons: selectedValues($("salespersons")),
        business_departments: selectedValues($("businessDepartments")),
        grades: selectedValues($("grades")),
        customers: selectedValues($("customers")),
        order_types: selectedValues($("orderTypes")),
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

    for (const instance of Object.values(detailSearchSelects)) {
        instance.clear();
    }

    state.detailPage = 1;
    state.detailSortField = null;
    state.detailSortDirection = "DESC";
}

async function exportDetail(path) {
    clearError();
    try {
        const payload = detailPayload();
        payload.page = 1;

        const response = await fetch(path, {
            method: "POST",
            headers: {"Content-Type": "application/json"},
            body: JSON.stringify(payload)
        });
        if (!response.ok) throw new Error(await readError(response));

        const blob = await response.blob();
        const disposition = response.headers.get("Content-Disposition") || "";
        const match = disposition.match(/filename="([^"]+)"/);
        const filename = match ? match[1] : "inventory_export";

        const url = URL.createObjectURL(blob);
        const link = document.createElement("a");
        link.href = url;
        link.download = filename;
        document.body.appendChild(link);
        link.click();
        link.remove();
        URL.revokeObjectURL(url);
    } catch (error) {
        showError(error.message);
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
    // 兩期差異後端與畫面程式保留，但目前不允許切換或執行。
    if (tabName === "comparison") {
        return;
    }

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
    () => exportDetail("/api/detail/export/xlsx")
);
$("exportCsvBtn").addEventListener(
    "click",
    () => exportDetail("/api/detail/export/csv")
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
