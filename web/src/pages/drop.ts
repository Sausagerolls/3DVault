/** A file plus its path relative to the dropped folder ("" for loose files). */
export type DroppedFile = { file: File; path: string };

/** Walk a DataTransfer, expanding dropped folders recursively. */
export async function collectDropped(dt: DataTransfer): Promise<DroppedFile[]> {
  const entries = Array.from(dt.items)
    .map((i) => i.webkitGetAsEntry?.())
    .filter((e): e is FileSystemEntry => !!e);
  if (!entries.length) return Array.from(dt.files).map((file) => ({ file, path: "" }));
  const out: DroppedFile[] = [];
  await Promise.all(entries.map((e) => walk(e, out, true)));
  return out;
}

async function walk(entry: FileSystemEntry, out: DroppedFile[], top: boolean): Promise<void> {
  if (entry.isFile) {
    const file = await new Promise<File>((res, rej) => (entry as FileSystemFileEntry).file(res, rej));
    out.push({ file, path: top ? "" : entry.fullPath.replace(/^\//, "") });
    return;
  }
  const reader = (entry as FileSystemDirectoryEntry).createReader();
  const children: FileSystemEntry[] = [];
  // readEntries returns batches of up to 100; call until empty.
  for (;;) {
    const batch = await new Promise<FileSystemEntry[]>((res, rej) => reader.readEntries(res, rej));
    if (!batch.length) break;
    children.push(...batch);
  }
  await Promise.all(children.map((c) => walk(c, out, false)));
}

export function fromInput(files: FileList | null): DroppedFile[] {
  return Array.from(files ?? []).map((file) => ({ file, path: file.webkitRelativePath || "" }));
}
