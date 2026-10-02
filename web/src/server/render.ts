// Рендер кадров Lottie в PNG через Skottie (canvaskit-wasm) — тот же движок Lottie, что в Chrome/Android.
// Работает без GPU и без браузера: и на Windows, и в собранном exe (wasm встроен в бинарник).
import CanvasKitInit from "canvaskit-wasm/bin/full/canvaskit.js";
import wasmPath from "canvaskit-wasm/bin/full/canvaskit.wasm" with { type: "file" };
import type { Lottie } from "../core/types.ts";

let ckPromise: Promise<any> | null = null;
function ck(): Promise<any> {
  ckPromise ??= (async () => {
    const wasmBinary = await Bun.file(wasmPath).arrayBuffer();
    return CanvasKitInit({ wasmBinary } as any);
  })();
  return ckPromise;
}

export interface Frame { png: Uint8Array; frame: number; width: number; height: number }

export function hexColor(hex?: string | null): [number, number, number] | null {
  let s = (hex ?? "").trim().replace(/^#/, "");
  if (!s || s.toLowerCase() === "transparent") return null;
  if (s.length === 3) s = s.split("").map((c) => c + c).join("");
  if (!/^[0-9a-f]{6}$/i.test(s)) return null;
  const v = parseInt(s, 16);
  return [(v >> 16) & 255, (v >> 8) & 255, v & 255];
}

/** frames — номера кадров; size — максимальная сторона в px. */
export async function renderFrames(lottie: Lottie, frames: number[], size: number, background: string | null): Promise<Frame[]> {
  const CK = await ck();
  const anim = CK.MakeManagedAnimation(JSON.stringify(lottie), {});
  if (!anim) throw new Error("Skottie could not load this Lottie");
  try {
    const [cw, ch] = anim.size();
    const scale = Math.max(8, Math.min(size, 4096)) / Math.max(cw, ch, 1);
    const w = Math.max(1, Math.round(cw * scale)), h = Math.max(1, Math.round(ch * scale));
    const surf = CK.MakeSurface(w, h);
    if (!surf) throw new Error("Cannot create render surface");
    const ip = lottie.ip ?? 0, op = lottie.op ?? 1;
    const bg = hexColor(background);
    const out: Frame[] = [];
    try {
      for (const f of frames) {
        const fr = Math.min(Math.max(f, ip), op);
        const c = surf.getCanvas();
        c.clear(bg ? CK.Color(bg[0], bg[1], bg[2], 1) : CK.TRANSPARENT);
        anim.seekFrame(fr - ip);
        anim.render(c, CK.LTRBRect(0, 0, w, h));
        surf.flush();
        const img = surf.makeImageSnapshot();
        const png = img.encodeToBytes();
        img.delete();
        if (!png) throw new Error("PNG encode failed");
        out.push({ png, frame: fr, width: w, height: h });
      }
    } finally { surf.delete(); }
    return out;
  } finally { anim.delete(); }
}
