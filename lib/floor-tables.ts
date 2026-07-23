export type TableStatus = "available" | "occupied" | "reserved";

export type FloorTable = {
  /** The immutable UUID assigned to the table object by the floor editor. */
  id: string;
  name: string;
  status: TableStatus;
  x: number | undefined;
  y: number | undefined;
  width: number | undefined;
  height: number | undefined;
  rotation: number | undefined;
};

type JsonRecord = Record<string, unknown>;

/** These are the exact object types written by the floor editor for tables. */
const TABLE_OBJECT_TYPES = new Set(["square-table", "round-table", "rectangle-table"]);

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

function numberValue(value: unknown) {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function isTableObject(object: JsonRecord) {
  const type = stringValue(object.type)?.toLowerCase();
  return type !== undefined && TABLE_OBJECT_TYPES.has(type);
}

function labelForTable(object: JsonRecord) {
  return labelValue(object.label)
    ?? labelValue(object.name)
    ?? labelValue(object.number)
    ?? labelValue(object.tableName)
    ?? labelValue(object.tableNumber)
    ?? "Unnamed table";
}

function statusForTable(object: JsonRecord): TableStatus {
  const status = stringValue(object.status)?.toLowerCase();
  return status === "reserved" || status === "occupied" ? status : "available";
}

/**
 * Extract table objects from the floor editor's persisted canvas document.
 * Only `layout.objects` is the editor object collection: inspecting nested
 * values can accidentally treat metadata or non-table decorations as tables.
 */
export function tablesFromFloorLayout(layout: unknown): FloorTable[] {
  if (!isRecord(layout) || !Array.isArray(layout.objects)) return [];

  return layout.objects.flatMap((value) => {
    if (!isRecord(value) || !isTableObject(value)) return [];

    // Do not fall back to derived IDs: orders are keyed to this editor UUID.
    const id = stringValue(value.id);
    if (!id) return [];

    return [{
      id,
      name: labelForTable(value),
      status: statusForTable(value),
      x: numberValue(value.x),
      y: numberValue(value.y),
      width: numberValue(value.width),
      height: numberValue(value.height),
      rotation: numberValue(value.rotation),
    }];
  });
}
