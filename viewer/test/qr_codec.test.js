import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { BrowserQRCodeReader, BrowserQRCodeSvgWriter } from '@zxing/browser';
import { BinaryBitmap, HybridBinarizer, RGBLuminanceSource } from '@zxing/library';
import { createCode, createReader } from '../src/qr-codec.js';

// Render the actual SVG writer's rectangles into luminance pixels without a
// browser. Browser integration separately rasterizes the displayed SVG/video.
function withSvgDocument(work) {
  const previous = global.document;
  global.document = { createElementNS: () => ({ attributes: {}, children: [],
    setAttribute(key, value) { this.attributes[key] = value; }, appendChild(child) { this.children.push(child); } }) };
  try { return work(); }
  finally { if (previous === undefined) delete global.document; else global.document = previous; }
}
function bitmap(svg) {
  const width = Number(svg.attributes.width), height = Number(svg.attributes.height);
  const pixels = new Uint8ClampedArray(width * height).fill(255);
  for (const { attributes: rect } of svg.children) {
    assert.equal(rect.fill, '#000000');
    const x = Number(rect.x), y = Number(rect.y), w = Number(rect.width), h = Number(rect.height);
    for (let row = y; row < y + h; row++) pixels.fill(0, row * width + x, row * width + x + w);
  }
  return new BinaryBitmap(new HybridBinarizer(new RGBLuminanceSource(pixels, width, height)));
}
const link = secret => `http://127.0.0.1:4175/#pair=room_b_0123456789.${secret}`;

test('the reader accepts a valid legacy QR that confuses the normal finder detector', () => withSvgDocument(() => {
  const value = link('C'.repeat(43)), image = bitmap(new BrowserQRCodeSvgWriter().write(value, 256, 256));
  assert.throws(() => new BrowserQRCodeReader().decodeBitmap(image));
  assert.equal(createReader().decodeBitmap(image).getText(), value);
}));
test('actual generated QR pixels preserve varied room links and realistic secrets', () => withSvgDocument(() => {
  for (let i = 0; i < 100; i++) {
    const secret = createHash('sha256').update(`Home Listen synthetic pairing ${i}`).digest('base64url');
    const value = `https://homelisten.example/#pair=room_${String(i).padStart(12, '0')}.${secret}`;
    assert.equal(createReader().decodeBitmap(bitmap(createCode(value))).getText(), value);
  }
}));
test('an empty camera frame remains undecodable', () => {
  const image = new BinaryBitmap(new HybridBinarizer(new RGBLuminanceSource(new Uint8ClampedArray(256 * 256).fill(255), 256, 256)));
  assert.throws(() => createReader().decodeBitmap(image));
});
