import { useEffect, useRef, useState } from 'react';
import { invoke } from '@tauri-apps/api/core';
import type { PunchCropTransform } from '../features/app/types';
import { isTauriRuntime, mimeTypeForPath, toAssetUrl } from '../features/app/utils';

type PunchEffectCanvasProps = {
  inputPath: string;
  cropTransform?: PunchCropTransform;
  onComplete: () => void;
};

type SampleRect = {
  x: number;
  y: number;
  width: number;
  height: number;
};

function resolveSampleRect(
  imageWidth: number,
  imageHeight: number,
  cropTransform?: PunchCropTransform,
): SampleRect {
  if (!cropTransform) {
    return {
      x: 0,
      y: 0,
      width: Math.max(1, imageWidth),
      height: Math.max(1, imageHeight),
    };
  }

  const width = Math.min(Math.max(1, cropTransform.width), Math.max(1, imageWidth));
  const height = Math.min(Math.max(1, cropTransform.height), Math.max(1, imageHeight));
  const maxX = Math.max(0, imageWidth - width);
  const maxY = Math.max(0, imageHeight - height);

  if (cropTransform.x != null && cropTransform.y != null) {
    return {
      x: Math.min(Math.max(0, cropTransform.x), maxX),
      y: Math.min(Math.max(0, cropTransform.y), maxY),
      width,
      height,
    };
  }

  switch (cropTransform.anchor) {
    case 'top_left':
      return { x: 0, y: 0, width, height };
    case 'top_right':
      return { x: maxX, y: 0, width, height };
    case 'bottom_left':
      return { x: 0, y: maxY, width, height };
    case 'bottom_right':
      return { x: maxX, y: maxY, width, height };
    case 'center':
    default:
      return { x: Math.floor(maxX / 2), y: Math.floor(maxY / 2), width, height };
  }
}

export function PunchEffectCanvas({ inputPath, cropTransform, onComplete }: PunchEffectCanvasProps) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const [resolvedSrc, setResolvedSrc] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    let blobURL: string | null = null;

    // eslint-disable-next-line react-hooks/set-state-in-effect
    setResolvedSrc(null);

    const resolveSource = async () => {
      const fallback = toAssetUrl(inputPath);

      if (isTauriRuntime()) {
        try {
          const bytes = await invoke<number[]>('read_image_bytes', { path: inputPath });
          if (Array.isArray(bytes) && bytes.length > 0) {
            const blob = new Blob([new Uint8Array(bytes)], { type: mimeTypeForPath(inputPath) });
            blobURL = URL.createObjectURL(blob);
            if (!cancelled) {
              setResolvedSrc(blobURL);
            }
            return;
          }
        } catch {
          // fallback below
        }
      }

      if (!cancelled) {
        setResolvedSrc(fallback || '');
      }
    };

    void resolveSource();

    return () => {
      cancelled = true;
      if (blobURL) {
        URL.revokeObjectURL(blobURL);
      }
    };
  }, [inputPath]);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas || resolvedSrc == null) {
      return;
    }

    const ctx = canvas.getContext('2d', { willReadFrequently: true });
    if (!ctx) {
      return;
    }

    const targetImg = new Image();

    const fistImg = new Image();
    fistImg.src = '/fist.png';
    let fistLoaded = false;
    fistImg.onload = () => {
      fistLoaded = true;
    };

    type Block = { x: number; y: number; w: number; h: number; color: string };
    type Particle = { x: number; y: number; vx: number; vy: number; size: number; color: string };

    let animationId = 0;
    let startTime = 0;
    let particles: Particle[] = [];
    let phase = 0;
    let completed = false;

    const cornerBlocks: Block[] = [];
    const bodyBlocks: Block[] = [];

    const offscreen = document.createElement('canvas');
    const offCtx = offscreen.getContext('2d', { willReadFrequently: true });

    let started = false;

    const startAnimation = (hasSourceImage: boolean) => {
      if (started) {
        return;
      }
      started = true;

      const cw = canvas.width;
      const ch = canvas.height;

      const maxImageSize = 160;
      const sampleRect = hasSourceImage && targetImg.naturalWidth > 0 && targetImg.naturalHeight > 0
        ? resolveSampleRect(targetImg.naturalWidth, targetImg.naturalHeight, cropTransform)
        : { x: 0, y: 0, width: 1, height: 1 };

      const ratio = hasSourceImage
        ? sampleRect.width / sampleRect.height
        : 1;

      const imgW = ratio >= 1 ? maxImageSize : maxImageSize * ratio;
      const imgH = ratio >= 1 ? maxImageSize / ratio : maxImageSize;
      const imgX = (cw - imgW) * 0.5;
      const imgY = 58 + (160 - imgH) * 0.5;
      const floorY = ch - 15;

      const blockSize = 8;
      const cols = Math.max(1, Math.ceil(imgW / blockSize));
      const rows = Math.max(1, Math.ceil(imgH / blockSize));

      cornerBlocks.length = 0;
      bodyBlocks.length = 0;
      particles = [];
      phase = 0;

      const samplingCanvas = document.createElement('canvas');
      const samplingCtx = samplingCanvas.getContext('2d', { willReadFrequently: true });
      samplingCanvas.width = Math.max(1, Math.round(imgW));
      samplingCanvas.height = Math.max(1, Math.round(imgH));

      if (samplingCtx && hasSourceImage) {
        samplingCtx.clearRect(0, 0, samplingCanvas.width, samplingCanvas.height);
        samplingCtx.drawImage(
          targetImg,
          sampleRect.x,
          sampleRect.y,
          sampleRect.width,
          sampleRect.height,
          0,
          0,
          samplingCanvas.width,
          samplingCanvas.height,
        );
      }

      const sampleColor = (block: Block): string => {
        if (!samplingCtx) {
          return 'rgba(59,130,246,1)';
        }

        const px = Math.min(
          samplingCanvas.width - 1,
          Math.max(0, Math.floor(block.x + block.w * 0.5)),
        );
        const py = Math.min(
          samplingCanvas.height - 1,
          Math.max(0, Math.floor(block.y + block.h * 0.5)),
        );
        const data = samplingCtx.getImageData(px, py, 1, 1).data;
        return `rgba(${data[0]}, ${data[1]}, ${data[2]}, ${data[3] / 255})`;
      };

      for (let row = 0; row < rows; row += 1) {
        for (let col = 0; col < cols; col += 1) {
          const x = col * blockSize;
          const y = row * blockSize;
          const w = Math.min(blockSize, imgW - x);
          const h = Math.min(blockSize, imgH - y);
          if (w <= 0 || h <= 0) {
            continue;
          }

          const block: Block = {
            x,
            y,
            w,
            h,
            color: 'rgba(59,130,246,1)',
          };
          block.color = sampleColor(block);

          const noise = Math.random() * 4 - 2;
          if (row + col + noise > rows + cols - 13) {
            cornerBlocks.push(block);
          } else {
            bodyBlocks.push(block);
          }
        }
      }

      const draw = (timestamp: number) => {
        if (!startTime) {
          startTime = timestamp;
        }

        const elapsed = timestamp - startTime;

        if (elapsed >= 4000) {
          if (!completed) {
            completed = true;
            onComplete();
          }
          return;
        }

        const localElapsed = elapsed;

        ctx.clearRect(0, 0, cw, ch);

        if (localElapsed > 3500) {
          ctx.globalAlpha = Math.max(0, 1 - (localElapsed - 3500) / 500);
        } else {
          ctx.globalAlpha = 1;
        }

        let shakeX = 0;
        let shakeY = 0;
        if ((localElapsed > 1000 && localElapsed < 1150) || (localElapsed > 2200 && localElapsed < 2300)) {
          shakeX = (Math.random() - 0.5) * 10;
          shakeY = (Math.random() - 0.5) * 10;
        }

        ctx.save();
        ctx.translate(shakeX, shakeY);

        if (localElapsed < 1000) {
          const holdMs = 180;
          let pixelSize = 1;

          if (localElapsed > holdMs) {
            const progress = Math.min(1, Math.max(0, (localElapsed - holdMs) / (1000 - holdMs)));
            const eased = Math.pow(progress, 1.2);
            pixelSize = 1 + eased * 7;
          }

          const scaledW = Math.max(1, Math.floor(imgW / pixelSize));
          const scaledH = Math.max(1, Math.floor(imgH / pixelSize));

          if (offCtx) {
            offscreen.width = scaledW;
            offscreen.height = scaledH;
            offCtx.clearRect(0, 0, scaledW, scaledH);
            if (hasSourceImage) {
              offCtx.drawImage(
                targetImg,
                sampleRect.x,
                sampleRect.y,
                sampleRect.width,
                sampleRect.height,
                0,
                0,
                scaledW,
                scaledH,
              );

              ctx.imageSmoothingEnabled = false;
              ctx.drawImage(offscreen, 0, 0, scaledW, scaledH, imgX, imgY, imgW, imgH);
            } else {
              bodyBlocks.forEach((block) => {
                ctx.fillStyle = block.color;
                ctx.fillRect(imgX + block.x, imgY + block.y, block.w, block.h);
              });
            }
          }
        } else if (localElapsed < 2200) {
          bodyBlocks.forEach((block) => {
            ctx.fillStyle = block.color;
            ctx.fillRect(imgX + block.x, imgY + block.y, block.w, block.h);
          });
        }

        const fistScale = 1.45;
        const fistW = Math.round(100 * fistScale);
        const fistH = Math.round(140 * fistScale);
        const fistX = (cw - fistW) * 0.5;
        const targetFistY = Math.max(-20, imgY - fistH * 0.55);

        let fistY = -fistH;
        if (localElapsed > 600 && localElapsed <= 1000) {
          const p = (localElapsed - 600) / 400;
          fistY = -fistH + (targetFistY + fistH) * (p * p * p);
        } else if (localElapsed > 1000 && localElapsed <= 1600) {
          fistY = targetFistY;
        } else if (localElapsed > 1600 && localElapsed <= 2200) {
          const p = (localElapsed - 1600) / 600;
          fistY = targetFistY - (targetFistY + fistH) * (p * p);
        }

        if (localElapsed > 600 && localElapsed <= 2200) {
          if (fistLoaded) {
            ctx.drawImage(fistImg, fistX, fistY, fistW, fistH);
          } else {
            ctx.fillStyle = '#fca5a5';
            ctx.fillRect(fistX, fistY, fistW, fistH);
          }
        }

        ctx.restore();

        if (localElapsed >= 1000 && phase === 0) {
          phase = 1;
          cornerBlocks.forEach((block) => {
            particles.push({
              x: imgX + block.x,
              y: imgY + block.y,
              vx: Math.random() * 6 + 1,
              vy: Math.random() * 4 - 2,
              size: Math.min(block.w, block.h),
              color: block.color,
            });
          });
        }

        if (localElapsed >= 2200 && phase === 1) {
          phase = 2;
          bodyBlocks.forEach((block) => {
            particles.push({
              x: imgX + block.x,
              y: imgY + block.y,
              vx: (Math.random() - 0.5) * 8,
              vy: (Math.random() - 0.5) * 4 - 2,
              size: Math.min(block.w, block.h),
              color: block.color,
            });
          });
        }

        particles.forEach((particle) => {
          particle.vy += 0.8;
          particle.x += particle.vx;
          particle.y += particle.vy;

          if (particle.y > floorY - particle.size) {
            particle.y = floorY - particle.size;
            particle.vy *= -0.3;
            particle.vx *= 0.7;
          }

          ctx.fillStyle = particle.color;
          ctx.fillRect(particle.x, particle.y, particle.size, particle.size);
        });

        animationId = window.requestAnimationFrame(draw);
      };

      animationId = window.requestAnimationFrame(draw);
    };

    targetImg.onload = () => {
      startAnimation(true);
    };

    targetImg.onerror = () => {
      startAnimation(false);
    };

    if (resolvedSrc !== '') {
      targetImg.src = resolvedSrc;
    } else {
      startAnimation(false);
    }

    return () => {
      if (animationId) {
        window.cancelAnimationFrame(animationId);
      }
    };
  }, [cropTransform, onComplete, resolvedSrc]);

  return <canvas ref={canvasRef} width={320} height={420} className="h-[280px] w-auto object-contain drop-shadow-2xl" />;
}
