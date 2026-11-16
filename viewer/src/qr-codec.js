import { BrowserQRCodeReader, BrowserQRCodeSvgWriter } from '@zxing/browser';
import { DecodeHintType, EncodeHintType } from '@zxing/library';

class PairingCodeReader extends BrowserQRCodeReader {
  constructor() {
    super();
    this.aligned = new BrowserQRCodeReader(new Map([[DecodeHintType.PURE_BARCODE, true]]));
  }
  decodeBitmap(bitmap) {
    try { return super.decodeBitmap(bitmap); }
    catch (error) {
      // Some valid, straight-on codes confuse ZXing's finder-pattern detector.
      // Retain its perspective-aware scan first, then try the aligned QR path.
      try { return this.aligned.decodeBitmap(bitmap); }
      catch { throw error; }
    }
  }
}

export const createReader = () => new PairingCodeReader();
export const createCode = text => new BrowserQRCodeSvgWriter().write(text, 256, 256,
  new Map([[EncodeHintType.ERROR_CORRECTION, 'Q']]));
