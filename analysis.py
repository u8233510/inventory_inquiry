from __future__ import annotations

import os
import re
from datetime import date, datetime
from decimal import Decimal
from functools import lru_cache
from typing import Any

import pyodbc
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from db import get_connection

router = APIRouter()

# v13.4：分析頁籤固定使用唯一資料來源；不做自動選擇、切換或備援。
# 庫存明細查詢仍由 app.py 使用各 Type View，完全不受此設定影響。
ANALYSIS_SOURCE = "dbo.vw_InventoryInquiry_Base"

AUDIT_SOURCE_NAMES: tuple[str, ...] = (
    "dbo.InventoryInquiryActivity",
    "dbo.InventoryInquirySnapshot",
    "dbo.vw_InventoryInquiry",
    "dbo.vw_InventoryInquiry_Base",
    "dbo.vw_InventoryInquiry_Type189",
    "dbo.vw_InventoryInquiry_Type2",
    "dbo.vw_InventoryInquiry_Type3",
    "dbo.vw_InventoryInquiry_Type4",
    "dbo.vw_InventoryInquiry_TypeF",
)

FIELD_CANDIDATES: dict[str, list[str]] = {
    "snapshot_date": ["計算基準日", "快照時間", "SnapshotDate", "SnapshotTime"],
    "inbound_date": ["入庫日期", "InboundDate"],
    "batch_no": ["批號(訂單/請購單)", "批號", "LotNo", "BatchNo"],
    "inventory_type": ["類型", "類型分類", "InventoryType"],
    "fabric_type": ["胚布類型", "ta_ima20", "布種別", "FabricType"],
    # 所有 InventoryInquiry View 已正式提供中文欄位 [彈性否]；不再推測其他欄位名稱。
    "elastic_flag": ["彈性否"],
    "item_no": ["料號", "料件編號", "ItemNo"],
    "unit": ["單位", "庫存單位", "InventoryUnit"],
    "quantity": ["數量", "庫存數量", "InventoryQuantity"],
    "average_cost": ["平均成本", "AverageCost"],
    "brand": ["Final Buyer名稱", "廠牌名稱", "廠牌", "BrandName"],
    "department": [
        "庫存歸屬部門說明", "庫存歸屬部門",
        "業務部門簡稱", "業務部門", "DepartmentName",
    ],
    "grade": ["等級", "Grade", "QualityGrade"],
    "provision_rate": [
        "提列率", "呆滯比率", "備抵率", "跌價率",
        "ProvisionRate", "ObsolescenceRate",
    ],
    "book_value": ["帳面價值", "BookValue", "NetBookValue"],
    "received_greige_flag": [
        "已收胚款否", "收胚款否", "胚款已收否", "GreigePaidFlag",
    ],
}

AGE_BUCKETS: tuple[tuple[str, int], ...] = (
    ("0-30天", 1),
    ("31-90天", 2),
    ("91-180天", 3),
    ("181-365天", 4),
    ("1年-1.5年", 5),
    ("1.5年-2年", 6),
    ("2年-3年", 7),
    ("3年-5年", 8),
    ("5年以上", 9),
)

BROAD_AGE_BUCKETS: tuple[tuple[str, int], ...] = (
    ("1年以內", 1),
    ("1-2年", 2),
    ("2-3年", 3),
    ("3年以上", 4),
)


class AnalysisRequest(BaseModel):
    snapshot_date: date | None = None
    base_snapshot_date: date | None = None
    compare_snapshot_date: date | None = None

    inventory_types: list[str] = Field(default_factory=list)
    fabric_types: list[str] = Field(default_factory=list)
    elastic_flags: list[str] = Field(default_factory=list)
    project_flags: list[str] = Field(default_factory=list)

    top_n: int = 20


def qident(name: str) -> str:
    return "[" + name.replace("]", "]]" ) + "]"


def split_object_name(object_name: str) -> tuple[str, str]:
    parts = object_name.split(".", maxsplit=1)
    if len(parts) != 2:
        raise RuntimeError(f"資料來源名稱格式錯誤：{object_name}")
    return parts[0], parts[1]


def normalize(value: str) -> str:
    return re.sub(r"[\s_\-（）()\[\]【】/\\]+", "", value).casefold()


def detect_column(columns: list[str], candidates: list[str]) -> str | None:
    normalized_columns = {normalize(col): col for col in columns}
    for candidate in candidates:
        exact = normalized_columns.get(normalize(candidate))
        if exact:
            return exact

    for candidate in candidates:
        normalized_candidate = normalize(candidate)
        for column in columns:
            normalized_column = normalize(column)
            if normalized_candidate and (
                normalized_candidate in normalized_column
                or normalized_column in normalized_candidate
            ):
                return column
    return None


@lru_cache(maxsize=64)
def get_object_columns(object_name: str) -> tuple[dict[str, Any], ...]:
    schema_name, table_name = split_object_name(object_name)
    sql = """
    SELECT
        c.column_id,
        c.name AS column_name,
        t.name AS data_type,
        c.max_length,
        c.precision,
        c.scale,
        c.is_nullable,
        o.type_desc AS object_type
    FROM sys.objects AS o
    INNER JOIN sys.schemas AS s
        ON s.schema_id = o.schema_id
    INNER JOIN sys.columns AS c
        ON c.object_id = o.object_id
    INNER JOIN sys.types AS t
        ON t.user_type_id = c.user_type_id
    WHERE s.name = ?
      AND o.name = ?
      AND o.type IN (N'U', N'V')
    ORDER BY c.column_id;
    """
    with get_connection() as conn:
        rows = conn.cursor().execute(sql, schema_name, table_name).fetchall()

    if not rows:
        raise HTTPException(
            status_code=404,
            detail=f"找不到 InventoryInquiry 資料來源：{object_name}",
        )

    return tuple(
        {
            "ordinal": int(row.column_id),
            "name": str(row.column_name),
            "data_type": str(row.data_type),
            "max_length": int(row.max_length),
            "precision": int(row.precision),
            "scale": int(row.scale),
            "nullable": bool(row.is_nullable),
            "object_type": str(row.object_type),
        }
        for row in rows
    )


def resolve_mapping(object_name: str) -> dict[str, str | None]:
    columns = [item["name"] for item in get_object_columns(object_name)]
    return {
        key: detect_column(columns, candidates)
        for key, candidates in FIELD_CANDIDATES.items()
    }




def serialize_value(value: Any) -> Any:
    if value is None:
        return None
    if isinstance(value, Decimal):
        return str(value)
    if isinstance(value, datetime):
        return value.isoformat(sep=" ")
    if isinstance(value, date):
        return value.isoformat()
    if isinstance(value, bytes):
        return value.hex()
    return value


def result_from_cursor(cursor: pyodbc.Cursor) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    names = [desc[0] for desc in cursor.description]
    rows = [
        {name: serialize_value(value) for name, value in zip(names, row)}
        for row in cursor.fetchall()
    ]
    columns = [{"ordinal": index + 1, "name": name} for index, name in enumerate(names)]
    return columns, rows


def require_field(mapping: dict[str, str | None], key: str, label: str) -> str:
    column = mapping.get(key)
    if not column:
        raise HTTPException(status_code=400, detail=f"資料來源無法辨識「{label}」欄位。")
    return column


def text_value_expression(column: str) -> str:
    return f"LTRIM(RTRIM(CONVERT(nvarchar(1000), {qident(column)})))"


def inventory_type_expression(mapping: dict[str, str | None]) -> str:
    column = require_field(mapping, "inventory_type", "類型")
    value = text_value_expression(column)
    return (
        f"CASE UPPER({value}) "
        "WHEN N'2' THEN N'胚布' "
        "WHEN N'3' THEN N'紗' "
        "WHEN N'胚布' THEN N'胚布' "
        "WHEN N'紗' THEN N'紗' "
        "ELSE COALESCE(NULLIF(" + value + ", N''), N'(未提供)') END"
    )


def fabric_type_expression(mapping: dict[str, str | None]) -> str:
    column = mapping.get("fabric_type")
    if not column:
        return "N'(未提供)'"
    value = text_value_expression(column)
    return (
        f"CASE {value} "
        "WHEN N'1' THEN N'針織' "
        "WHEN N'2' THEN N'平織' "
        "WHEN N'3' THEN N'領片胚布' "
        "WHEN N'4' THEN N'不織布' "
        "WHEN N'針織' THEN N'針織' "
        "WHEN N'平織' THEN N'平織' "
        "WHEN N'--' THEN N'未分類' "
        "WHEN N'' THEN N'未分類' "
        "ELSE COALESCE(NULLIF(" + value + ", N''), N'未分類') END"
    )


def elastic_flag_expression(mapping: dict[str, str | None]) -> str:
    """直接使用 View 已轉換完成的 [彈性否]：彈性／非彈性。"""
    column = require_field(mapping, "elastic_flag", "彈性否")
    value = text_value_expression(column)
    return f"COALESCE(NULLIF({value}, N''), N'未分類')"


def project_302_expression(mapping: dict[str, str | None]) -> str:
    """依批號第 2 碼起連續 4 碼判斷 302 專案。"""
    column = require_field(mapping, "batch_no", "批號(訂單/請購單)")
    value = (
        f"LTRIM(RTRIM(CONVERT(nvarchar(4000), {qident(column)})))"
    )
    return (
        "CASE "
        f"WHEN SUBSTRING(COALESCE({value}, N''), 2, 4) "
        "IN (N'1132', N'3132') THEN N'Y' "
        "ELSE N'N' END"
    )


def generic_text_expression(
    mapping: dict[str, str | None],
    key: str,
    default_text: str = "(未提供)",
) -> str:
    column = mapping.get(key)
    if not column:
        return f"N'{default_text}'"
    return (
        f"COALESCE(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(1000), {qident(column)}))), N''), "
        f"N'{default_text}')"
    )


def quantity_expression(mapping: dict[str, str | None]) -> str:
    column = require_field(mapping, "quantity", "數量")
    return f"COALESCE(TRY_CONVERT(decimal(38,6), {qident(column)}), 0)"


def unit_expression(mapping: dict[str, str | None]) -> str:
    column = require_field(mapping, "unit", "單位")
    return (
        f"COALESCE(NULLIF(UPPER(LTRIM(RTRIM(CONVERT(nvarchar(100), {qident(column)})))), N''), "
        "N'(未提供)')"
    )


def amount_expression(mapping: dict[str, str | None]) -> str:
    quantity = quantity_expression(mapping)
    cost_column = require_field(mapping, "average_cost", "平均成本")
    average_cost = f"COALESCE(TRY_CONVERT(decimal(38,6), {qident(cost_column)}), 0)"
    return f"(({quantity}) * ({average_cost}))"


def reference_date_expression(mapping: dict[str, str | None]) -> str:
    column = mapping.get("snapshot_date")
    if column:
        return f"COALESCE(CAST({qident(column)} AS date), CAST(GETDATE() AS date))"
    return "CAST(GETDATE() AS date)"


def age_days_expression(mapping: dict[str, str | None]) -> str:
    inbound = require_field(mapping, "inbound_date", "入庫日期")
    reference = reference_date_expression(mapping)
    return (
        f"CASE WHEN {qident(inbound)} IS NULL THEN NULL "
        f"ELSE DATEDIFF(day, CAST({qident(inbound)} AS date), {reference}) END"
    )


def detailed_age_bucket_expression(mapping: dict[str, str | None]) -> str:
    days = age_days_expression(mapping)
    return (
        "CASE "
        f"WHEN {days} IS NULL THEN N'未提供' "
        f"WHEN {days} < 0 THEN N'日期異常' "
        f"WHEN {days} <= 30 THEN N'0-30天' "
        f"WHEN {days} <= 90 THEN N'31-90天' "
        f"WHEN {days} <= 180 THEN N'91-180天' "
        f"WHEN {days} <= 365 THEN N'181-365天' "
        f"WHEN {days} <= 548 THEN N'1年-1.5年' "
        f"WHEN {days} <= 730 THEN N'1.5年-2年' "
        f"WHEN {days} <= 1095 THEN N'2年-3年' "
        f"WHEN {days} <= 1825 THEN N'3年-5年' "
        "ELSE N'5年以上' END"
    )


def broad_age_bucket_expression(mapping: dict[str, str | None]) -> str:
    days = age_days_expression(mapping)
    return (
        "CASE "
        f"WHEN {days} IS NULL THEN N'未提供' "
        f"WHEN {days} < 0 THEN N'日期異常' "
        f"WHEN {days} <= 365 THEN N'1年以內' "
        f"WHEN {days} <= 730 THEN N'1-2年' "
        f"WHEN {days} <= 1095 THEN N'2-3年' "
        "ELSE N'3年以上' END"
    )


def age_sort_expression(age_bucket_sql: str) -> str:
    return (
        "CASE "
        f"WHEN {age_bucket_sql}=N'0-30天' THEN 1 "
        f"WHEN {age_bucket_sql}=N'31-90天' THEN 2 "
        f"WHEN {age_bucket_sql}=N'91-180天' THEN 3 "
        f"WHEN {age_bucket_sql}=N'181-365天' THEN 4 "
        f"WHEN {age_bucket_sql}=N'1年-1.5年' THEN 5 "
        f"WHEN {age_bucket_sql}=N'1.5年-2年' THEN 6 "
        f"WHEN {age_bucket_sql}=N'2年-3年' THEN 7 "
        f"WHEN {age_bucket_sql}=N'3年-5年' THEN 8 "
        f"WHEN {age_bucket_sql}=N'5年以上' THEN 9 "
        f"WHEN {age_bucket_sql}=N'1年以內' THEN 1 "
        f"WHEN {age_bucket_sql}=N'1-2年' THEN 2 "
        f"WHEN {age_bucket_sql}=N'2-3年' THEN 3 "
        f"WHEN {age_bucket_sql}=N'3年以上' THEN 4 "
        f"WHEN {age_bucket_sql}=N'未提供' THEN 98 "
        "ELSE 99 END"
    )


def provision_rate_expression(mapping: dict[str, str | None]) -> str:
    age_days = age_days_expression(mapping)
    grade_column = mapping.get("grade")
    grade_value = (
        f"UPPER(LTRIM(RTRIM(CONVERT(nvarchar(100), {qident(grade_column)}))))"
        if grade_column
        else "N''"
    )

    fallback = (
        "CASE "
        f"WHEN {grade_value} IN (N'C', N'C級') THEN 100.0 "
        f"WHEN {grade_value} IN (N'B', N'B級') AND {age_days} >= 366 THEN 100.0 "
        f"WHEN {age_days} > 1095 THEN 100.0 "
        f"WHEN {age_days} > 730 THEN 50.0 "
        "ELSE 0.0 END"
    )

    rate_column = mapping.get("provision_rate")
    if not rate_column:
        return fallback

    raw = f"TRY_CONVERT(decimal(19,6), {qident(rate_column)})"
    normalized = (
        "CASE "
        f"WHEN {raw} IS NULL THEN NULL "
        f"WHEN ABS({raw}) <= 1 THEN ABS({raw}) * 100.0 "
        f"ELSE ABS({raw}) END"
    )
    return (
        "CASE "
        f"WHEN {normalized} IS NULL THEN ({fallback}) "
        f"WHEN {normalized} < 0 THEN 0.0 "
        f"WHEN {normalized} > 100 THEN 100.0 "
        f"ELSE {normalized} END"
    )


def book_value_expression(mapping: dict[str, str | None]) -> str:
    book_column = mapping.get("book_value")
    if book_column:
        return f"COALESCE(TRY_CONVERT(decimal(38,6), {qident(book_column)}), 0)"
    amount = amount_expression(mapping)
    rate = provision_rate_expression(mapping)
    return f"(({amount}) * (1.0 - ({rate}) / 100.0))"


def add_raw_filter(
    where: list[str],
    params: list[Any],
    column: str | None,
    values: list[str],
) -> None:
    clean = [str(value).strip() for value in values if str(value).strip()]
    if not clean:
        return
    if not column:
        return
    placeholders = ", ".join("?" for _ in clean)
    where.append(f"CONVERT(nvarchar(4000), {qident(column)}) IN ({placeholders})")
    params.extend(clean)


def type_23_condition(mapping: dict[str, str | None]) -> str:
    column = require_field(mapping, "inventory_type", "類型")
    value = f"UPPER(LTRIM(RTRIM(CONVERT(nvarchar(100), {qident(column)}))))"
    return f"{value} IN (N'2', N'3', N'胚布', N'紗')"


def type_condition(mapping: dict[str, str | None], code: str, label: str) -> str:
    column = require_field(mapping, "inventory_type", "類型")
    value = f"UPPER(LTRIM(RTRIM(CONVERT(nvarchar(100), {qident(column)}))))"
    return f"{value} IN (N'{code}', N'{label}')"


def fabric_condition(mapping: dict[str, str | None], code: str, label: str) -> str:
    column = require_field(mapping, "fabric_type", "胚布類型")
    value = f"LTRIM(RTRIM(CONVERT(nvarchar(100), {qident(column)})))"
    return f"{value} IN (N'{code}', N'{label}')"


def build_common_filters(
    req: AnalysisRequest,
    mapping: dict[str, str | None],
    *,
    snapshot_date: date | None,
    apply_inventory_filter: bool = True,
    apply_fabric_filter: bool = True,
    apply_elastic_filter: bool = True,
    apply_project_filter: bool = True,
    restrict_to_yarn_and_greige: bool = True,
) -> tuple[list[str], list[Any]]:
    where = ["1 = 1"]
    params: list[Any] = []

    if restrict_to_yarn_and_greige:
        where.append(type_23_condition(mapping))

    snapshot_column = mapping.get("snapshot_date")
    if snapshot_date and snapshot_column:
        where.append(f"CAST({qident(snapshot_column)} AS date) = CAST(? AS date)")
        params.append(snapshot_date.isoformat())

    if apply_inventory_filter:
        add_raw_filter(
            where, params, mapping.get("inventory_type"), req.inventory_types
        )
    if apply_fabric_filter:
        add_raw_filter(where, params, mapping.get("fabric_type"), req.fabric_types)
    if apply_elastic_filter and req.elastic_flags:
        elastic_column = require_field(mapping, "elastic_flag", "彈性否")
        add_raw_filter(where, params, elastic_column, req.elastic_flags)

    if apply_project_filter:
        clean_project_flags = [
            str(value).strip().upper()
            for value in req.project_flags
            if str(value).strip().upper() in {"Y", "N"}
        ]
        if clean_project_flags:
            placeholders = ", ".join("?" for _ in clean_project_flags)
            where.append(f"({project_302_expression(mapping)}) IN ({placeholders})")
            params.extend(clean_project_flags)

    return where, params


def distinct_values(source_name: str, column: str, limit: int = 500) -> list[str]:
    sql = (
        f"SELECT DISTINCT TOP ({limit}) "
        f"LTRIM(RTRIM(CONVERT(nvarchar(4000), {qident(column)}))) AS value "
        f"FROM {source_name} "
        f"WHERE {qident(column)} IS NOT NULL "
        f"AND LTRIM(RTRIM(CONVERT(nvarchar(4000), {qident(column)}))) <> N'' "
        "ORDER BY value;"
    )
    with get_connection() as conn:
        rows = conn.cursor().execute(sql).fetchall()
    return [str(row.value).strip() for row in rows if row.value is not None]


def option_label(key: str, value: str) -> str:
    mapping = {
        "inventory_type": {
            "2": "2－胚布",
            "3": "3－紗",
            "胚布": "胚布",
            "紗": "紗",
        },
        "fabric_type": {
            "1": "1－針織",
            "2": "2－平織",
            "針織": "針織",
            "平織": "平織",
        },
        "elastic_flag": {
            "彈性": "彈性",
            "非彈性": "非彈性",
        },
    }
    return mapping.get(key, {}).get(value, value)


def option_objects(key: str, values: list[str]) -> list[dict[str, str]]:
    seen: set[str] = set()
    result: list[dict[str, str]] = []
    for value in values:
        cleaned = str(value).strip()
        if not cleaned or cleaned in seen:
            continue
        seen.add(cleaned)
        result.append({"value": cleaned, "label": option_label(key, cleaned)})
    return result


def execute_query(sql: str, params: list[Any], error_prefix: str) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    try:
        with get_connection() as conn:
            cursor = conn.cursor().execute(sql, *params)
            return result_from_cursor(cursor)
    except pyodbc.Error as exc:
        raise HTTPException(status_code=500, detail=f"{error_prefix}：{exc}") from exc


def empty_table(columns: list[str]) -> dict[str, Any]:
    return {
        "columns": [{"ordinal": index + 1, "name": name} for index, name in enumerate(columns)],
        "rows": [],
    }


@router.get("/api/source-audit")
def source_audit() -> dict[str, Any]:
    analysis_source = ANALYSIS_SOURCE
    sources: list[dict[str, Any]] = []

    for source_name in AUDIT_SOURCE_NAMES:
        try:
            metadata = get_object_columns(source_name)
            sources.append(
                {
                    "source_name": source_name,
                    "exists": True,
                    "object_type": metadata[0].get("object_type") if metadata else None,
                    "column_count": len(metadata),
                    "columns": [item["name"] for item in metadata],
                }
            )
        except HTTPException as exc:
            sources.append(
                {"source_name": source_name, "exists": False, "error": str(exc.detail)}
            )

    return {
        "analysis_source": analysis_source,
        "analysis_mapping": resolve_mapping(analysis_source),
        "elastic_field": {
            "implemented": True,
            "source": analysis_source,
            "source_column": resolve_mapping(analysis_source).get("elastic_flag"),
            "values": ["彈性", "非彈性"],
            "message": "直接使用 dbo.vw_InventoryInquiry_Base.[彈性否]，不再跨資料庫關聯 snx_ima_file。",
        },
        "project_302": {
            "implemented": True,
            "source_column": resolve_mapping(analysis_source).get("batch_no"),
            "rule": "SUBSTRING([批號(訂單/請購單)], 2, 4) IN (N'1132', N'3132')",
            "message": "批號第 2 碼起連續 4 碼為 1132 或 3132 時，302專案否＝Y；否則＝N。",
        },
        "sources": sources,
    }


@router.get("/api/dashboard/options")
def dashboard_options() -> dict[str, Any]:
    source_name = ANALYSIS_SOURCE
    mapping = resolve_mapping(source_name)
    limit = int(os.getenv("OPTION_LIMIT", "500"))

    snapshot_dates: list[str] = []
    snapshot_column = mapping.get("snapshot_date")
    if snapshot_column:
        sql = (
            f"SELECT DISTINCT TOP ({limit}) "
            f"CONVERT(char(10), CAST({qident(snapshot_column)} AS date), 23) AS snapshot_date "
            f"FROM {source_name} WHERE {qident(snapshot_column)} IS NOT NULL "
            f"ORDER BY snapshot_date DESC;"
        )
        with get_connection() as conn:
            rows = conn.cursor().execute(sql).fetchall()
        snapshot_dates = [str(row.snapshot_date) for row in rows if row.snapshot_date]

    inventory_values = (
        distinct_values(source_name, mapping["inventory_type"], limit)
        if mapping.get("inventory_type")
        else []
    )
    inventory_values = [
        value for value in inventory_values
        if value.upper() in {"2", "3", "胚布", "紗"}
    ]

    fabric_values = (
        distinct_values(source_name, mapping["fabric_type"], limit)
        if mapping.get("fabric_type")
        else []
    )
    fabric_values = [
        value for value in fabric_values
        if value in {"1", "2", "針織", "平織"}
    ]

    elastic_column = require_field(mapping, "elastic_flag", "彈性否")
    raw_elastic_values = distinct_values(source_name, elastic_column, limit)
    elastic_values = [
        value.strip()
        for value in raw_elastic_values
        if value.strip() in {"彈性", "非彈性"}
    ]
    elastic_values.sort(key=lambda value: 0 if value == "彈性" else 1)

    provision_mode = "來源欄位"
    if not mapping.get("provision_rate") and not mapping.get("book_value"):
        provision_mode = "依等級與庫齡規則推算"

    return {
        "analysis_source": source_name,
        "mapping": mapping,
        "snapshot_dates": snapshot_dates,
        "latest_snapshot_date": snapshot_dates[0] if snapshot_dates else None,
        "previous_snapshot_date": snapshot_dates[1] if len(snapshot_dates) > 1 else None,
        "snapshot_enabled": bool(snapshot_column),
        "available_filters": {
            "inventory_type": bool(mapping.get("inventory_type")),
            "fabric_type": bool(mapping.get("fabric_type")),
            "elastic_flag": True,
            "project_302": bool(mapping.get("batch_no")),
        },
        "options": {
            "inventory_type": option_objects("inventory_type", inventory_values),
            "fabric_type": option_objects("fabric_type", fabric_values),
            "elastic_flag": option_objects("elastic_flag", elastic_values),
            "project_302": [
                {"value": "Y", "label": "Y－302專案"},
                {"value": "N", "label": "N－非302專案"},
            ],
        },
        "project_302": {
            "implemented": True,
            "source_column": mapping.get("batch_no"),
            "rule": "批號第2碼起連續4碼為1132或3132",
        },
        "provision_mode": provision_mode,
    }


@router.post("/api/dashboard/aging")
def inventory_aging_analysis(req: AnalysisRequest) -> dict[str, Any]:
    source_name = ANALYSIS_SOURCE
    mapping = resolve_mapping(source_name)
    where, params = build_common_filters(
        req,
        mapping,
        snapshot_date=req.snapshot_date,
        apply_inventory_filter=True,
        apply_fabric_filter=True,
        apply_elastic_filter=True,
    )

    inventory_type = inventory_type_expression(mapping)
    fabric_type = fabric_type_expression(mapping)
    elastic_flag = elastic_flag_expression(mapping)
    project_302 = project_302_expression(mapping)
    age_bucket = detailed_age_bucket_expression(mapping)
    amount = amount_expression(mapping)

    amount_columns: list[str] = []
    total_columns: list[str] = []
    output_names: list[str] = []

    for bucket, _ in AGE_BUCKETS:
        amount_name = f"{bucket}存貨金額"
        percent_name = f"{bucket}百分比"
        output_names.extend([amount_name, percent_name])
        amount_columns.extend(
            [
                (
                    f"CAST(SUM(CASE WHEN AgeBucket=N'{bucket}' THEN Amount ELSE 0 END) "
                    f"AS decimal(38,2)) AS {qident(amount_name)}"
                ),
                (
                    "CAST(COALESCE("
                    f"SUM(CASE WHEN AgeBucket=N'{bucket}' THEN Amount ELSE 0 END) * 100.0 / "
                    f"NULLIF(MAX(CASE WHEN AgeBucket=N'{bucket}' THEN BucketTotal END), 0), 0) "
                    f"AS decimal(19,4)) AS {qident(percent_name)}"
                ),
            ]
        )
        total_columns.extend(
            [
                (
                    f"CAST(SUM(CASE WHEN AgeBucket=N'{bucket}' THEN Amount ELSE 0 END) "
                    f"AS decimal(38,2)) AS {qident(amount_name)}"
                ),
                (
                    "CAST(CASE WHEN SUM(CASE WHEN AgeBucket=N'"
                    + bucket
                    + "' THEN Amount ELSE 0 END) = 0 THEN 0 ELSE 100 END "
                    f"AS decimal(19,4)) AS {qident(percent_name)}"
                ),
            ]
        )

    select_columns = [
        "[302專案否]",
        "[類型分類]",
        "[布種別]",
        "[彈性否]",
        *[qident(name) for name in output_names],
        "[存貨金額合計]",
        "[總金額百分比]",
    ]
    metrics = ",\n            ".join(amount_columns)
    total_metrics = ",\n            ".join(total_columns)

    sql = f"""
    WITH B AS
    (
        SELECT
            {project_302} AS Project302,
            {inventory_type} AS InventoryType,
            CASE WHEN {inventory_type}=N'紗' THEN N'--' ELSE {fabric_type} END AS FabricType,
            CASE WHEN {inventory_type}=N'紗' THEN N'--' ELSE {elastic_flag} END AS ElasticFlag,
            {age_bucket} AS AgeBucket,
            {amount} AS Amount
        FROM {source_name}
        WHERE {' AND '.join(where)}
    ), G AS
    (
        SELECT
            Project302,
            InventoryType,
            FabricType,
            ElasticFlag,
            AgeBucket,
            SUM(Amount) AS Amount
        FROM B
        GROUP BY Project302, InventoryType, FabricType, ElasticFlag, AgeBucket
    ), W AS
    (
        SELECT
            G.*,
            SUM(Amount) OVER (PARTITION BY AgeBucket) AS BucketTotal,
            SUM(Amount) OVER () AS GrandTotal
        FROM G
    ), DetailRows AS
    (
        SELECT
            0 AS SortTotal,
            CASE WHEN Project302=N'Y' THEN 1 WHEN Project302=N'N' THEN 2 ELSE 9 END AS SortProject,
            CASE WHEN InventoryType=N'紗' THEN 1 WHEN InventoryType=N'胚布' THEN 2 ELSE 9 END AS SortType,
            CASE WHEN FabricType=N'--' THEN 0 WHEN FabricType=N'針織' THEN 1
                 WHEN FabricType=N'平織' THEN 2 ELSE 9 END AS SortFabric,
            0 AS SortLevel,
            Project302 AS [302專案否],
            InventoryType AS [類型分類],
            FabricType AS [布種別],
            ElasticFlag AS [彈性否],
            {metrics},
            CAST(SUM(Amount) AS decimal(38,2)) AS [存貨金額合計],
            CAST(COALESCE(SUM(Amount) * 100.0 / NULLIF(MAX(GrandTotal), 0), 0)
                 AS decimal(19,4)) AS [總金額百分比]
        FROM W
        GROUP BY Project302, InventoryType, FabricType, ElasticFlag

    ), TypeTotals AS
    (
        SELECT
            0 AS SortTotal,
            CASE WHEN Project302=N'Y' THEN 1 WHEN Project302=N'N' THEN 2 ELSE 9 END AS SortProject,
            CASE WHEN InventoryType=N'紗' THEN 1 WHEN InventoryType=N'胚布' THEN 2 ELSE 9 END AS SortType,
            99 AS SortFabric,
            2 AS SortLevel,
            Project302 AS [302專案否],
            InventoryType + N' 合計' AS [類型分類],
            N'' AS [布種別],
            N'' AS [彈性否],
            {metrics},
            CAST(SUM(Amount) AS decimal(38,2)) AS [存貨金額合計],
            CAST(COALESCE(SUM(Amount) * 100.0 / NULLIF(MAX(GrandTotal), 0), 0)
                 AS decimal(19,4)) AS [總金額百分比]
        FROM W
        GROUP BY Project302, InventoryType
    ), X AS
    (
        SELECT * FROM DetailRows
        UNION ALL
        SELECT * FROM TypeTotals
        UNION ALL
        SELECT
            1 AS SortTotal,
            99 AS SortProject,
            99 AS SortType,
            99 AS SortFabric,
            3 AS SortLevel,
            N'' AS [302專案否],
            N'總計' AS [類型分類],
            N'' AS [布種別],
            N'' AS [彈性否],
            {total_metrics},
            CAST(SUM(Amount) AS decimal(38,2)) AS [存貨金額合計],
            CAST(CASE WHEN SUM(Amount)=0 THEN 0 ELSE 100 END AS decimal(19,4)) AS [總金額百分比]
        FROM B
    )
    SELECT {', '.join(select_columns)}
    FROM X
    ORDER BY SortTotal, SortProject, SortType, SortFabric, SortLevel, [彈性否];
    """

    columns, rows = execute_query(sql, params, "庫存分析查詢失敗")
    return {
        "view_name": source_name,
        "columns": columns,
        "rows": rows,
        "project_302_implemented": True,
        "elastic_available": bool(mapping.get("elastic_flag")),
    }




@router.post("/api/dashboard/category")
def inventory_age_summary(req: AnalysisRequest) -> dict[str, Any]:
    source_name = ANALYSIS_SOURCE
    mapping = resolve_mapping(source_name)
    where, params = build_common_filters(
        req,
        mapping,
        snapshot_date=req.snapshot_date,
        apply_inventory_filter=True,
        apply_fabric_filter=True,
        apply_elastic_filter=True,
    )

    inventory_type = inventory_type_expression(mapping)
    age_bucket = broad_age_bucket_expression(mapping)
    amount = amount_expression(mapping)

    sql = f"""
    WITH B AS
    (
        SELECT
            {inventory_type} AS InventoryType,
            {age_bucket} AS AgeBucket,
            {amount} AS Amount
        FROM {source_name}
        WHERE {' AND '.join(where)}
    ), G AS
    (
        SELECT AgeBucket, InventoryType, SUM(Amount) AS Amount
        FROM B
        GROUP BY AgeBucket, InventoryType
    ), P AS
    (
        SELECT
            AgeBucket,
            MAX({age_sort_expression('AgeBucket')}) AS AgeSort,
            SUM(CASE WHEN InventoryType=N'紗' THEN Amount ELSE 0 END) AS YarnAmount,
            SUM(CASE WHEN InventoryType=N'胚布' THEN Amount ELSE 0 END) AS GreigeAmount,
            SUM(Amount) AS TotalAmount,
            SUM(SUM(CASE WHEN InventoryType=N'紗' THEN Amount ELSE 0 END)) OVER () AS YarnGrand,
            SUM(SUM(CASE WHEN InventoryType=N'胚布' THEN Amount ELSE 0 END)) OVER () AS GreigeGrand,
            SUM(SUM(Amount)) OVER () AS GrandTotal
        FROM G
        GROUP BY AgeBucket
    ), X AS
    (
        SELECT
            0 AS SortTotal,
            AgeSort,
            AgeBucket AS [庫齡區間],
            CAST(YarnAmount AS decimal(38,2)) AS [紗存貨金額],
            CAST(COALESCE(YarnAmount * 100.0 / NULLIF(YarnGrand, 0), 0)
                 AS decimal(19,4)) AS [紗占比百分比],
            CAST(GreigeAmount AS decimal(38,2)) AS [胚布存貨金額],
            CAST(COALESCE(GreigeAmount * 100.0 / NULLIF(GreigeGrand, 0), 0)
                 AS decimal(19,4)) AS [胚布占比百分比],
            CAST(TotalAmount AS decimal(38,2)) AS [合計存貨金額],
            CAST(COALESCE(TotalAmount * 100.0 / NULLIF(GrandTotal, 0), 0)
                 AS decimal(19,4)) AS [合計占比百分比]
        FROM P
        UNION ALL
        SELECT
            1,
            99,
            N'總計',
            CAST(SUM(CASE WHEN InventoryType=N'紗' THEN Amount ELSE 0 END) AS decimal(38,2)),
            CAST(CASE WHEN SUM(CASE WHEN InventoryType=N'紗' THEN Amount ELSE 0 END)=0 THEN 0 ELSE 100 END AS decimal(19,4)),
            CAST(SUM(CASE WHEN InventoryType=N'胚布' THEN Amount ELSE 0 END) AS decimal(38,2)),
            CAST(CASE WHEN SUM(CASE WHEN InventoryType=N'胚布' THEN Amount ELSE 0 END)=0 THEN 0 ELSE 100 END AS decimal(19,4)),
            CAST(SUM(Amount) AS decimal(38,2)),
            CAST(CASE WHEN SUM(Amount)=0 THEN 0 ELSE 100 END AS decimal(19,4))
        FROM B
    )
    SELECT
        [庫齡區間], [紗存貨金額], [紗占比百分比],
        [胚布存貨金額], [胚布占比百分比],
        [合計存貨金額], [合計占比百分比]
    FROM X
    ORDER BY SortTotal, AgeSort;
    """

    columns, rows = execute_query(sql, params, "庫齡結構摘要查詢失敗")
    return {"view_name": source_name, "columns": columns, "rows": rows}


def comparison_query(
    *,
    source_name: str,
    mapping: dict[str, str | None],
    req: AnalysisRequest,
    inventory_code: str,
    inventory_label: str,
    greige_mode: bool,
) -> dict[str, Any]:
    snapshot_column = mapping.get("snapshot_date")
    if not snapshot_column:
        return {
            "columns": [],
            "rows": [],
            "available": False,
            "message": "目前 InventoryInquiry 分析來源沒有快照日期欄位，無法執行兩期存貨差異。",
        }

    if not req.base_snapshot_date or not req.compare_snapshot_date:
        return {
            "columns": [],
            "rows": [],
            "available": False,
            "message": "請選擇基準快照日與比較快照日。",
        }

    if req.base_snapshot_date == req.compare_snapshot_date:
        return {
            "columns": [],
            "rows": [],
            "available": False,
            "message": "基準快照日與比較快照日必須不同。",
        }

    where, filter_params = build_common_filters(
        req,
        mapping,
        snapshot_date=None,
        apply_inventory_filter=False,
        apply_fabric_filter=False,
        apply_elastic_filter=True,
        restrict_to_yarn_and_greige=False,
    )
    where.append(type_condition(mapping, inventory_code, inventory_label))
    where.append(
        f"CAST({qident(snapshot_column)} AS date) IN (CAST(? AS date), CAST(? AS date))"
    )

    age_bucket = detailed_age_bucket_expression(mapping)
    age_sort = age_sort_expression(age_bucket)
    quantity = quantity_expression(mapping)
    unit = unit_expression(mapping)
    amount = amount_expression(mapping)
    book = book_value_expression(mapping)
    fabric = fabric_type_expression(mapping)

    if greige_mode:
        base_quantity_columns = """
            CAST(SUM(CASE WHEN PeriodCode=N'BASE' AND FabricType=N'平織' AND InventoryUnit=N'Y'
                          THEN InventoryQuantity ELSE 0 END) AS decimal(38,6)) AS [基準期平織數量(Y)],
            CAST(SUM(CASE WHEN PeriodCode=N'BASE' AND FabricType=N'針織' AND InventoryUnit=N'KG'
                          THEN InventoryQuantity ELSE 0 END) AS decimal(38,6)) AS [基準期針織數量(KG)],
        """
        compare_quantity_columns = """
            CAST(SUM(CASE WHEN PeriodCode=N'COMPARE' AND FabricType=N'平織' AND InventoryUnit=N'Y'
                          THEN InventoryQuantity ELSE 0 END) AS decimal(38,6)) AS [比較期平織數量(Y)],
            CAST(SUM(CASE WHEN PeriodCode=N'COMPARE' AND FabricType=N'針織' AND InventoryUnit=N'KG'
                          THEN InventoryQuantity ELSE 0 END) AS decimal(38,6)) AS [比較期針織數量(KG)],
        """
        difference_quantity_columns = """
            CAST(SUM(CASE WHEN PeriodCode=N'BASE' AND FabricType=N'平織' AND InventoryUnit=N'Y'
                          THEN InventoryQuantity ELSE 0 END)
               - SUM(CASE WHEN PeriodCode=N'COMPARE' AND FabricType=N'平織' AND InventoryUnit=N'Y'
                          THEN InventoryQuantity ELSE 0 END) AS decimal(38,6)) AS [差異平織數量(Y)],
            CAST(SUM(CASE WHEN PeriodCode=N'BASE' AND FabricType=N'針織' AND InventoryUnit=N'KG'
                          THEN InventoryQuantity ELSE 0 END)
               - SUM(CASE WHEN PeriodCode=N'COMPARE' AND FabricType=N'針織' AND InventoryUnit=N'KG'
                          THEN InventoryQuantity ELSE 0 END) AS decimal(38,6)) AS [差異針織數量(KG)],
        """
        quantity_total_base = """
            CAST(SUM(CASE WHEN PeriodCode=N'BASE' AND FabricType=N'平織' AND InventoryUnit=N'Y'
                          THEN InventoryQuantity ELSE 0 END) AS decimal(38,6)),
            CAST(SUM(CASE WHEN PeriodCode=N'BASE' AND FabricType=N'針織' AND InventoryUnit=N'KG'
                          THEN InventoryQuantity ELSE 0 END) AS decimal(38,6)),
        """
        quantity_total_compare = """
            CAST(SUM(CASE WHEN PeriodCode=N'COMPARE' AND FabricType=N'平織' AND InventoryUnit=N'Y'
                          THEN InventoryQuantity ELSE 0 END) AS decimal(38,6)),
            CAST(SUM(CASE WHEN PeriodCode=N'COMPARE' AND FabricType=N'針織' AND InventoryUnit=N'KG'
                          THEN InventoryQuantity ELSE 0 END) AS decimal(38,6)),
        """
        quantity_total_diff = """
            CAST(SUM(CASE WHEN PeriodCode=N'BASE' AND FabricType=N'平織' AND InventoryUnit=N'Y'
                          THEN InventoryQuantity ELSE 0 END)
               - SUM(CASE WHEN PeriodCode=N'COMPARE' AND FabricType=N'平織' AND InventoryUnit=N'Y'
                          THEN InventoryQuantity ELSE 0 END) AS decimal(38,6)),
            CAST(SUM(CASE WHEN PeriodCode=N'BASE' AND FabricType=N'針織' AND InventoryUnit=N'KG'
                          THEN InventoryQuantity ELSE 0 END)
               - SUM(CASE WHEN PeriodCode=N'COMPARE' AND FabricType=N'針織' AND InventoryUnit=N'KG'
                          THEN InventoryQuantity ELSE 0 END) AS decimal(38,6)),
        """
        select_columns = [
            "庫齡區間",
            "基準期平織數量(Y)", "基準期針織數量(KG)",
            "基準期存貨金額", "基準期金額百分比", "基準期帳面價值", "基準期提列率",
            "比較期平織數量(Y)", "比較期針織數量(KG)",
            "比較期存貨金額", "比較期金額百分比", "比較期帳面價值", "比較期提列率",
            "差異平織數量(Y)", "差異針織數量(KG)", "差異存貨金額",
        ]
    else:
        base_quantity_columns = """
            CAST(SUM(CASE WHEN PeriodCode=N'BASE' AND InventoryUnit=N'KG'
                          THEN InventoryQuantity ELSE 0 END) AS decimal(38,6)) AS [基準期存貨數量(KG)],
        """
        compare_quantity_columns = """
            CAST(SUM(CASE WHEN PeriodCode=N'COMPARE' AND InventoryUnit=N'KG'
                          THEN InventoryQuantity ELSE 0 END) AS decimal(38,6)) AS [比較期存貨數量(KG)],
        """
        difference_quantity_columns = """
            CAST(SUM(CASE WHEN PeriodCode=N'BASE' AND InventoryUnit=N'KG'
                          THEN InventoryQuantity ELSE 0 END)
               - SUM(CASE WHEN PeriodCode=N'COMPARE' AND InventoryUnit=N'KG'
                          THEN InventoryQuantity ELSE 0 END) AS decimal(38,6)) AS [差異存貨數量(KG)],
        """
        quantity_total_base = """
            CAST(SUM(CASE WHEN PeriodCode=N'BASE' AND InventoryUnit=N'KG'
                          THEN InventoryQuantity ELSE 0 END) AS decimal(38,6)),
        """
        quantity_total_compare = """
            CAST(SUM(CASE WHEN PeriodCode=N'COMPARE' AND InventoryUnit=N'KG'
                          THEN InventoryQuantity ELSE 0 END) AS decimal(38,6)),
        """
        quantity_total_diff = """
            CAST(SUM(CASE WHEN PeriodCode=N'BASE' AND InventoryUnit=N'KG'
                          THEN InventoryQuantity ELSE 0 END)
               - SUM(CASE WHEN PeriodCode=N'COMPARE' AND InventoryUnit=N'KG'
                          THEN InventoryQuantity ELSE 0 END) AS decimal(38,6)),
        """
        select_columns = [
            "庫齡區間",
            "基準期存貨數量(KG)", "基準期存貨金額", "基準期金額百分比",
            "基準期帳面價值", "基準期提列率",
            "比較期存貨數量(KG)", "比較期存貨金額", "比較期金額百分比",
            "比較期帳面價值", "比較期提列率",
            "差異存貨數量(KG)", "差異存貨金額",
        ]

    base_date = req.base_snapshot_date.isoformat()
    compare_date = req.compare_snapshot_date.isoformat()

    sql = f"""
    WITH B AS
    (
        SELECT
            CASE
                WHEN CAST({qident(snapshot_column)} AS date)=CAST(? AS date) THEN N'BASE'
                WHEN CAST({qident(snapshot_column)} AS date)=CAST(? AS date) THEN N'COMPARE'
            END AS PeriodCode,
            {age_bucket} AS AgeBucket,
            {age_sort} AS AgeSort,
            {fabric} AS FabricType,
            {unit} AS InventoryUnit,
            {quantity} AS InventoryQuantity,
            {amount} AS InventoryAmount,
            {book} AS BookValue
        FROM {source_name}
        WHERE {' AND '.join(where)}
    ), G AS
    (
        SELECT
            AgeBucket,
            MAX(AgeSort) AS AgeSort,
            PeriodCode,
            FabricType,
            InventoryUnit,
            SUM(InventoryQuantity) AS InventoryQuantity,
            SUM(InventoryAmount) AS InventoryAmount,
            SUM(BookValue) AS BookValue
        FROM B
        GROUP BY AgeBucket, PeriodCode, FabricType, InventoryUnit
    ), X AS
    (
        SELECT
            0 AS SortTotal,
            MAX(AgeSort) AS AgeSort,
            AgeBucket AS [庫齡區間],
            {base_quantity_columns}
            CAST(SUM(CASE WHEN PeriodCode=N'BASE' THEN InventoryAmount ELSE 0 END) AS decimal(38,2)) AS [基準期存貨金額],
            CAST(COALESCE(SUM(CASE WHEN PeriodCode=N'BASE' THEN InventoryAmount ELSE 0 END) * 100.0 /
                 NULLIF(SUM(SUM(CASE WHEN PeriodCode=N'BASE' THEN InventoryAmount ELSE 0 END)) OVER (), 0), 0)
                 AS decimal(19,4)) AS [基準期金額百分比],
            CAST(SUM(CASE WHEN PeriodCode=N'BASE' THEN BookValue ELSE 0 END) AS decimal(38,2)) AS [基準期帳面價值],
            CAST(COALESCE((SUM(CASE WHEN PeriodCode=N'BASE' THEN BookValue ELSE 0 END)
                 - SUM(CASE WHEN PeriodCode=N'BASE' THEN InventoryAmount ELSE 0 END)) * 100.0 /
                 NULLIF(SUM(CASE WHEN PeriodCode=N'BASE' THEN InventoryAmount ELSE 0 END), 0), 0)
                 AS decimal(19,4)) AS [基準期提列率],
            {compare_quantity_columns}
            CAST(SUM(CASE WHEN PeriodCode=N'COMPARE' THEN InventoryAmount ELSE 0 END) AS decimal(38,2)) AS [比較期存貨金額],
            CAST(COALESCE(SUM(CASE WHEN PeriodCode=N'COMPARE' THEN InventoryAmount ELSE 0 END) * 100.0 /
                 NULLIF(SUM(SUM(CASE WHEN PeriodCode=N'COMPARE' THEN InventoryAmount ELSE 0 END)) OVER (), 0), 0)
                 AS decimal(19,4)) AS [比較期金額百分比],
            CAST(SUM(CASE WHEN PeriodCode=N'COMPARE' THEN BookValue ELSE 0 END) AS decimal(38,2)) AS [比較期帳面價值],
            CAST(COALESCE((SUM(CASE WHEN PeriodCode=N'COMPARE' THEN BookValue ELSE 0 END)
                 - SUM(CASE WHEN PeriodCode=N'COMPARE' THEN InventoryAmount ELSE 0 END)) * 100.0 /
                 NULLIF(SUM(CASE WHEN PeriodCode=N'COMPARE' THEN InventoryAmount ELSE 0 END), 0), 0)
                 AS decimal(19,4)) AS [比較期提列率],
            {difference_quantity_columns}
            CAST(SUM(CASE WHEN PeriodCode=N'BASE' THEN InventoryAmount ELSE 0 END)
               - SUM(CASE WHEN PeriodCode=N'COMPARE' THEN InventoryAmount ELSE 0 END)
                 AS decimal(38,2)) AS [差異存貨金額]
        FROM G
        GROUP BY AgeBucket
        UNION ALL
        SELECT
            1,
            99,
            N'總計',
            {quantity_total_base}
            CAST(SUM(CASE WHEN PeriodCode=N'BASE' THEN InventoryAmount ELSE 0 END) AS decimal(38,2)),
            CAST(CASE WHEN SUM(CASE WHEN PeriodCode=N'BASE' THEN InventoryAmount ELSE 0 END)=0 THEN 0 ELSE 100 END AS decimal(19,4)),
            CAST(SUM(CASE WHEN PeriodCode=N'BASE' THEN BookValue ELSE 0 END) AS decimal(38,2)),
            CAST(COALESCE((SUM(CASE WHEN PeriodCode=N'BASE' THEN BookValue ELSE 0 END)
                 - SUM(CASE WHEN PeriodCode=N'BASE' THEN InventoryAmount ELSE 0 END)) * 100.0 /
                 NULLIF(SUM(CASE WHEN PeriodCode=N'BASE' THEN InventoryAmount ELSE 0 END), 0), 0)
                 AS decimal(19,4)),
            {quantity_total_compare}
            CAST(SUM(CASE WHEN PeriodCode=N'COMPARE' THEN InventoryAmount ELSE 0 END) AS decimal(38,2)),
            CAST(CASE WHEN SUM(CASE WHEN PeriodCode=N'COMPARE' THEN InventoryAmount ELSE 0 END)=0 THEN 0 ELSE 100 END AS decimal(19,4)),
            CAST(SUM(CASE WHEN PeriodCode=N'COMPARE' THEN BookValue ELSE 0 END) AS decimal(38,2)),
            CAST(COALESCE((SUM(CASE WHEN PeriodCode=N'COMPARE' THEN BookValue ELSE 0 END)
                 - SUM(CASE WHEN PeriodCode=N'COMPARE' THEN InventoryAmount ELSE 0 END)) * 100.0 /
                 NULLIF(SUM(CASE WHEN PeriodCode=N'COMPARE' THEN InventoryAmount ELSE 0 END), 0), 0)
                 AS decimal(19,4)),
            {quantity_total_diff}
            CAST(SUM(CASE WHEN PeriodCode=N'BASE' THEN InventoryAmount ELSE 0 END)
               - SUM(CASE WHEN PeriodCode=N'COMPARE' THEN InventoryAmount ELSE 0 END)
                 AS decimal(38,2))
        FROM G
    )
    SELECT {', '.join(qident(column) for column in select_columns)}
    FROM X
    ORDER BY SortTotal, AgeSort;
    """

    params = [base_date, compare_date, *filter_params, base_date, compare_date]
    columns, rows = execute_query(sql, params, f"{inventory_label}兩期存貨差異查詢失敗")
    return {"columns": columns, "rows": rows, "available": True}


@router.post("/api/dashboard/period-comparison")
def period_comparison(req: AnalysisRequest) -> dict[str, Any]:
    source_name = ANALYSIS_SOURCE
    mapping = resolve_mapping(source_name)

    yarn = comparison_query(
        source_name=source_name,
        mapping=mapping,
        req=req,
        inventory_code="3",
        inventory_label="紗",
        greige_mode=False,
    )
    greige = comparison_query(
        source_name=source_name,
        mapping=mapping,
        req=req,
        inventory_code="2",
        inventory_label="胚布",
        greige_mode=True,
    )

    available = bool(yarn.get("available") and greige.get("available"))
    message = yarn.get("message") or greige.get("message") or ""
    return {
        "view_name": source_name,
        "available": available,
        "message": message,
        "base_snapshot_date": req.base_snapshot_date.isoformat() if req.base_snapshot_date else None,
        "compare_snapshot_date": req.compare_snapshot_date.isoformat() if req.compare_snapshot_date else None,
        "difference_definition": "基準期－比較期",
        "yarn": yarn,
        "greige": greige,
    }


def received_greige_exclusion(mapping: dict[str, str | None]) -> str | None:
    column = mapping.get("received_greige_flag")
    if not column:
        return None
    value = f"UPPER(LTRIM(RTRIM(CONVERT(nvarchar(100), {qident(column)}))))"
    return f"COALESCE(NULLIF({value}, N''), N'N') NOT IN (N'Y', N'1', N'是')"


def top_items_for_fabric(
    *,
    source_name: str,
    mapping: dict[str, str | None],
    req: AnalysisRequest,
    fabric_code: str,
    fabric_label: str,
    required_unit: str,
) -> dict[str, Any]:
    if req.top_n < 1 or req.top_n > 100:
        raise HTTPException(status_code=400, detail="Top N 必須介於 1 與 100。")

    where, params = build_common_filters(
        req,
        mapping,
        snapshot_date=req.snapshot_date,
        apply_inventory_filter=False,
        apply_fabric_filter=False,
        apply_elastic_filter=True,
        restrict_to_yarn_and_greige=False,
    )
    where.append(type_condition(mapping, "2", "胚布"))
    where.append(fabric_condition(mapping, fabric_code, fabric_label))
    where.append(f"({age_days_expression(mapping)}) BETWEEN 0 AND 1095")
    where.append(f"{unit_expression(mapping)} = N'{required_unit}'")
    exclusion = received_greige_exclusion(mapping)
    if exclusion:
        where.append(exclusion)

    item_column = require_field(mapping, "item_no", "料號")
    item_expr = (
        f"COALESCE(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(400), {qident(item_column)}))), N''), "
        "N'(未提供)')"
    )
    unit = unit_expression(mapping)
    quantity = quantity_expression(mapping)
    amount = amount_expression(mapping)
    book = book_value_expression(mapping)

    sql = f"""
    WITH G AS
    (
        SELECT
            {item_expr} AS ItemNo,
            {unit} AS InventoryUnit,
            SUM({quantity}) AS InventoryQuantity,
            SUM({amount}) AS InventoryAmount,
            SUM({book}) AS BookValue
        FROM {source_name}
        WHERE {' AND '.join(where)}
        GROUP BY {item_expr}, {unit}
    ), R AS
    (
        SELECT
            ROW_NUMBER() OVER (ORDER BY InventoryQuantity DESC, ItemNo) AS RankNo,
            *,
            SUM(InventoryQuantity) OVER () AS TotalQuantity,
            SUM(InventoryAmount) OVER () AS TotalAmount,
            SUM(BookValue) OVER () AS TotalBookValue
        FROM G
    )
    SELECT TOP ({req.top_n})
        RankNo,
        ItemNo,
        InventoryUnit,
        InventoryQuantity,
        InventoryAmount,
        BookValue,
        TotalQuantity,
        TotalAmount,
        TotalBookValue
    FROM R
    ORDER BY RankNo;
    """

    _, raw_rows = execute_query(sql, params, f"{fabric_label}庫存前 N 大查詢失敗")

    columns = [
        "排行", "料件編號", "庫存單位", "庫存數量", "數量百分比",
        "存貨金額", "金額百分比", "帳面價值", "提列率",
    ]
    result_rows: list[dict[str, Any]] = []

    if not raw_rows:
        return {
            "fabric_type": fabric_label,
            "required_unit": required_unit,
            "columns": [{"ordinal": index + 1, "name": name} for index, name in enumerate(columns)],
            "rows": [],
        }

    total_quantity = Decimal(str(raw_rows[0].get("TotalQuantity") or "0"))
    total_amount = Decimal(str(raw_rows[0].get("TotalAmount") or "0"))
    total_book = Decimal(str(raw_rows[0].get("TotalBookValue") or "0"))
    top_quantity = Decimal("0")
    top_amount = Decimal("0")
    top_book = Decimal("0")

    def percent(numerator: Decimal, denominator: Decimal) -> Decimal:
        if denominator == 0:
            return Decimal("0")
        return numerator * Decimal("100") / denominator

    def provision_percent(amount_value: Decimal, book_value: Decimal) -> Decimal:
        if amount_value == 0:
            return Decimal("0")
        return (book_value - amount_value) * Decimal("100") / amount_value

    for row in raw_rows:
        quantity_value = Decimal(str(row.get("InventoryQuantity") or "0"))
        amount_value = Decimal(str(row.get("InventoryAmount") or "0"))
        book_value = Decimal(str(row.get("BookValue") or "0"))
        top_quantity += quantity_value
        top_amount += amount_value
        top_book += book_value
        result_rows.append(
            {
                "排行": row.get("RankNo"),
                "料件編號": row.get("ItemNo"),
                "庫存單位": row.get("InventoryUnit"),
                "庫存數量": serialize_value(quantity_value),
                "數量百分比": serialize_value(percent(quantity_value, total_quantity)),
                "存貨金額": serialize_value(amount_value),
                "金額百分比": serialize_value(percent(amount_value, total_amount)),
                "帳面價值": serialize_value(book_value),
                "提列率": serialize_value(provision_percent(amount_value, book_value)),
            }
        )

    other_quantity = total_quantity - top_quantity
    other_amount = total_amount - top_amount
    other_book = total_book - top_book

    summary_rows = [
        (
            f"前{req.top_n}大數量小計",
            top_quantity,
            top_amount,
            top_book,
        ),
        ("其他", other_quantity, other_amount, other_book),
        ("總計", total_quantity, total_amount, total_book),
    ]

    for label, quantity_value, amount_value, book_value in summary_rows:
        result_rows.append(
            {
                "排行": "",
                "料件編號": label,
                "庫存單位": required_unit,
                "庫存數量": serialize_value(quantity_value),
                "數量百分比": serialize_value(percent(quantity_value, total_quantity)),
                "存貨金額": serialize_value(amount_value),
                "金額百分比": serialize_value(percent(amount_value, total_amount)),
                "帳面價值": serialize_value(book_value),
                "提列率": serialize_value(provision_percent(amount_value, book_value)),
            }
        )

    return {
        "fabric_type": fabric_label,
        "required_unit": required_unit,
        "columns": [{"ordinal": index + 1, "name": name} for index, name in enumerate(columns)],
        "rows": result_rows,
    }


@router.post("/api/dashboard/top-items")
def top_items(req: AnalysisRequest) -> dict[str, Any]:
    source_name = ANALYSIS_SOURCE
    mapping = resolve_mapping(source_name)
    flat = top_items_for_fabric(
        source_name=source_name,
        mapping=mapping,
        req=req,
        fabric_code="2",
        fabric_label="平織",
        required_unit="Y",
    )
    knit = top_items_for_fabric(
        source_name=source_name,
        mapping=mapping,
        req=req,
        fabric_code="1",
        fabric_label="針織",
        required_unit="KG",
    )
    return {
        "view_name": source_name,
        "within_three_years": True,
        "received_greige_exclusion_applied": bool(mapping.get("received_greige_flag")),
        "flat": flat,
        "knit": knit,
    }


def responsibility_for_fabric(
    *,
    source_name: str,
    mapping: dict[str, str | None],
    req: AnalysisRequest,
    fabric_code: str,
    fabric_label: str,
    required_unit: str,
) -> dict[str, Any]:
    if req.top_n < 1 or req.top_n > 100:
        raise HTTPException(status_code=400, detail="Top N 必須介於 1 與 100。")

    where, params = build_common_filters(
        req,
        mapping,
        snapshot_date=req.snapshot_date,
        apply_inventory_filter=False,
        apply_fabric_filter=False,
        apply_elastic_filter=True,
        restrict_to_yarn_and_greige=False,
    )
    where.append(type_condition(mapping, "2", "胚布"))
    where.append(fabric_condition(mapping, fabric_code, fabric_label))
    where.append(f"({age_days_expression(mapping)}) BETWEEN 0 AND 1095")
    where.append(f"{unit_expression(mapping)} = N'{required_unit}'")
    exclusion = received_greige_exclusion(mapping)
    if exclusion:
        where.append(exclusion)

    item_column = require_field(mapping, "item_no", "料號")
    item_expr = (
        f"COALESCE(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(400), {qident(item_column)}))), N''), "
        "N'(未提供)')"
    )
    unit = unit_expression(mapping)
    age_bucket = detailed_age_bucket_expression(mapping)
    age_sort = age_sort_expression(age_bucket)
    brand = generic_text_expression(mapping, "brand")
    department = generic_text_expression(mapping, "department")
    quantity = quantity_expression(mapping)
    amount = amount_expression(mapping)
    book = book_value_expression(mapping)

    sql = f"""
    WITH B AS
    (
        SELECT
            {item_expr} AS ItemNo,
            {unit} AS InventoryUnit,
            {age_bucket} AS AgeBucket,
            {age_sort} AS AgeSort,
            {brand} AS BrandName,
            {department} AS DepartmentName,
            {quantity} AS InventoryQuantity,
            {amount} AS InventoryAmount,
            {book} AS BookValue
        FROM {source_name}
        WHERE {' AND '.join(where)}
    ), ItemG AS
    (
        SELECT ItemNo, SUM(InventoryQuantity) AS ItemQuantity
        FROM B
        GROUP BY ItemNo
    ), R AS
    (
        SELECT
            ROW_NUMBER() OVER (ORDER BY ItemQuantity DESC, ItemNo) AS RankNo,
            ItemNo
        FROM ItemG
    ), Totals AS
    (
        SELECT
            SUM(InventoryQuantity) AS TotalQuantity,
            SUM(InventoryAmount) AS TotalAmount
        FROM B
    ), D AS
    (
        SELECT
            R.RankNo,
            B.ItemNo,
            B.InventoryUnit,
            B.AgeBucket,
            MAX(B.AgeSort) AS AgeSort,
            B.BrandName,
            B.DepartmentName,
            SUM(B.InventoryQuantity) AS InventoryQuantity,
            SUM(B.InventoryAmount) AS InventoryAmount,
            SUM(B.BookValue) AS BookValue
        FROM B
        INNER JOIN R ON R.ItemNo = B.ItemNo
        WHERE R.RankNo <= ?
        GROUP BY R.RankNo, B.ItemNo, B.InventoryUnit,
                 B.AgeBucket, B.BrandName, B.DepartmentName
    )
    SELECT
        D.RankNo AS [排行],
        D.ItemNo AS [料件編號],
        D.InventoryUnit AS [庫存單位],
        CAST(D.InventoryQuantity AS decimal(38,6)) AS [庫存數量],
        CAST(COALESCE(D.InventoryQuantity * 100.0 / NULLIF(T.TotalQuantity, 0), 0)
             AS decimal(19,4)) AS [數量百分比],
        CAST(D.InventoryAmount AS decimal(38,2)) AS [存貨金額],
        CAST(COALESCE(D.InventoryAmount * 100.0 / NULLIF(T.TotalAmount, 0), 0)
             AS decimal(19,4)) AS [金額百分比],
        CAST(D.BookValue AS decimal(38,2)) AS [帳面價值],
        CAST(COALESCE((D.BookValue - D.InventoryAmount) * 100.0 /
             NULLIF(D.InventoryAmount, 0), 0) AS decimal(19,4)) AS [提列率],
        D.AgeBucket AS [庫齡區間],
        D.BrandName AS [品牌商簡稱],
        D.DepartmentName AS [歸屬部門簡稱]
    FROM D
    CROSS JOIN Totals AS T
    ORDER BY D.RankNo, D.ItemNo, D.AgeSort, D.BrandName, D.DepartmentName;
    """

    columns, rows = execute_query(
        sql,
        [*params, req.top_n],
        f"{fabric_label}責任歸屬與庫齡分析查詢失敗",
    )
    return {
        "fabric_type": fabric_label,
        "required_unit": required_unit,
        "columns": columns,
        "rows": rows,
    }


@router.post("/api/dashboard/responsibility")
def responsibility(req: AnalysisRequest) -> dict[str, Any]:
    source_name = ANALYSIS_SOURCE
    mapping = resolve_mapping(source_name)
    flat = responsibility_for_fabric(
        source_name=source_name,
        mapping=mapping,
        req=req,
        fabric_code="2",
        fabric_label="平織",
        required_unit="Y",
    )
    knit = responsibility_for_fabric(
        source_name=source_name,
        mapping=mapping,
        req=req,
        fabric_code="1",
        fabric_label="針織",
        required_unit="KG",
    )
    return {
        "view_name": source_name,
        "within_three_years": True,
        "received_greige_exclusion_applied": bool(mapping.get("received_greige_flag")),
        "flat": flat,
        "knit": knit,
    }
