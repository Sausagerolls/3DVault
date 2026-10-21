import { memo, useRef } from "react";
import { STATUS_LABELS, formatDims, thumbUrl, type ModelSummary } from "../api";
import { useHoverStage } from "./HoverStage";
import { Icon } from "./ui";

type Props = {
  model: ModelSummary;
  selected: boolean;
  onClick: (e: React.MouseEvent, m: ModelSummary) => void;
  onToggle: (e: React.MouseEvent, m: ModelSummary) => void;
};

const statusClass: Record<string, string> = { printed: "ok", failed: "danger", to_print: "accent", needs_remix: "" };

function ModelCardInner({ model: m, selected, onClick, onToggle }: Props) {
  const thumb = useRef<HTMLDivElement>(null);
  const hover = useHoverStage();
  // Photos and source images look better cropped; renders are contained.
  const coverIsRender = m.cover_has_preview;
  return (
    <div
      className={`mcard ${selected ? "selected" : ""}`}
      onClick={(e) => onClick(e, m)}
      onMouseEnter={() => thumb.current && m.preview_file_id && hover.show(thumb.current, m.preview_file_id)}
      onMouseLeave={() => hover.hide()}
    >
      <div className="corner left">
        <span
          className="select-box"
          onClick={(e) => {
            e.stopPropagation();
            onToggle(e, m);
          }}
        >
          {selected && <Icon name="check" size={14} />}
        </span>
        {m.untriaged && !m.deleted_at && <span className="pill accent">New</span>}
      </div>
      <div className="corner right">
        {m.me.favourite && (
          <span className="pill">
            <Icon name="heart" size={11} className="fav" />
          </span>
        )}
        {m.flag_count > 0 && <span className="pill danger" title="Has problem flags">⚑ {m.flag_count}</span>}
        {m.me.status && <span className={`pill ${statusClass[m.me.status]}`}>{STATUS_LABELS[m.me.status]}</span>}
      </div>
      <div className="thumb" ref={thumb}>
        {m.cover_file_id ? (
          <img src={thumbUrl(m.cover_file_id)} alt="" loading="lazy" draggable={false} className={coverIsRender ? "" : "photo"} />
        ) : (
          <span className="placeholder">{m.processing ? "Processing…" : "No preview"}</span>
        )}
      </div>
      <div className="meta">
        <div className="name" title={m.name}>
          {m.name}
        </div>
        <div className="sub">
          <span>{m.part_count ? `${m.part_count} part${m.part_count > 1 ? "s" : ""}` : "No mesh"}</span>
          <span className="ellipsis">{formatDims(m.size_x, m.size_y, m.size_z)}</span>
          {m.me.rating ? <span style={{ color: "var(--warn)", marginLeft: "auto" }}>★{m.me.rating}</span> : null}
        </div>
      </div>
    </div>
  );
}

export const ModelCard = memo(ModelCardInner);
