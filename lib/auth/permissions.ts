export const roles = ["admin", "manager", "worker"] as const;
export type Role = (typeof roles)[number];

// Keep this list aligned with the permissions seeded by the database migrations.
export const permissions = ["staff:read", "staff:manage", "settings:manage", "pos:use", "products:manage", "inventory:manage"] as const;
export type Permission = (typeof permissions)[number];

const rolePermissions: Record<Role, readonly Permission[]> = {
  admin: permissions,
  manager: ["staff:read", "pos:use", "products:manage", "inventory:manage"],
  worker: ["pos:use"]
};

export function hasPermission(role: Role, permission: Permission): boolean {
  return rolePermissions[role].includes(permission);
}

export function hasAnyPermission(role: Role, requiredPermissions: readonly Permission[]): boolean {
  return requiredPermissions.some((permission) => hasPermission(role, permission));
}
