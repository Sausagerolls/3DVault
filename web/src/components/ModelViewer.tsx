import { useEffect, useRef, useState } from "react";
import { previewUrl, thumbUrl, formatDims, type VaultFile } from "../api";
import { Viewer } from "../viewer/Viewer";
import { Icon } from "./ui";

/** Full interactive viewer for a mesh/CAD file, or a still image for anything else. */
export function ModelViewer({ file }: { file: VaultFile | null }) {
  const box = useRef<HTMLDivElement>(null);
  const viewer = useRef<Viewer | null>(null);
  const [wire, setWire] = useState(false);
  const [state, setState] = useState<"idle" | "loading" | "ready" | "error">("idle");
  const is3d = !!file?.has_preview;

  useEffect(() => {
    if (!is3d || !box.current) return;
    const v = new Viewer(box.current, { interactive: true, showBed: true });
    viewer.current = v;
    return () => {
      v.dispose();
      viewer.current = null;
    };
  }, [is3d]);

  useEffect(() => {
    if (!file?.has_preview || !viewer.current) return;
    setState("loading");
    viewer.current
      .load(previewUrl(file.id))
      .then(() => setState("ready"))
      .catch(() => setState("error"));
  }, [file?.id, file?.has_preview]);

  useEffect(() => viewer.current?.setWireframe(wire), [wire]);

  return (
    <div className="viewer-box" ref={box}>
      {!is3d && file?.has_thumb && <img className="still" src={thumbUrl(file.id)} alt="" />}
      {!is3d && !file?.has_thumb && (
        <div className="empty" style={{ height: "100%", display: "flex", alignItems: "center", justifyContent: "center" }}>
          {file?.status === "pending" ? "Generating preview…" : "No preview available"}
        </div>
      )}
      {is3d && (
        <>
          <div className="viewer-tools">
            <button className={`small ${wire ? "active" : ""}`} onClick={() => setWire(!wire)} title="Wireframe">
              <Icon name="wire" size={14} />
            </button>
            <button className="small" onClick={() => viewer.current?.frameModel()} title="Reset view">
              <Icon name="refresh" size={14} />
            </button>
          </div>
          <div className="viewer-info">
            {state === "loading" && "Loading…"}
            {state === "error" && "Could not load preview"}
            {state === "ready" && (
              <>
                {formatDims(file!.size_x, file!.size_y, file!.size_z)}
                {file!.tri_count ? ` · ${file!.tri_count.toLocaleString()} triangles` : ""}
              </>
            )}
          </div>
        </>
      )}
    </div>
  );
}
