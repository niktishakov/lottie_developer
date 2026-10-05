import { test } from "node:test";
import assert from "node:assert/strict";
import { CHUNK, requestFrames, ResponseAssembler, toB64, fromB64 } from "../src/protocol.ts";

test("base64 round trip", () => {
  const b = new Uint8Array(70_000).map((_, i) => (i * 7) % 256);
  assert.deepEqual(fromB64(toB64(b)), b);
});

test("small body is one frame", () => {
  const f = requestFrames("1", "POST", "/mcp", "", { a: "b" }, new Uint8Array([1, 2, 3])).map((s) => JSON.parse(s));
  assert.equal(f.length, 1);
  assert.equal(f[0].t, "req");
  assert.equal(f[0].more, false);
});

test("large body splits and reassembles", () => {
  const body = new Uint8Array(CHUNK * 2 + 10).map((_, i) => i % 251);
  const frames = requestFrames("x", "PUT", "/api/upload", "name=a.zip", {}, body).map((s) => JSON.parse(s));
  assert.equal(frames.length, 3);
  assert.deepEqual(frames.map((f) => f.t), ["req", "req-body", "req-body"]);
  assert.deepEqual(frames.map((f) => f.more), [true, true, false]);
  // Ответ собирается из тех же кусков.
  const asm = new ResponseAssembler();
  frames.forEach((f, i) => asm.add(i === 0 ? { t: "res", id: "x", status: 200, headers: {}, body: f.body, more: f.more } : { ...f, t: "res-body" }));
  assert.equal(asm.done, true);
  assert.deepEqual(asm.body(), body);
});
