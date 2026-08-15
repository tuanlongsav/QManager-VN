const MAX_AVATAR_FILE_BYTES = 500_000;
const AVATAR_MAX_DIMENSION = 128;

/**
 * NOTE ON STORAGE: there is deliberately none in this file, and that is the
 * whole audit result — the module only turns a File into a data URL. Persisting
 * the result is the caller's job (components/nav-user.tsx keeps it under
 * `qm_display_avatar`), and any caller doing so must go through
 * lib/browser-storage.ts: a 128px JPEG data URL is roughly 4-8 KB, which is
 * small but not free, and `localStorage.setItem` throws QuotaExceededError once
 * an origin's quota is full. An avatar is a decoration; it must never be the
 * reason a page fails to render.
 *
 * What CAN fail in here is the canvas, and it is guarded below for the same
 * class of reason: browser privacy features (Firefox's resistFingerprinting,
 * Brave's farbling, some enterprise policies) intercept `toDataURL`, and while
 * most of them return a blank or noised image, some throw outright. The failure
 * has to arrive as `null` — the documented "cannot be decoded" answer — rather
 * than as an exception out of an onload handler, where nothing is left to catch
 * it and the rejection is unhandled.
 */

/**
 * Resize an image file to a small data URL suitable for persisting.
 *
 * Never rejects. Resolves `null` for anything that did not work out: a
 * non-image, a file over MAX_AVATAR_FILE_BYTES, an undecodable image, or a
 * canvas the browser would not let us read back.
 */
export function fileToAvatarDataUrl(file: File): Promise<string | null> {
  if (!file.type.startsWith("image/")) {
    return Promise.resolve(null);
  }
  if (file.size > MAX_AVATAR_FILE_BYTES) {
    return Promise.resolve(null);
  }

  return new Promise((resolve) => {
    let url: string;
    try {
      url = URL.createObjectURL(file);
    } catch {
      // A File whose backing blob the browser has already released (the user
      // ejected the SD card the picker read from, say) throws here rather than
      // failing to load later.
      resolve(null);
      return;
    }

    const img = new Image();

    img.onload = () => {
      URL.revokeObjectURL(url);
      const scale = Math.min(
        1,
        AVATAR_MAX_DIMENSION / Math.max(img.width, img.height),
      );
      const width = Math.max(1, Math.round(img.width * scale));
      const height = Math.max(1, Math.round(img.height * scale));

      try {
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
      } catch {
        // See the note at the top of the file: toDataURL is the realistic
        // thrower. This handler runs off the event loop with no caller on the
        // stack, so an escaping exception would be an unhandled rejection and
        // the promise would never settle — the upload UI would sit on its
        // spinner forever.
        resolve(null);
      }
    };

    img.onerror = () => {
      URL.revokeObjectURL(url);
      resolve(null);
    };

    img.src = url;
  });
}
