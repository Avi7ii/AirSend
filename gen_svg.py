import sys

svg_head = """<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <defs>
    <!-- M3 Volume Shadows -->
    <filter id="m3" x="-40%" y="-40%" width="180%" height="180%">
      <feDropShadow dx="0" dy="8" stdDeviation="10" flood-color="#4A001F" flood-opacity="0.16"/>
    </filter>
    <filter id="m3-high" x="-40%" y="-40%" width="180%" height="180%">
      <feDropShadow dx="0" dy="24" stdDeviation="20" flood-color="#4A001F" flood-opacity="0.25"/>
    </filter>

    <g id="block">
      <polygon points="0,-80 69.28,-40 0,0 -69.28,-40" fill="#FFC9D6" />
      <polygon points="-69.28,-40 0,0 0,80 -69.28,40" fill="#8D3845" />
      <polygon points="0,0 69.28,-40 69.28,40 0,80" fill="#D94A6E" />
      <path d="M 0,-80 L 0,0 M -69.28,-40 L 0,0 M 69.28,-40 L 0,0" stroke="#FFF8F9" stroke-width="1.5" stroke-opacity="0.5"/>
    </g>
    
    <g id="block-dark">
      <polygon points="0,-80 69.28,-40 0,0 -69.28,-40" fill="#D94A6E" />
      <polygon points="-69.28,-40 0,0 0,80 -69.28,40" fill="#3D0014" />
      <polygon points="0,0 69.28,-40 69.28,40 0,80" fill="#6A1A2B" />
      <path d="M 0,-80 L 0,0 M -69.28,-40 L 0,0 M 69.28,-40 L 0,0" stroke="#FFD8E9" stroke-width="1.5" stroke-opacity="0.3"/>
    </g>

    <g id="block-light">
      <polygon points="0,-80 69.28,-40 0,0 -69.28,-40" fill="#FFFFFF" />
      <polygon points="-69.28,-40 0,0 0,80 -69.28,40" fill="#AA2E4D" />
      <polygon points="0,0 69.28,-40 69.28,40 0,80" fill="#FF8BA7" />
      <path d="M 0,-80 L 0,0 M -69.28,-40 L 0,0 M 69.28,-40 L 0,0" stroke="#FFF8F9" stroke-width="2" stroke-opacity="0.8"/>
    </g>

    <g id="block-hollow">
      <polygon points="0,-80 69.28,-40 0,0 -69.28,-40" fill="none" stroke="#FF8BA7" stroke-width="4" stroke-linejoin="round"/>
      <polygon points="-69.28,-40 0,0 0,80 -69.28,40" fill="none" stroke="#6A1A2B" stroke-width="4" stroke-linejoin="round"/>
      <polygon points="0,0 69.28,-40 69.28,40 0,80" fill="none" stroke="#D94A6E" stroke-width="4" stroke-linejoin="round"/>
    </g>
  </defs>

  <rect width="1024" height="1024" fill="none" />
  <rect x="64" y="64" width="896" height="896" rx="250" fill="#FFF0F2" />
  
  <g transform="translate(512, 190)">
"""

blocks_str = ""
N = 11
mid = 5
nodes = []

for u in range(N):
    for v in range(N):
        du = abs(u - mid)
        dv = abs(v - mid)
        d = max(du, dv)
        d_manhattan = du + dv
        
        if d_manhattan > 7:
            continue
            
        z = 0
        if d == 0:
            z = 6
        elif d == 1:
            z = 4
        elif d == 2:
            z = 3
        elif d == 3:
            z = 2
        elif d == 4:
            z = 1
        elif d == 5:
            z = 0
            
        b_type = "block"
        if d == 0:
            b_type = "block-light"
        elif d_manhattan % 2 != 0:
            b_type = "block-dark"
            
        if d_manhattan == 7 and d > 3:
            b_type = "block-hollow"
            z = 0.5 
            
        x = (u - v) * 69.28
        y = (u + v) * 40 - z * 80
        
        nodes.append({"u": u, "v": v, "sum": u+v, "x": x, "y": y, "type": b_type, "d": d})

nodes.sort(key=lambda n: n["sum"])

for n in nodes:
    filt = ' filter="url(#m3-high)"' if n["d"] <= 1 else ' filter="url(#m3)"'
    if n["type"] == "block-hollow":
        filt = ' opacity="0.9"'
    blocks_str += f'    <use href="#{n["type"]}" x="{n["x"]:.2f}" y="{n["y"]:.2f}"{filt} />\n'

svg_tail = """
  </g>
</svg>"""

with open("/Users/thom/Desktop/Localsend X/AirSend-macOS/Sources/AirSend/m3-icon-dynamic-rose.svg", "w") as f:
    f.write(svg_head + blocks_str + svg_tail)

print("SVG Generated.")
