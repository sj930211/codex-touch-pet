# Fox artwork resources

These transparent PNGs are the first state-resource slice extracted from the
approved middle fox in the candidate contact sheet:

- `fox-idle.png`: neutral idle fallback frame;
- `fox-idle-00.png` … `fox-idle-05.png`: normalized idle animation frames;
- `fox-working.png`: working fallback frame;
- `fox-working-00.png` … `fox-working-05.png`: normalized working animation
  frames with two hind legs grounded and two front paws on the keyboard;
- `fox-waiting-approval-00.png` … `05`: approval-waiting loop;
- `fox-waiting-input-00.png` … `05`: input-waiting loop;
- `fox-connecting-00.png` … `05`: connecting scan loop;
- `fox-disconnected-00.png` … `05`: disconnected resting loop;
- `fox-completed-00.png` … `05`: one-shot completion reaction;
- `fox-failed-00.png` … `05`: one-shot failure reaction;
- `fox-system-error-00.png` … `05`: one-shot system-error reaction;
- `fox-interrupted-00.png` … `05`: one-shot stopped reaction.
- `fox-idle-run-right-00.png` … `07`: idle-only eight-frame run cycle facing right;
- `fox-idle-run-left-00.png` … `07`: mirrored eight-frame run cycle facing left;
- `fox-idle-jump-00.png` … `07`: idle-only small hop action;
- `fox-idle-play-00.png` … `07`: idle-only tail-play action.

All semantic states use six-frame rows. Every row uses one shared spatial
transform on a 192×208 canvas, with a common 171-pixel reference height and
baseline. This prevents size popping without independently resizing each pose.
The Touch Bar status label and color remain authoritative when artwork fails to
load.

The source frames and normalization script live under
`design-test/animation-test/fox-v2-continuity/` and are retained for visual QA.

The idle play-action drafts and deterministic strip normalization live under
`design-test/animation-test/fox-play-v1/`. These actions keep the semantic
state as `idle`; they are not task-status replacements. The run action now
selects a left/right resource from the movement target and uses a longer
eight-frame cycle, so moving back across the blank Touch Bar area no longer
looks like a forward-facing fox sliding backward.
