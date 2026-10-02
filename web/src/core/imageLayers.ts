// Растровые ассеты как слои Lottie — порт `asset(...)` / `layer(...)` из LottieImageLayers.swift.
// Картинка вшивается в `assets` (base64, `e: 1`), слой `ty: 2` ссылается на неё.

export interface ImageRect { x: number; y: number; width: number; height: number }
export interface ImagePx { width: number; height: number }

function mimeType(b: Uint8Array): string {
  if (b.length >= 4 && b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47) return "image/png";
  if (b.length >= 2 && b[0] === 0xff && b[1] === 0xd8) return "image/jpeg";
  if (b.length >= 4 && b[0] === 0x52 && b[1] === 0x49 && b[2] === 0x46 && b[3] === 0x46) return "image/webp";
  return "image/png";
}

function base64(b: Uint8Array): string {
  return Buffer.from(b.buffer, b.byteOffset, b.byteLength).toString("base64");
}

export function imageAsset(id: string, image: Uint8Array, px: ImagePx): Record<string, any> {
  return { id, w: px.width, h: px.height, u: "", e: 1, p: `data:${mimeType(image)};base64,${base64(image)}` };
}

/** Якорь в центре картинки (чтобы scale/rotate крутились вокруг центра), позиция — центр rect. */
function imageTransform(px: ImagePx, rect: ImageRect): Record<string, any> {
  const sx = (rect.width / px.width) * 100, sy = (rect.height / px.height) * 100;
  return {
    o: { a: 0, k: 100, ix: 11 },
    r: { a: 0, k: 0, ix: 10 },
    p: { a: 0, k: [rect.x + rect.width / 2, rect.y + rect.height / 2, 0], ix: 2 },
    a: { a: 0, k: [px.width / 2, px.height / 2, 0], ix: 1 },
    s: { a: 0, k: [sx, sy, 100], ix: 6 },
  };
}

export function imageLayer(name: string, assetID: string, px: ImagePx, rect: ImageRect, ind: number, op: number): Record<string, any> {
  return {
    ddd: 0, ind, ty: 2, nm: name, refId: assetID, sr: 1,
    ks: imageTransform(px, rect), ao: 0, ip: 0, op, st: 0, bm: 0,
  };
}
