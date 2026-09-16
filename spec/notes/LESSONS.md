# Lessons from the first two days (2026-09-15/16) — what worked, what didn't

Written for the next Claude (or human) picking this up after context is compacted. Chronological where it matters, otherwise grouped.

## The arc in one paragraph
Day 1: spec written first, then WP0–WP7 implemented by Sonnet agents under Fable's review, all accepted on the simulator by the evening (browser, PDFKit reader, per-document position, PencilKit ink, lock, glass bar). Day 2: Apple membership came back; first iPad install; real use exposed that ink was blurry *while writing* at the owner's zoom. Five attempts (S1–S5); the fifth — moving the canvas out from under PDFKit's zoom transform — solved it. `main` = `stable-drawing-v1`.

---

## What worked (keep doing)

### Process
- **Spec before code, with explicit non-goals and "five things you may not change."** Cheaper agents implemented seven packages without once breaking the core invariants (pencilOnly, sidecar, content-hash identity, restore-before-observe, scrollsToTop). The spec was the guardrail, not the reviewer.
- **Orchestrator reviews code, not reports.** Every agent report was checked by rebuilding and reading the actual diff. This caught: an ineffective crisp-zoom "verification" (S1 logged bounds before PDFKit reset them), a Y-flip in a transform, a hit-test guess that swallowed all fingers.
- **Owner tests on real hardware, by numbered list, short answers.** The most valuable findings of the whole project ("blurry while writing at MY zoom", "palm pans, not stray ink", "Preview's ink is a low-res bitmap") came from the owner using it, not from test plans. Ask for numbered results; explain jargon when asked ("ink glued to the page" needed a plain-language rewrite).
- **Log a finding in the spec/notes BEFORE fixing it.** Every device bug got a line with symptom → cause → fix. That's why S3's failure and S5b's wrong maths won't be retried blindly.
- **Experiments on branches, `main` only via a smoke test on the iPad.** After S3 broke writing, the owner asked for "the most stable version we don't lose" → `stable-drawing-v1` tag + `SMOKE.md`. Should have existed from the first device install.
- **Spec-level decisions kept small and explicit:** continuous scroll vs paged, lock = fingers do nothing, auto-reopen last doc, ✎ = palette only + debug-only ink-off. Each was a one-line decision the owner could overrule; several were.
- **Honest verdicts beat comfortable ones.** Owner's "no, still blurry" / "the writing layer is crap" / "ink moves in the wrong direction" each saved a day of iterating on a dead end. Ask for the honest answer and act on it the same turn.
- **Memory + CLAUDE.md** so a fresh session doesn't re-derive any of this.

### Technical
- PDFKit + PencilKit + sidecar `PKDrawing` files: fast, file never touched, ink fidelity kept. Preview's alternative (write annotations into the PDF) rasterises the strokes — their notes are blurry at any zoom; ours aren't.
- Content-hash document identity survived rename/move on device; restore-before-observe made "remember my page" reliable, including the status-bar tap that started the whole project.
- Resize handled as a *settling window* (re-pin on every PDFKit signal, suppress saves until quiet) — a one-shot re-pin was not enough because PDFKit lays out asynchronously.
- Glass bar via `contentInsetAdjustmentBehavior = .always` + `setContentScrollView` — PDFKit respected it first try.
- `InteractionLock` (disable every recogniser under PDFView except inside the canvas) — deterministic, no hit-test tricks, works on device.
- **S5 architecture** (see `CLAUDE.md`): one screen-scale canvas inside PDFKit's scroll view as a sibling of the zoomed document view; page-space storage projected per frame; contentOffset mirrored synchronously; widths scaled by zoom. Crisp at any zoom with PencilKit's unmodified latency, and navigation stays PDFKit-native because fingers reach the scroll view's recognisers as ancestors.

---

## What didn't work (don't repeat)

### Technical dead ends — all tried on device
| Attempt | Idea | Why it failed |
|---|---|---|
| A (WP6) | `contentScaleFactor` on the canvas + subviews | PencilKit ignores external contents-scale hints. Apple forum thread confirms. |
| S1 | PencilKit's own `zoomScale` + `1/z` counter-transform on the per-page overlay canvas | Fought UIScrollView/PDFKit internals; readjusted during pinch; drifted off the page after repeated zooms. Also the spike's own log "verified" geometry before PDFKit re-set the frame. |
| S2 | Crisp bitmap (`PKDrawing.image(from:scale:)`) for settled ink, live canvas shown only while drawing | Great on the simulator; on device every pen-down swapped layers on different sub-pixel grids → 1–2 px shift + blur-on-press; eraser ghost. And it never touched the *live* stroke, which was the real complaint. |
| S3 | Stroke-only live canvas (settled ink always bitmap) | Eraser broke, strokes joined by lines, blurry under the pen. Same root cause: the live canvas was still under the zoom transform. |
| S4 | Re-render the bitmap continuously while drawing | PencilKit doesn't expose the in-progress stroke until pen-up. Would also bypass the low-latency pipeline. |
| S5 v1 | Sibling canvas with pencil/finger decided in `hitTest` | `event.allTouches` is nil during hit-testing for new touches → all fingers swallowed, navigation dead. |
| S5 v1 | Y-flipped page transform (`scale(s,-s)`) | Crash on first sync (debug assertion). Sidecar/page space is already y-down. |
| S5 v2 | Re-assign `canvas.drawing` after each commit; commit at pen-up | Cancelled the next stroke when writing fast; eraser's async commit made the fallback re-sync stale state. |
| FR-32 | Two-finger-only pan for palm safety | Owner: "navigation broken, no need to touch, I'll lock the screen." Reverted; deferred until writing is settled. Lesson: don't bundle a UX change into a rendering fix. |
| S5b | Mirror the live zoom on the canvas during pinch | Ink moved the wrong direction — anchor/position maths wrong; approach still plausible. Parked. |

### Process misses
- **Testing on the simulator gave false confidence twice.** S2 was "perfect" on the simulator and broke on the device (Retina, real Pencil, real zoom). Rule now: ink changes are judged only on the iPad.
- **Agents' self-verification can be wrong in ways that look rigorous.** S1's log lines and S5's "verified numerically" both measured the wrong thing. Read the code path, not the numbers.
- **Chained shell commands hid a failure**: `grep -E "error|BUILD"` "succeeded" on a failed build and the chain committed and installed a stale binary. Gate on `BUILD SUCCEEDED` explicitly (now done everywhere).
- **A python patch with an ambiguous anchor duplicated half a file.** Anchor on unique strings, search after the start index, assert.
- **Agent scope creep into the wrong package:** WP3's agent got its files swept into an unrelated spec commit; S3's files were swept into a spec commit made while the agent ran. Don't `git add -A` while an agent is working in the tree.
- **An agent looped on simulator verification the owner didn't need** ("wasting tokens"). Simulator steps are now optional in prompts; the owner tests on device.
- **The stable tag came late.** Should be created the moment the owner first says "this is good" on device.
- **I over-promised cadence once** ("both on your iPad within the hour") — S5 took several rounds. State expectations as "next build when it passes review", not time.

---

## Owner facts that shaped decisions (keep in mind)
- Writes **zoomed in**, always; the live stroke is what must be crisp. Prefers pen width "one level thinner than Preview" — fine.
- Finger drawing disabled system-wide; the palm problem is **pan/zoom drift**, not stray ink. Uses Lock as the answer for now.
- Wants Preview's UI and behaviours (glass bar, name + thumbnail, ✎ = palette). Accepts ink disappearing during a pinch.
- Chooses options A/B when asked; wants numbered tests; dislikes ceremony and token waste; asks for honest trade-offs.
- Prefers delegation to cheaper models with Fable reviewing ("option B") — but the last three geometry/touch bugs were only caught by the orchestrator reading the code, so keep ink/touch changes under close review.

## If you are picking this up
1. Read `CLAUDE.md`, then `spec/SPEC.md` §5 and `spec/notes/S5-screen-canvas.md`.
2. Deploy `main` to the iPad and run `spec/SMOKE.md` before changing anything.
3. Open items are in `spec/WORK-PACKAGES.md` "Status" and `deferred.md`; the owner picks the order.
