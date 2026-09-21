# Fox artwork staging resource

These transparent PNGs are the first state-resource slice extracted from the
approved middle fox in the candidate contact sheet:

- `fox-idle.png`: neutral idle posture;
- `fox-working.png`: working posture with the small screen;
- `fox-completed.png`: completed posture with the green check;
- `fox-waiting-input.png`: waiting posture with the question mark;
- `fox-system-error.png`: current system-error posture with the red marker.

They are still staging resources rather than a finished animated atlas. States
without a reliable matching frame currently fall back to `fox-idle.png`, while
the Touch Bar status label and color continue to communicate the actual state.

State-specific frames and the final animated v2 atlas remain separate work and
must pass visual QA before replacing this fallback.
