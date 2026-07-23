export type TableStatus = "available" | "occupied" | "reserved";

export type FloorTable = {
  id: string;
  name: string;
  status: TableStatus;
};

type JsonRecord = Record<string, unknown>;

const TABLE_SHAPES = new Set(["round", "square", "rectangle", "rectangular"]);
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function isRecord(value: unknown): value is JsonRecord {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function stringValue(value: unknown) {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

function labelValue(value: unknown) {
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  return stringValue(value);
}

function tableId(object: JsonRecord) {
  const id = stringValue(object.uuid) ?? stringValue(object.id) ?? stringValue(object.objectId);
  return id && UUID_PATTERN.test(id) ? id : undefined;
}

/**
 * Floor plans are saved as a canvas JSON document.  The editor has used both
 * `type: "table"` plus a shape and shape-specific type values over time, so
 * recognize the persisted table variants without changing the stored layout.
 */
function isTableObject(object: JsonRecord) {
  const type = [object.type, object.objectType, object.kind, object.tableType, object.tableShape]
    .map(stringValue)
    .filter((value): value is string => Boolean(value))
    .join(" ")
    .toLowerCase();
  const shape = stringValue(object.shape)?.toLowerCase();
  const hasTableLabel = [object.name, object.tableName, object.tableNumber, object.label].some(labelValue);

  return type.includes("table")
    || (shape !== undefined && (TABLE_SHAPES.has(shape) || shape.includes("table")) && hasTableLabel);
}

function labelForTable(object: JsonRecord, index: number) {
  return labelValue(object.name)
    ?? labelValue(object.tableName)
    ?? labelValue(object.tableNumber)
    ?? labelValue(object.label)
    ?? `Table ${index + 1}`;
}

function statusForTable(object: JsonRecord): TableStatus {
  const status = stringValue(object.status)?.toLowerCase();
  return status === "reserved" || status === "occupied" ? status : "available";
}

/** Extract table canvas objects while retaining their editor-generated UUID. */
export function tablesFromFloorLayout(layout: unknown): FloorTable[] {
  const tables: FloorTable[] = [];
  const seenIds = new Set<string>();

  function visit(value: unknown) {
    if (Array.isArray(value)) {
      value.forEach(visit);
      return;
    }
    if (!isRecord(value)) return;

    const id = tableId(value);
    if (id && isTableObject(value) && !seenIds.has(id)) {
      seenIds.add(id);
      tables.push({ id, name: labelForTable(value, tables.length), status: statusForTable(value) });
    }
    Object.values(value).forEach(visit);
  }

  visit(layout);
  return tables;
}
