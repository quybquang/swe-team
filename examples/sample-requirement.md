# Sample requirement

Paste the text below into `/swe-team` to see a full pipeline run on a small feature.

---

Add a dark-mode toggle to the site header. Requirements:

- Toggle button lives in `src/components/Header.tsx`, to the right of the nav links.
- State persists in `localStorage` under the key `theme` (values: `light`, `dark`).
- Defaults to the user's `prefers-color-scheme` on first visit.
- Tailwind's `dark:` variants should activate — configure `darkMode: 'class'` and toggle the `dark` class on `<html>`.
- Add a unit test that the hook returns the persisted value on remount.
