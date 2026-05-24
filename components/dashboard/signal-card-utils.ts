import type { Variants } from "motion/react";

/** Stagger container for signal metric rows (0.04s between children) */
export const listVariants: Variants = {
  hidden: {},
  visible: { transition: { staggerChildren: 0.04 } },
};

/** Fade-up entrance for individual metric rows */
export const rowVariants: Variants = {
  hidden: { opacity: 0, y: 5 },
  visible: { opacity: 1, y: 0 },
};

/** Maps a signal quality level to a Tailwind text-color class */
export function getValueColorClass(quality: string): string {
  switch (quality) {
    case "excellent":
    case "good":
      return "text-success";
    case "fair":
      return "text-warning";
    case "poor":
      return "text-destructive";
    default:
      return "";
  }
}

/**
 * Maps a signal quality level to a short human-readable label. User-facing
 * label "Best" is preferred over "Excellent" — shorter, fits inline with
 * the metric value in narrow card layouts.
 */
export function getQualityLabel(quality: string): string {
  switch (quality) {
    case "excellent":
      return "Best";
    case "good":
      return "Good";
    case "fair":
      return "Fair";
    case "poor":
      return "Poor";
    default:
      return "";
  }
}
