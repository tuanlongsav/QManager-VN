const MAX_AVATAR_FILE_BYTES = 500_000;
const AVATAR_MAX_DIMENSION = 128;

/**
 * Resize an image file to a small data URL suitable for localStorage.
 * Returns null if the file is too large or cannot be decoded.
 */
export function fileToAvatarDataUrl(file: File): Promise<string | null> {
  if (!file.type.startsWith("image/")) {
    return Promise.resolve(null);
  }
  if (file.size > MAX_AVATAR_FILE_BYTES) {
    return Promise.resolve(null);
  }

  return new Promise((resolve) => {
    const url = URL.createObjectURL(file);
    const img = new Image();

    img.onload = () => {
      URL.revokeObjectURL(url);
      const scale = Math.min(
        1,
        AVATAR_MAX_DIMENSION / Math.max(img.width, img.height),
      );
      const width = Math.max(1, Math.round(img.width * scale));
      const height = Math.max(1, Math.round(img.height * scale));

      const canvas = document.createElement("canvas");
      canvas.width = width;
      canvas.height = height;
      const ctx = canvas.getContext("2d");
      if (!ctx) {
        resolve(null);
        return;
      }
      ctx.drawImage(img, 0, 0, width, height);
      resolve(canvas.toDataURL("image/jpeg", 0.85));
    };

    img.onerror = () => {
      URL.revokeObjectURL(url);
      resolve(null);
    };

    img.src = url;
  });
}
