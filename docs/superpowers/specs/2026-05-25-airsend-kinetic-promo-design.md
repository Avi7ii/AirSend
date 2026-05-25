# AirSend Kinetic Promo Design

## Goal

Create a 16:9 horizontal Remotion promo video from the assets in `screenshot/`.
The result should feel like a kinetic product launch teaser: strong title motion,
mask sweeps, light movement, punchy transitions, and concise Chinese copy.

The final video must use the brand name `AirSend` only. No legacy or upstream
brand naming may appear anywhere in the main video, captions, titles, metadata
text shown on screen, or rendered end card.

## Source Assets

Use these video clips in full. Do not crop the picture, do not trim their time,
and do not play them faster or slower.

- `screenshot/截图同步Mac向Android.mp4` - 9.167s, 1660x1080
- `screenshot/文件互传Android向Mac.mp4` - 11.4s, 1660x1080
- `screenshot/双端剪贴板同步.mp4` - 17.634s, 1660x1080
- `screenshot/截屏互传Android向Mac.mp4` - 10.15s, 1660x1080
- `screenshot/文件互传Mac向Android.mp4` - 7.5s, 1660x1080

Use these images as timing and visual anchors. Their display duration can be
chosen during implementation.

- `screenshot/状态栏应用界面.png`
- `screenshot/设置界面.png`
- `screenshot/无数次提交与版本更迭.png`

## Output

- Main composition: 1920x1080, 30fps.
- Expected length: about 65-70 seconds, depending on still-image hold times and
  transition overlap.
- Video clip audio: muted.
- Added audio: subtle background rhythm and light transition hits. Audio should
  support the motion without becoming the focus.

## Timeline

1. Open, 4-5s
   AirSend title reveal with kinetic text, mask sweeps, and quick flashes of the
   status/menu and settings screenshots.

2. Screenshot Sync, full clip
   Show `截图同步Mac向Android.mp4`. On-screen copy: `截图即刻同步`.

3. Android to Mac File Transfer, full clip
   Show `文件互传Android向Mac.mp4`. On-screen copy: `跨端文件直达`.

4. Clipboard Sync, full clip
   Show `双端剪贴板同步.mp4`. On-screen copy: `剪贴板双端接力`.

5. Android to Mac Screenshot Transfer, full clip
   Show `截屏互传Android向Mac.mp4`. On-screen copy: `移动端截屏，桌面即收`.

6. Mac to Android File Transfer, full clip
   Show `文件互传Mac向Android.mp4`. On-screen copy: `从 Mac 推送到 Android`.

7. Close, 4-6s
   Use `无数次提交与版本更迭.png` as the build journey anchor, then end on an
   AirSend title lockup.

## Motion Direction

The kinetic style should be energetic, but the product footage stays readable.
Use strong motion mostly at scene starts and exits. During the middle of each
recorded clip, captions should either fade out or move into safe margins.

Scene transitions should combine:

- `@remotion/transitions` with `TransitionSeries`.
- Fade, slide, wipe, or flip transitions where they support the story.
- Overlay accents such as light sweeps or scan lines, implemented in React/CSS
  unless a small dependency is already justified.
- Subtle scale or camera drift on still images and the framed product footage.

Because source video is 1660x1080 inside a 1920x1080 composition, render it with
`object-fit: contain` inside a full-frame stage. Do not use `cover`.

## Text System

Use short Chinese copy only. Titles should animate with masks, staggered words,
or fast directional movement. Body copy should be minimal. Avoid explanatory
paragraphs on screen.

Primary copy:

- `AirSend`
- `截图即刻同步`
- `跨端文件直达`
- `剪贴板双端接力`
- `移动端截屏，桌面即收`
- `从 Mac 推送到 Android`
- `为每一次跨端协作而生`

Forbidden visible text:

- Any legacy or upstream brand name.
- Any variant that visually includes a legacy or upstream brand name.

## Remotion Architecture

Create a local Remotion project or composition under a repo-local output area,
keeping generated build artifacts out of git. Copy or reference assets through
Remotion's `public/` folder and `staticFile()`.

Recommended components:

- `AirSendPromo` - root composition and timing.
- `SceneTimeline` - `TransitionSeries` assembly.
- `MediaScene` - full-duration video scene with safe text overlay.
- `StillScene` - still-image stage with kinetic camera movement.
- `KineticTitle` - reusable title reveal.
- `TransitionFlash` or `LightSweep` - reusable overlay accent.
- `AudioBed` - generated or bundled subtle rhythm/transition audio.

Use data-driven scene definitions so clip names, copy, durations, and transition
settings are easy to audit.

## Verification

Before claiming completion:

- Render or preview the composition with Remotion.
- Check at least one still frame from the open, a video scene, and the close.
- Confirm that all video clips appear with no crop and full duration.
- Confirm no visible text contains legacy or upstream brand naming.
- Confirm text does not cover important product actions for long periods.
- Confirm audio is present only as added background/transition audio and source
  clip audio is muted.

## Non-Goals

- No vertical version in the first pass.
- No voiceover in the first pass.
- No trimming, speed ramping, or cropping of source video clips.
- No changes to the AirSend app code.
