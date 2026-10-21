import { createContext, useCallback, useContext, useEffect, useRef, type ReactNode } from "react";
import { previewUrl } from "../api";
import { Viewer } from "../viewer/Viewer";

/**
 * One shared WebGL canvas that floats over whichever card is hovered and spins
 * its low-poly preview. Avoids a WebGL context per card.
 */
type Api = { show: (el: HTMLElement, fileId: number) => void; hide: () => void };
const Ctx = createContext<Api>({ show: () => {}, hide: () => {} });
export const useHoverStage = () => useContext(Ctx);

const canHover = typeof window !== "undefined" && window.matchMedia("(hover: hover)").matches;

export function HoverStageProvider({ children }: { children: ReactNode }) {
  const stage = useRef<HTMLDivElement>(null);
  const viewer = useRef<Viewer | null>(null);
  const timer = useRef<number>();
  const target = useRef<HTMLElement | null>(null);

  useEffect(() => {
    if (!canHover || !stage.current) return;
    viewer.current = new Viewer(stage.current, { autoRotate: true });
    const onScroll = () => hide();
    window.addEventListener("scroll", onScroll, true);
    return () => {
      window.removeEventListener("scroll", onScroll, true);
      viewer.current?.dispose();
      viewer.current = null;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const hide = useCallback(() => {
    window.clearTimeout(timer.current);
    target.current = null;
    stage.current?.classList.remove("on");
    viewer.current?.setAutoRotate(false);
  }, []);

  const show = useCallback((el: HTMLElement, fileId: number) => {
    if (!viewer.current || !stage.current) return;
    window.clearTimeout(timer.current);
    target.current = el;
    timer.current = window.setTimeout(async () => {
      if (target.current !== el || !stage.current || !viewer.current) return;
      const r = el.getBoundingClientRect();
      Object.assign(stage.current.style, { left: `${r.left}px`, top: `${r.top}px`, width: `${r.width}px`, height: `${r.height}px` });
      viewer.current.resize();
      try {
        viewer.current.clear();
        await viewer.current.load(previewUrl(fileId, true));
        if (target.current === el) stage.current.classList.add("on");
      } catch {
        /* no preview available: keep the static thumbnail */
      }
    }, 350);
  }, []);

  return (
    <Ctx.Provider value={{ show, hide }}>
      {children}
      {canHover && <div ref={stage} className="hover-stage" />}
    </Ctx.Provider>
  );
}
