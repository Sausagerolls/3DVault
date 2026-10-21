export type User = { id: number; username: string; display_name: string; role: "admin" | "member" };
export type MyState = { favourite: boolean; rating: number | null; status: Status | null };
export type Status = "to_print" | "printed" | "failed" | "needs_remix";
export type FlagKind = "broken_mesh" | "missing_parts" | "bad_scale" | "other";

export type ModelSummary = {
  id: number;
  slug: string;
  name: string;
  category_id: number | null;
  tags: string[];
  cover_file_id: number | null;
  cover_has_preview: boolean;
  preview_file_id: number | null;
  untriaged: boolean;
  size_x: number | null;
  size_y: number | null;
  size_z: number | null;
  part_count: number;
  tri_count: number;
  flag_count: number;
  created_at: string;
  updated_at: string;
  deleted_at: string | null;
  me: MyState;
  processing: boolean;
};

export type VaultFile = {
  id: number;
  rel_path: string;
  kind: "mesh" | "cad" | "gcode" | "project" | "image" | "photo" | "doc" | "other";
  ext: string;
  size: number;
  sha256: string;
  size_x: number | null;
  size_y: number | null;
  size_z: number | null;
  tri_count: number | null;
  meta: Record<string, string | boolean>;
  has_thumb: boolean;
  has_preview: boolean;
  status: "pending" | "ready" | "error";
  error: string;
  created_at: string;
};

export type Flag = { id: number; kind: FlagKind; note: string; user_id: number | null; resolved: boolean; created_at: string };

export type ModelDetail = ModelSummary & {
  description: string;
  source_url: string;
  author: string;
  license: string;
  print_notes: string;
  printer_ids: number[];
  uploader: User | null;
  category_path: string[];
  files: VaultFile[];
  flags: Flag[];
  collection_ids: number[];
};

export type Page<T> = { items: T[]; total: number; page: number; page_size: number };
export type Category = { id: number; name: string; parent_id: number | null; count: number };
export type Tag = { id: number; name: string; count: number | null };
export type Printer = { id: number; name: string; x: number; y: number; z: number; builtin: boolean };
export type Collection = {
  id: number;
  name: string;
  kind: "manual" | "smart";
  query: Record<string, string | string[]>;
  shared: boolean;
  owner_id: number;
  count: number | null;
};
export type Rule = {
  id: number;
  name: string;
  field: "any" | "filename" | "name" | "source_url";
  pattern: string;
  add_tags: string[];
  category_id: number | null;
  enabled: boolean;
};
export type StagedFile = {
  id: string;
  path: string;
  size: number;
  sha256: string;
  kind: string;
  hint: string;
  dup_model_id: number | null;
};
export type Batch = { id: string; files: StagedFile[]; groups: { name: string; file_ids: string[] }[] };

export class ApiError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}

const BASE = "/api/v1";

export async function api<T = unknown>(path: string, init: RequestInit & { json?: unknown } = {}): Promise<T> {
  const { json, ...rest } = init;
  const headers = new Headers(rest.headers);
  if (json !== undefined) headers.set("content-type", "application/json");
  const res = await fetch(BASE + path, {
    credentials: "same-origin",
    ...rest,
    headers,
    body: json !== undefined ? JSON.stringify(json) : rest.body,
  });
  if (!res.ok) {
    let msg = res.statusText;
    try {
      const body = await res.json();
      msg = typeof body.detail === "string" ? body.detail : JSON.stringify(body.detail);
    } catch {
      /* not JSON */
    }
    if (res.status === 401 && !path.startsWith("/auth/")) window.dispatchEvent(new Event("vault:unauthorised"));
    throw new ApiError(res.status, msg);
  }
  if (res.status === 204) return undefined as T;
  return res.json();
}

/** Upload with progress. XHR because fetch has no upload progress events. */
export function uploadForm<T>(path: string, form: FormData, onProgress?: (fraction: number) => void): Promise<T> {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open("POST", BASE + path);
    xhr.withCredentials = true;
    xhr.upload.onprogress = (e) => e.lengthComputable && onProgress?.(e.loaded / e.total);
    xhr.onload = () => {
      if (xhr.status >= 200 && xhr.status < 300) resolve(JSON.parse(xhr.responseText));
      else {
        let msg = xhr.statusText;
        try {
          msg = JSON.parse(xhr.responseText).detail;
        } catch {
          /* ignore */
        }
        reject(new ApiError(xhr.status, msg));
      }
    };
    xhr.onerror = () => reject(new ApiError(0, "Network error"));
    xhr.send(form);
  });
}

export const thumbUrl = (fileId: number) => `${BASE}/files/${fileId}/thumb?v=${fileId}`;
// Bump with the server's LOD_VERSION so browsers drop cached hover previews.
const LOD_VERSION = 2;
export const previewUrl = (fileId: number, lod = false) => `${BASE}/files/${fileId}/preview${lod ? `?lod=true&v=${LOD_VERSION}` : ""}`;
export const downloadUrl = (fileId: number) => `${BASE}/files/${fileId}/download`;
export const modelZipUrl = (modelId: number) => `${BASE}/models/${modelId}/download`;

export const STATUS_LABELS: Record<Status, string> = {
  to_print: "To print",
  printed: "Printed",
  failed: "Failed",
  needs_remix: "Needs remix",
};
export const FLAG_LABELS: Record<FlagKind, string> = {
  broken_mesh: "Broken mesh",
  missing_parts: "Missing parts",
  bad_scale: "Bad scale",
  other: "Other problem",
};

export function formatBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 ** 2) return `${(n / 1024).toFixed(0)} KB`;
  if (n < 1024 ** 3) return `${(n / 1024 ** 2).toFixed(1)} MB`;
  return `${(n / 1024 ** 3).toFixed(2)} GB`;
}

export function formatDims(x: number | null, y: number | null, z: number | null): string {
  if (x == null || y == null || z == null) return "";
  return `${Math.round(x)} × ${Math.round(y)} × ${Math.round(z)} mm`;
}
