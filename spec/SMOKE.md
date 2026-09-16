# Device smoke test — run BEFORE any merge to `main` (5 minutes, real iPad + Pencil)

The owner's non-negotiables. A build that fails any line does not merge, whatever else it improves.

1. Write a line of fast cursive at your usual zoom → sharp while writing, nothing skipped, no flicker, feel of Notes.
2. Pen-down on a page with ink → nothing already written moves or blurs.
3. Eraser (pixel + object) → gone, stays gone after 5 s. Undo brings it back.
4. Pinch in/out, scroll a few pages → ink exactly on the page after the gesture.
5. Status-bar tap, rotate, kill + relaunch → same page, all ink present.
6. Lock 🔒 → page inert; unlock → scroll works.

Record the result as a line in `spec/notes/smoke-log.md`: date · commit · pass/fail (+ which line).
