#!/usr/bin/env node

const fs = require('node:fs');
const path = require('node:path');
const ort = require('onnxruntime-node');
const jpeg = require('jpeg-js');
const { PNG } = require('pngjs');

const MODEL_SIZE = 1024;

function parseArgs(argv) {
  const args = new Map();
  for (let index = 2; index < argv.length; index += 2) {
    const key = argv[index];
    const value = argv[index + 1];
    if (!key || !key.startsWith('--') || value === undefined) {
      throw new Error('Expected --flag value pairs');
    }
    args.set(key.slice(2), value);
  }

  const model = args.get('model');
  const input = args.get('input');
  const output = args.get('output');
  if (!model || !input || !output) {
    throw new Error('Usage: remove_bg.cjs --model <path> --input <path> --output <path> [--roi x,y,w,h]');
  }

  return {
    model,
    input,
    output,
    roi: args.get('roi') || null,
  };
}

function emitStatus(phase, message) {
  process.stdout.write(`${JSON.stringify({ event: 'status', phase, message })}\n`);
}

function emitFinished(payload) {
  process.stdout.write(`${JSON.stringify({ event: 'finished', payload })}\n`);
}

function decodeImage(filePath) {
  const extension = path.extname(filePath).toLowerCase();
  const data = fs.readFileSync(filePath);

  if (extension === '.png') {
    const image = PNG.sync.read(data);
    return {
      width: image.width,
      height: image.height,
      data: new Uint8ClampedArray(image.data),
    };
  }

  if (extension === '.jpg' || extension === '.jpeg') {
    const image = jpeg.decode(data, { useTArray: true });
    return {
      width: image.width,
      height: image.height,
      data: new Uint8ClampedArray(image.data),
    };
  }

  throw new Error(`Unsupported input format: ${extension || 'unknown'}`);
}

function encodePng(image, outputPath) {
  const png = new PNG({ width: image.width, height: image.height });
  png.data = Buffer.from(image.data);
  fs.writeFileSync(outputPath, PNG.sync.write(png));
}

function clamp(value, min, max) {
  return Math.max(min, Math.min(max, value));
}

function parseRoi(rawRoi, image) {
  if (!rawRoi) {
    return null;
  }

  const parts = rawRoi.split(',').map((part) => Number.parseInt(part, 10));
  if (parts.length !== 4 || parts.some((part) => !Number.isFinite(part))) {
    throw new Error(`Invalid ROI: ${rawRoi}`);
  }

  const [x, y, width, height] = parts;
  const clampedX = clamp(x, 0, image.width - 1);
  const clampedY = clamp(y, 0, image.height - 1);
  const clampedWidth = clamp(width, 1, image.width - clampedX);
  const clampedHeight = clamp(height, 1, image.height - clampedY);

  return {
    x: clampedX,
    y: clampedY,
    width: clampedWidth,
    height: clampedHeight,
  };
}

function cropImage(image, roi) {
  const cropped = new Uint8ClampedArray(roi.width * roi.height * 4);
  for (let row = 0; row < roi.height; row += 1) {
    const srcStart = ((roi.y + row) * image.width + roi.x) * 4;
    const srcEnd = srcStart + roi.width * 4;
    const destStart = row * roi.width * 4;
    cropped.set(image.data.subarray(srcStart, srcEnd), destStart);
  }

  return {
    width: roi.width,
    height: roi.height,
    data: cropped,
  };
}

function resizeRgbaBilinear(image, targetWidth, targetHeight) {
  const output = new Uint8ClampedArray(targetWidth * targetHeight * 4);
  const xScale = image.width / targetWidth;
  const yScale = image.height / targetHeight;

  for (let y = 0; y < targetHeight; y += 1) {
    const srcY = (y + 0.5) * yScale - 0.5;
    const y0 = clamp(Math.floor(srcY), 0, image.height - 1);
    const y1 = clamp(y0 + 1, 0, image.height - 1);
    const yWeight = srcY - y0;

    for (let x = 0; x < targetWidth; x += 1) {
      const srcX = (x + 0.5) * xScale - 0.5;
      const x0 = clamp(Math.floor(srcX), 0, image.width - 1);
      const x1 = clamp(x0 + 1, 0, image.width - 1);
      const xWeight = srcX - x0;
      const outIndex = (y * targetWidth + x) * 4;

      for (let channel = 0; channel < 4; channel += 1) {
        const topLeft = image.data[(y0 * image.width + x0) * 4 + channel];
        const topRight = image.data[(y0 * image.width + x1) * 4 + channel];
        const bottomLeft = image.data[(y1 * image.width + x0) * 4 + channel];
        const bottomRight = image.data[(y1 * image.width + x1) * 4 + channel];
        const top = topLeft + (topRight - topLeft) * xWeight;
        const bottom = bottomLeft + (bottomRight - bottomLeft) * xWeight;
        output[outIndex + channel] = Math.round(top + (bottom - top) * yWeight);
      }
    }
  }

  return {
    width: targetWidth,
    height: targetHeight,
    data: output,
  };
}

function resizeMaskBilinear(mask, sourceWidth, sourceHeight, targetWidth, targetHeight) {
  const output = new Uint8ClampedArray(targetWidth * targetHeight);
  const xScale = sourceWidth / targetWidth;
  const yScale = sourceHeight / targetHeight;

  for (let y = 0; y < targetHeight; y += 1) {
    const srcY = (y + 0.5) * yScale - 0.5;
    const y0 = clamp(Math.floor(srcY), 0, sourceHeight - 1);
    const y1 = clamp(y0 + 1, 0, sourceHeight - 1);
    const yWeight = srcY - y0;

    for (let x = 0; x < targetWidth; x += 1) {
      const srcX = (x + 0.5) * xScale - 0.5;
      const x0 = clamp(Math.floor(srcX), 0, sourceWidth - 1);
      const x1 = clamp(x0 + 1, 0, sourceWidth - 1);
      const xWeight = srcX - x0;

      const topLeft = mask[y0 * sourceWidth + x0];
      const topRight = mask[y0 * sourceWidth + x1];
      const bottomLeft = mask[y1 * sourceWidth + x0];
      const bottomRight = mask[y1 * sourceWidth + x1];
      const top = topLeft + (topRight - topLeft) * xWeight;
      const bottom = bottomLeft + (bottomRight - bottomLeft) * xWeight;
      output[y * targetWidth + x] = Math.round(top + (bottom - top) * yWeight);
    }
  }

  return output;
}

function rgbaToModelInput(image) {
  const area = image.width * image.height;
  const tensor = new Float32Array(area * 3);

  for (let index = 0; index < area; index += 1) {
    const srcIndex = index * 4;
    tensor[index] = image.data[srcIndex] / 255.0 - 0.5;
    tensor[area + index] = image.data[srcIndex + 1] / 255.0 - 0.5;
    tensor[area * 2 + index] = image.data[srcIndex + 2] / 255.0 - 0.5;
  }

  return tensor;
}

function normalizeMask(rawMask) {
  let min = Number.POSITIVE_INFINITY;
  let max = Number.NEGATIVE_INFINITY;

  for (let index = 0; index < rawMask.length; index += 1) {
    const value = rawMask[index];
    if (value < min) {
      min = value;
    }
    if (value > max) {
      max = value;
    }
  }

  const range = max - min;
  if (!Number.isFinite(range) || range <= 1e-8) {
    return new Uint8ClampedArray(rawMask.length).fill(255);
  }

  const normalized = new Uint8ClampedArray(rawMask.length);
  for (let index = 0; index < rawMask.length; index += 1) {
    normalized[index] = clamp(Math.round(((rawMask[index] - min) / range) * 255), 0, 255);
  }

  return normalized;
}

function flattenOutput(outputTensor) {
  const dims = outputTensor.dims || [];
  const data = outputTensor.data;
  if (!Array.isArray(dims) || dims.length < 2) {
    throw new Error(`Unexpected output dims: ${JSON.stringify(dims)}`);
  }

  const height = dims[dims.length - 2];
  const width = dims[dims.length - 1];
  return {
    width,
    height,
    data,
  };
}

function applyMask(originalImage, mask, roi) {
  const output = new Uint8ClampedArray(originalImage.data);
  const alpha = new Uint8ClampedArray(originalImage.width * originalImage.height);

  if (roi) {
    for (let row = 0; row < roi.height; row += 1) {
      const srcOffset = row * roi.width;
      const destOffset = (roi.y + row) * originalImage.width + roi.x;
      alpha.set(mask.subarray(srcOffset, srcOffset + roi.width), destOffset);
    }
  } else {
    alpha.set(mask);
  }

  for (let index = 0; index < alpha.length; index += 1) {
    output[index * 4 + 3] = alpha[index];
  }

  return {
    width: originalImage.width,
    height: originalImage.height,
    data: output,
  };
}

async function main() {
  const options = parseArgs(process.argv);
  emitStatus('loading', 'Loading image');
  const originalImage = decodeImage(options.input);
  const roi = parseRoi(options.roi, originalImage);
  const workingImage = roi ? cropImage(originalImage, roi) : originalImage;

  emitStatus('loading', 'Loading RMBG-1.4 model');
  const session = await ort.InferenceSession.create(options.model, {
    executionProviders: ['cpu'],
    graphOptimizationLevel: 'all',
  });

  emitStatus('segmenting', 'Running background removal');
  const resized = resizeRgbaBilinear(workingImage, MODEL_SIZE, MODEL_SIZE);
  const inputName = session.inputNames[0];
  const outputName = session.outputNames[0];
  const feeds = {
    [inputName]: new ort.Tensor('float32', rgbaToModelInput(resized), [1, 3, MODEL_SIZE, MODEL_SIZE]),
  };
  const outputs = await session.run(feeds);
  const modelOutput = flattenOutput(outputs[outputName]);
  const normalizedMask = normalizeMask(modelOutput.data);

  emitStatus('saving', 'Writing transparent PNG');
  const resizedMask = resizeMaskBilinear(
    normalizedMask,
    modelOutput.width,
    modelOutput.height,
    workingImage.width,
    workingImage.height,
  );
  const composited = applyMask(originalImage, resizedMask, roi);

  fs.mkdirSync(path.dirname(options.output), { recursive: true });
  encodePng(composited, options.output);

  emitFinished({
    success: true,
    output_path: options.output,
    output_bytes: fs.statSync(options.output).size,
  });
}

main().catch((error) => {
  emitFinished({
    success: false,
    error: error instanceof Error ? error.message : String(error),
  });
  process.exitCode = 1;
});
