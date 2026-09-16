# PenPDF — Device Acceptance Checklist

Run on a real iPad with a real Apple Pencil. Simulator results do not count for anything marked (device).
Tick with the WP that must pass it. Any P0 failure blocks "done".

## A. Opening (WP1)
- [ ] A1 Cold launch, no last document → Files browser filtered to PDFs, no "+" create button.
- [ ] A2 Tap a PDF in the browser → Reader opens full-screen; title shows `1 / N` (or restored page).
- [ ] A3 From the Files app: long-press a PDF → Share → PenPDF opens it (Open With).
- [ ] A4 Back → browser. Reopen same file → instant.
- [ ] A5 Cold launch with a last document → lands directly in it, no browser flash (FR-5, P1).
- [ ] A6 A non-PDF renamed to `.pdf` → alert, browser stays.

## B. Position invariants — the "never lose my page" tests (WP2/WP3)
- [ ] B1 Scroll to a page deep in the doc (write it down). Tap the **status bar** → page unchanged. (P0)
- [ ] B2 Tap the **navigation bar** background/title → page unchanged. (P0)
- [ ] B3 Rotate iPad portrait ↔ landscape → same page; width re-fits. (P0)
- [ ] B4 Slide-over / Split View another app, resize the divider → same page. (P0)
- [ ] B5 Show and hide the tool palette → same page. (P0)
- [ ] B6 Toggle Lock on/off → same page. (P0)
- [ ] B7 Background the app (home), wait 10 s, return → same page. (P0)
- [ ] B8 Kill from the app switcher, relaunch, reopen → **first visible frame** is the saved page; screen-record and scrub — there must be no page-1 flash. (P0)
- [ ] B9 In Files: rename the PDF → reopen → same page. (P0)
- [ ] B10 In Files: move the PDF to another folder / from On My iPad to iCloud Drive → reopen → same page. (P0)
- [ ] B11 Two PDFs open alternately remember independent pages. (P0)
- [ ] B12 Same page **and** same scroll point / zoom restored. (P1)
- [ ] B13 Delete the app's data (reinstall) → opens at page 1 — the only allowed case.

## C. Ink (WP4, device)
- [ ] C1 Draw with Pencil at fit-width. Pinch to 300 % → ink exactly on the same content. Back to 50 % → same. (P0)
- [ ] C2 Draw, scroll 30 pages away, come back → ink present and aligned. (P0)
- [ ] C3 Draw, kill app, relaunch → ink present and aligned on every drawn page. (P0)
- [ ] C4 Draw, rotate iPad → ink aligned. (P0)
- [ ] C5 Draw on a **rotated (landscape) page** in a mixed doc → aligned after C1–C4. (P0)
- [ ] C6 Draw a stroke then immediately background the app (< 1 s) → stroke survives relaunch. (P0)
- [ ] C7 Erase all ink on a page → page's `.drawing` file gone (check via Xcode container download, or trust WP4's log). (P1)
- [ ] C8 Undo removes the last stroke; redo restores it. (P0)
- [ ] C9 Palette: pen/marker/pencil/eraser/lasso/ruler and colors all behave as in Apple Notes. Pencil double-tap follows the system setting. (P0)
- [ ] C10 Latency: write a line of text side-by-side with Apple Notes → no perceivable difference. (P0)
- [ ] C11 Scribble 100+ dense strokes on one page, scroll → no stutter. (P1)

## D. Palm & finger (WP4, device)
- [ ] D1 System Settings → Apple Pencil → "Only Draw with Apple Pencil" **OFF**. Finger on page: pans/zooms, **never draws**. (P0)
- [ ] D2 Rest palm on the page while writing (unlocked) → no stray ink (guaranteed by `pencilOnly`). Note how much the palm pans/zooms the page — this was the owner's actual Preview complaint; Lock (E1) is the answer, and if the drift is bad enough that Lock stays on permanently, make Lock default-on (one flag in `AppSettings`). (P0)
- [ ] D3 Finger long-press selects text (unlocked). (P1)

## E. Lock mode (WP5, device)
- [ ] E1 Lock ON → icon filled/tinted. Palm rest + drag fingers in all directions + pinch → page does not move, zoom, or select. (P0)
- [ ] E2 Lock ON → Pencil draws normally; palette opens; undo/redo work. (P0)
- [ ] E3 Lock ON → prev/next buttons change page; title updates. (P0)
- [ ] E4 Lock ON → rotate iPad → still locked, same page. (P0)
- [ ] E5 Lock ON → back to browser → open another PDF → still locked. Kill & relaunch → still locked. (P0)
- [ ] E6 Lock OFF → finger pan/zoom/select all return immediately. (P0)
- [ ] E7 Lock button unreachable by a resting palm (it's in the top bar; nothing floats over the page). (P0)

## F. Performance & robustness
- [ ] F1 200+ MB scanned book: open < 3 s, fling-scroll smooth, no memory kill after 5 min of use. (P0)
- [ ] F2 Vector-heavy PDF: zoom/pan usable (Preview-comparable). If it stutters, note it — this is the PDFium trigger, not a bug. (P1)
- [ ] F3 Cold launch to restored page on a small PDF < 1.5 s. (P1)
- [ ] F4 Airplane mode: everything works. (P0)
- [ ] F5 Password PDF → prompt → correct password opens; wrong → back to browser. (P1)
- [ ] F6 Xcode console on launch and while drawing: no constraint warnings, no PDFKit/PencilKit warnings. (P1)
