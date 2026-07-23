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
  zIndex: number;
  shape: "round" | "square" | "rectangle";
};

export type FloorObject = {
  id: string;
  type: string;
  label: string;
  x: number;
  y: number;
  width: number;
  height: number;
  rotation: number;
  zIndex: number;
  shape: "round" | "square" | "rectangle" | undefined;
  status: TableStatus;
  isTable: boolean;
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

function shapeForObject(object: JsonRecord) {
  const shape = stringValue(object.shape)?.toLowerCase() ?? stringValue(object.type)?.toLowerCase() ?? "";
  if (shape.includes("round")) return "round" as const;
  if (shape.includes("square")) return "square" as const;
  return shape.includes("rectangle") || shape.includes("rectangular") ? "rectangle" as const : undefined;
}

function labelForTable(object: JsonRecord, fallbackNumber?: number) {
  return labelValue(object.label)
    ?? labelValue(object.name)
    ?? labelValue(object.number)
    ?? labelValue(object.tableName)
    ?? labelValue(object.tableNumber)
    ?? labelValue(object.text)
    ?? (fallbackNumber ? `Table ${fallbackNumber}` : "");
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

  let tableNumber = 0;
  return layout.objects.flatMap((value) => {
    if (!isRecord(value) || !isTableObject(value)) return [];

    // Do not fall back to derived IDs: orders are keyed to this editor UUID.
    const id = stringValue(value.id);
    if (!id) return [];

    tableNumber += 1;
    return [{
      id,
      name: labelForTable(value, tableNumber),
      status: statusForTable(value),
      x: numberValue(value.x),
      y: numberValue(value.y),
      width: numberValue(value.width),
      height: numberValue(value.height),
      rotation: numberValue(value.rotation),
      zIndex: numberValue(value.zIndex) ?? numberValue(value.z_index) ?? 0,
      shape: shapeForObject(value) ?? "rectangle",
    }];
  });
}

/** Read the editor canvas without changing its schema.  Coordinates are kept in
 * the same pixel space so the orders screen can be a faithful read-only view. */
export function objectsFromFloorLayout(layout: unknown): FloorObject[] {
  if (!isRecord(layout) || !Array.isArray(layout.objects)) return [];
  return layout.objects.flatMap((value, index) => {
    if (!isRecord(value)) return [];
    const type = stringValue(value.type) ?? "label";
    const isTable = isTableObject(value);
    return [{
      id: stringValue(value.id) ?? `decoration-${index}`,
      type,
      label: isTable ? labelForTable(value) : (labelForTable(value) || type),
      x: numberValue(value.x) ?? 0,
      y: numberValue(value.y) ?? 0,
      width: numberValue(value.width) ?? (type === "wall" || type === "divider" ? 180 : 120),
      height: numberValue(value.height) ?? (type === "wall" || type === "divider" ? 10 : 80),
      rotation: numberValue(value.rotation) ?? 0,
      zIndex: numberValue(value.zIndex) ?? numberValue(value.z_index) ?? 0,
      shape: shapeForObject(value),
      status: statusForTable(value),
      isTable,
    }];
  });
}
