# AirSend Engineering Architecture

The developer-facing architecture plate is generated directly as SVG for the
repository README. It is a deterministic engineering schematic, not an
AI-generated image. An editable draw.io engineering model is retained as a
companion for Next AI Draw.io-assisted exploration and future restructuring.

- README poster: `airsend-engineering-architecture.svg`
- Poster generator: `generate_architecture_poster.mjs`
- Editable engineering model: `airsend-engineering-architecture.drawio`
- Draw.io model generator: `generate_architecture.mjs`

## Regenerate

The README image is generated as a deterministic SVG. The layout keeps the
high-density dual-runtime poster structure while reserving explicit cable lanes
for cross-boundary routing.

```bash
node docs/architecture/generate_architecture_poster.mjs
```

The companion `.drawio` model can be opened in
[Next AI Draw.io](https://github.com/DayuanJiang/next-ai-draw-io) for
natural-language architecture edits. Regenerate it separately with:

```bash
node docs/architecture/generate_architecture.mjs
```

## Diagram Tool Research

| Project | Best use | Fit for this diagram |
| --- | --- | --- |
| [Next AI Draw.io](https://github.com/DayuanJiang/next-ai-draw-io) | Natural-language generation and iterative editing of draw.io XML | Best maintenance companion because the final source remains editable draw.io XML |
| [draw.io](https://github.com/jgraph/drawio) | Dense manually controlled engineering diagrams | Chosen final renderer; supports containers, precise routing, SVG export, and sketch style |
| [D2](https://github.com/terrastruct/d2) | Text-to-diagram with strong automatic layout engines | Excellent for rapidly laying out large graphs; useful when architecture changes frequently |
| [D2](https://github.com/terrastruct/d2) | Text-to-diagram with ELK layout and native sketch rendering | Explored; strong routing, but automatic layouts flattened the intended dense poster composition |
| [Excalidraw DSL](https://github.com/tyrchen/excalidraw-dsl) | Diagram-as-code with editable Excalidraw output | Explored; Force tangled feedback paths and Dagre produced an impractically wide graph |
| [Excalidraw](https://github.com/excalidraw/excalidraw) | Strongest freehand visual language | Useful for manual annotation after the generated graph stabilizes |
| [PlantUML](https://github.com/plantuml/plantuml) | UML, sequence, deployment, and C4-style documentation | Strong for rigorous modeled views; less suitable for this single poster-like hand-drawn overview |
| [Diagrams](https://github.com/mingrammer/diagrams) | Diagram-as-code with cloud/provider icons | Strong for cloud topology; less relevant to AirSend's native process and protocol internals |

## Information Model

The diagram deliberately combines four views in one canvas:

1. Platform boundaries: macOS, local network, and Android.
2. Runtime boundaries: Swift main process, Kotlin app process,
   `system_server`, and root Rust daemon.
3. Protocol boundaries: AirSend discovery and recovery mechanisms, the
   LocalSend-compatible HTTP API adapter, HTTPS default
   path, manual HTTP compatibility path, and bounded campus UDP fallback.
4. Data flows: files, directories, clipboard text, PNG images, screenshots,
   registration, Direct Share, and reverse clipboard writes.

The campus fallback is shown separately from HTTP compatibility because they are
different mechanisms. HTTP compatibility retains the LocalSend API over an
explicitly enabled plain HTTP data path. Campus fallback is a bounded UDP
window protocol for payloads up to 1 MiB.
