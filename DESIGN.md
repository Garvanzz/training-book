---
version: alpha
product: Training Book
platforms: [windows, ios]
theme: dark
colors:
  canvas: '#0B0E12'
  surface: '#131820'
  surfaceRaised: '#1A212B'
  surfaceInteractive: '#222C38'
  border: '#2D3947'
  text: '#F2F5F7'
  muted: '#9CA9B8'
  accent: '#B8E85C'
  accentInk: '#172000'
  info: '#78B7FF'
  warning: '#F5C56B'
  danger: '#FF8383'
spacing: [4, 8, 12, 16, 24, 32, 48]
radii:
  small: 10
  medium: 16
  large: 24
---

# Training Book Design System

## Product character

Training Book is a personal training workbench: calm, concentrated and precise. It is not a neon gym app, nor a dense administration form. Prefer a quiet task surface over explanatory copy: information earns its place only when it changes the next action.

## Typography

Use `Microsoft YaHei UI` on Windows, with `PingFang SC` and system sans-serif as fallbacks. The main page title is 28px/700; section titles are 18px/700; body text is 14px/400; supporting text is 12px/400. Never use placeholder copy as saved content: hints must remain visually muted until the user types.

## Layout

Desktop uses a persistent 216px navigation rail, a 32px page gutter and a maximum readable content width of 1320px. A workbench may use two or three panes: navigation/list, working canvas, and contextual inspection. Mobile collapses this to one focused column.

## Color and elevation

The canvas is near-black graphite, not pure black. Surfaces are separated with 1px low-contrast borders before shadows. Lime is reserved for the next useful action, completion and positive state; it must not become a large background color. Blue is informational, amber is attention, and red is destructive or unsafe.

## Components

- Cards are grouped working surfaces, not every line item. Radius 16px, 1px border, 16–24px internal padding.
- Buttons use a clear action hierarchy: filled lime for the one primary action in a region; tonal/outlined for secondary actions; icon buttons always have tooltips.
- Forms are assembled from optional sections. Empty sections show only a `+` affordance; adding a row is always intentional.
- Lists show an icon or media thumbnail, primary name, one useful status/detail line and a clear selection affordance.
- Status is shown as compact labeled chips, never as unexplained colored dots.

## Key journeys

### Today

Lead with the next concrete action: select a plan and start training. Keep sync status out of the main surface unless it requires attention.

### Plan builder

One plan is one complete training session. It is a canvas of reorderable stage blocks: warm-up/mobility, activation, primary strength, accessory, conditioning or recovery. Selecting an exercise opens its training settings without leaving the plan.

### Exercise library

The desktop library is led by the published action list. Drafts are a compact secondary queue. Saving and publishing are permissive: only an action name is required.

## Do / don't

Do use terse empty states, spacious grouping and readable Chinese labels. Do preserve user-entered text exactly. Don't prefill instructions merely to make a form look complete. Don't use gradients, generic fitness photos, excessive rounded pills, explanatory panels, or a dashboard of fabricated metrics.
