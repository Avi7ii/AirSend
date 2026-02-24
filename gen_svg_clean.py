import sys

# Scale factors for isometric grid
R = 42  # 大幅缩小半径，防止超出 832x832 圆角框
DX = R * 0.866025  # cos(30)
DY = R * 0.5       # sin(30)
DZ = R * 1.0       # height of a block

svg_head = f"""<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <defs>
    <!-- M3 Volume Shadows -->
    <filter id="m3" x="-40%" y="-40%" width="180%" height="180%">
      <feDropShadow dx="0" dy="8" stdDeviation="12" flood-color="#4A001F" flood-opacity="0.12"/>
    </filter>
    <filter id="m3-high" x="-40%" y="-40%" width="180%" height="180%">
      <feDropShadow dx="0" dy="16" stdDeviation="18" flood-color="#4A001F" flood-opacity="0.2"/>
    </filter>

    <g id="block">
      <!-- Top face -->
      <polygon points="0,{-DZ} {DX},{-DZ+DY} 0,0 {-DX},{-DZ+DY}" fill="#FFC9D6" />
      <!-- Left face -->
      <polygon points="{-DX},{-DZ+DY} 0,0 0,{DZ} {-DX},{DY}" fill="#8D3845" />
      <!-- Right face -->
      <polygon points="0,0 {DX},{-DZ+DY} {DX},{DY} 0,{DZ}" fill="#D94A6E" />
      <!-- Edges for crisp M3 feel -->
      <path d="M 0,{-DZ} L 0,0 M {-DX},{-DZ+DY} L 0,0 M {DX},{-DZ+DY} L 0,0" stroke="#FFF8F9" stroke-width="1.5" stroke-opacity="0.6"/>
    </g>
    
    <g id="block-dark">
      <polygon points="0,{-DZ} {DX},{-DZ+DY} 0,0 {-DX},{-DZ+DY}" fill="#D94A6E" />
      <polygon points="{-DX},{-DZ+DY} 0,0 0,{DZ} {-DX},{DY}" fill="#3D0014" />
      <polygon points="0,0 {DX},{-DZ+DY} {DX},{DY} 0,{DZ}" fill="#6A1A2B" />
      <path d="M 0,{-DZ} L 0,0 M {-DX},{-DZ+DY} L 0,0 M {DX},{-DZ+DY} L 0,0" stroke="#FFD8E9" stroke-width="1.5" stroke-opacity="0.4"/>
    </g>

    <g id="block-light">
      <polygon points="0,{-DZ} {DX},{-DZ+DY} 0,0 {-DX},{-DZ+DY}" fill="#FFFFFF" />
      <polygon points="{-DX},{-DZ+DY} 0,0 0,{DZ} {-DX},{DY}" fill="#AA2E4D" />
      <polygon points="0,0 {DX},{-DZ+DY} {DX},{DY} 0,{DZ}" fill="#FF8BA7" />
      <path d="M 0,{-DZ} L 0,0 M {-DX},{-DZ+DY} L 0,0 M {DX},{-DZ+DY} L 0,0" stroke="#FFF8F9" stroke-width="2.5" stroke-opacity="0.9"/>
    </g>
  </defs>

  <!-- Clear Background -->
  <rect width="1024" height="1024" fill="none" />
  
  <!-- M3 Squircle Primary Container -->
  <rect x="96" y="96" width="832" height="832" rx="224" fill="#FFF0F2" filter="url(#m3)" />
  
  <g transform="translate(512, 530)">
"""

blocks_logic = [
    # Center pillar
    (0, 0, 0, "block-dark"), 
    (0, 0, 1, "block"), 
    (0, 0, 2, "block"), 
    (0, 0, 3, "block-light"),
    
    # +u axis (Front-Right arm)
    (1, 0, 0, "block"), (2, 0, 0, "block"), (3, 0, 0, "block-dark"), (4, 0, 0, "block-light"),
    (1, 0, 1, "block"), (2, 0, 1, "block-light"),
    (1, 0, 2, "block"),
    
    # -u axis (Back-Left arm)
    (-1, 0, 0, "block"), (-2, 0, 0, "block"), (-3, 0, 0, "block-dark"), (-4, 0, 0, "block-light"),
    (-1, 0, 1, "block"), (-2, 0, 1, "block-light"),
    (-1, 0, 2, "block"),
    
    # +v axis (Back-Right arm)
    (0, 1, 0, "block"), (0, 2, 0, "block"), (0, 3, 0, "block-dark"), (0, 4, 0, "block-light"),
    (0, 1, 1, "block"), (0, 2, 1, "block-light"),
    (0, 1, 2, "block"),
    
    # -v axis (Front-Left arm)
    (0, -1, 0, "block"), (0, -2, 0, "block"), (0, -3, 0, "block-dark"), (0, -4, 0, "block-light"),
    (0, -1, 1, "block"), (0, -2, 1, "block-light"),
    (0, -1, 2, "block")
]

nodes = []
for u, v, z, b_type in blocks_logic:
    x = (u - v) * DX
    y = (u + v) * DY - z * DZ
    nodes.append({"u": u, "v": v, "z": z, "x": x, "y": y, "type": b_type, "sort_key": u + v + z*0.01})

nodes.sort(key=lambda n: n["sort_key"])

blocks_str = ""
for n in nodes:
    filt = ' filter="url(#m3-high)"' if n["z"] >= 2 or abs(n["u"]) == 4 or abs(n["v"]) == 4 else ' filter="url(#m3)"'
    blocks_str += f'    <use href="#{n["type"]}" x="{n["x"]:.2f}" y="{n["y"]:.2f}"{filt} />\n'

svg_tail = """
  </g>
</svg>"""

with open("/Users/thom/Desktop/Localsend X/AirSend-macOS/Sources/AirSend/m3-icon-dynamic-rose.svg", "w") as f:
    f.write(svg_head + blocks_str + svg_tail)

print("SVG Generated successfully.")
