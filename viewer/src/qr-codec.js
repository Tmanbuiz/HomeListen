import { BrowserQRCodeReader, BrowserQRCodeSvgWriter } from '@zxing/browser';

export const createReader = () => new BrowserQRCodeReader();
export const createCode = text => new BrowserQRCodeSvgWriter().write(text, 256, 256);
