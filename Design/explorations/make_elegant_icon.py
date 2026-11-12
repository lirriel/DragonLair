"""Generates AppIcon-elegant.svg: a jade dragon curled asleep around stacks of gold.

The serpentine body is built from a Catmull-Rom centerline with a width profile,
so the taper, belly band, scales and mane all follow the same curve.
Run: python3 make_elegant_icon.py
"""
import math
import os

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "AppIcon-elegant.svg")
CENTER = (520, 540)

# centerline from the neck (behind the head) around the hoard to the tail tip
CTRL = [
    (450, 655), (360, 702), (268, 662), (214, 540), (248, 392), (368, 282),
    (520, 246), (680, 282), (800, 392), (836, 545), (790, 694), (676, 792),
    (530, 834), (390, 826), (285, 800), (205, 770),
]


def catmull_rom(pts, samples_per_seg=40):
    pts = [pts[0]] + pts + [pts[-1]]
    out = []
    for i in range(1, len(pts) - 2):
        p0, p1, p2, p3 = pts[i - 1], pts[i], pts[i + 1], pts[i + 2]
        for s in range(samples_per_seg):
            t = s / samples_per_seg
            t2, t3 = t * t, t * t * t
            out.append(tuple(
                0.5 * (2 * p1[k] + (-p0[k] + p2[k]) * t + (2 * p0[k] - 5 * p1[k] + 4 * p2[k] - p3[k]) * t2
                       + (-p0[k] + 3 * p1[k] - 3 * p2[k] + p3[k]) * t3)
                for k in range(2)))
    out.append(pts[-2])
    return out


def width_at(u):
    if u < 0.22:
        return 66 + (94 - 66) * math.sin(u / 0.22 * math.pi / 2)
    if u < 0.55:
        return 94
    v = (u - 0.55) / 0.45
    return 4 + 90 * (math.cos(v * math.pi / 2) ** 1.3)


line = catmull_rom(CTRL)
seg = [0.0]
for a, b in zip(line, line[1:]):
    seg.append(seg[-1] + math.dist(a, b))
total = seg[-1]

frames = []  # (point, unit tangent, unit outward normal, width, u)
for i, p in enumerate(line):
    a = line[max(i - 1, 0)]
    b = line[min(i + 1, len(line) - 1)]
    tx, ty = b[0] - a[0], b[1] - a[1]
    n = math.hypot(tx, ty) or 1
    tx, ty = tx / n, ty / n
    nx, ny = -ty, tx
    # make the normal point away from the hoard
    if (p[0] - CENTER[0]) * nx + (p[1] - CENTER[1]) * ny < 0:
        nx, ny = -nx, -ny
    u = seg[i] / total
    frames.append((p, (tx, ty), (nx, ny), width_at(u), u))


def off(f, k):
    (px, py), _, (nx, ny), _, _ = f
    return (px + nx * k, py + ny * k)


def poly(points):
    return "M" + " L".join(f"{x:.1f} {y:.1f}" for x, y in points) + " Z"


outer = [off(f, f[3] / 2) for f in frames]
inner = [off(f, -f[3] / 2) for f in frames]
body_d = poly(outer + inner[::-1])

belly_frames = [f for f in frames if f[4] < 0.93]
belly_d = poly([off(f, -f[3] / 2) for f in belly_frames]
               + [off(f, -f[3] / 2 + f[3] * 0.3) for f in belly_frames][::-1])

# belly plates: fine transverse lines
plates = []
step = total / 64
nxt = step * 2
for f, s in zip(frames, seg):
    if f[4] > 0.9:
        break
    if s >= nxt:
        a = off(f, -f[3] / 2 + 2)
        b = off(f, -f[3] / 2 + f[3] * 0.28)
        plates.append(f"M{a[0]:.1f} {a[1]:.1f} L{b[0]:.1f} {b[1]:.1f}")
        nxt += step

# scales: small backward-bulging arcs in staggered rows on the back
scales = []
step = total / 70
nxt = step
row = 0
for f, s in zip(frames, seg):
    if f[4] > 0.88:
        break
    if s >= nxt:
        (px, py), (tx, ty), (nx, ny), w, _ = f
        ks = [0.02, 0.24] if row % 2 == 0 else [0.13, 0.35]
        for k in ks:
            k *= w
            r = w * 0.09
            p0 = (px + nx * (k - r), py + ny * (k - r))
            p2 = (px + nx * (k + r), py + ny * (k + r))
            c = (px + nx * k - tx * r * 1.3, py + ny * k - ty * r * 1.3)
            scales.append(f"M{p0[0]:.1f} {p0[1]:.1f} Q{c[0]:.1f} {c[1]:.1f} {p2[0]:.1f} {p2[1]:.1f}")
        row += 1
        nxt += step

# mane: fine gold strands sweeping back off the spine
mane = []
step = total / 46
nxt = step * 1.5
for f, s in zip(frames, seg):
    if f[4] > 0.82:
        break
    if s >= nxt:
        (px, py), (tx, ty), (nx, ny), w, u = f
        base = (px + nx * w * 0.42, py + ny * w * 0.42)
        L = 20 * (1 - u * 0.5)
        tip = (base[0] + nx * L - tx * L * 0.9, base[1] + ny * L - ty * L * 0.9)
        c = (base[0] + nx * L * 0.9, base[1] + ny * L * 0.9)
        mane.append(f"M{base[0]:.1f} {base[1]:.1f} Q{c[0]:.1f} {c[1]:.1f} {tip[0]:.1f} {tip[1]:.1f}")
        nxt += step

# coin stacks
def coin_stack(cx, base_y, n, rx=54, ry=16, h=15):
    parts = []
    for i in range(n):
        y = base_y - i * h
        parts.append(
            f'<path d="M{cx - rx} {y - h} L{cx - rx} {y} A{rx} {ry} 0 0 0 {cx + rx} {y} L{cx + rx} {y - h} Z" fill="url(#coinEdge)" stroke="#8A6526" stroke-width="1.6"/>')
        parts.append(f'<path d="M{cx - rx + 4} {y - h * 0.45} A{rx - 4} {ry - 2} 0 0 0 {cx + rx - 4} {y - h * 0.45}" fill="none" stroke="#F3D68E" stroke-width="1" opacity="0.5"/>')
    top = base_y - n * h
    parts.append(f'<ellipse cx="{cx}" cy="{top}" rx="{rx}" ry="{ry}" fill="url(#coinFace)" stroke="#8A6526" stroke-width="1.6"/>')
    parts.append(f'<ellipse cx="{cx}" cy="{top}" rx="{rx - 9}" ry="{ry - 4}" fill="none" stroke="#B8893A" stroke-width="1.4"/>')
    return "\n    ".join(parts), top


stack_a, top_a = coin_stack(462, 640, 8)
stack_b, top_b = coin_stack(566, 652, 12)
stack_c, top_c = coin_stack(664, 640, 6)

svg = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <defs>
    <radialGradient id="bg" cx="50%" cy="46%" r="70%">
      <stop offset="0" stop-color="#2D5A4E"/>
      <stop offset="0.55" stop-color="#1B3D34"/>
      <stop offset="1" stop-color="#0E211C"/>
    </radialGradient>
    <radialGradient id="halo" cx="52%" cy="58%" r="32%">
      <stop offset="0" stop-color="#F2D28A" stop-opacity="0.28"/>
      <stop offset="1" stop-color="#F2D28A" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="jade" x1="0.15" y1="0" x2="0.85" y2="1">
      <stop offset="0" stop-color="#D3E7D6"/>
      <stop offset="0.5" stop-color="#A9CCB4"/>
      <stop offset="1" stop-color="#7FA993"/>
    </linearGradient>
    <linearGradient id="ivory" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#F6EEDC"/>
      <stop offset="1" stop-color="#E4D5B4"/>
    </linearGradient>
    <linearGradient id="gold" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#F6DFA0"/>
      <stop offset="0.5" stop-color="#D6AE5C"/>
      <stop offset="1" stop-color="#A97E34"/>
    </linearGradient>
    <linearGradient id="coinEdge" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0" stop-color="#B98A37"/>
      <stop offset="0.35" stop-color="#F0CF7E"/>
      <stop offset="0.7" stop-color="#D0A24E"/>
      <stop offset="1" stop-color="#9C7229"/>
    </linearGradient>
    <radialGradient id="coinFace" cx="40%" cy="35%" r="70%">
      <stop offset="0" stop-color="#FBE6A8"/>
      <stop offset="1" stop-color="#D9AC55"/>
    </radialGradient>
    <linearGradient id="silk" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0" stop-color="#6E1F2E"/>
      <stop offset="0.5" stop-color="#9E3446"/>
      <stop offset="1" stop-color="#6E1F2E"/>
    </linearGradient>
    <filter id="shadow" x="-10%" y="-10%" width="120%" height="120%">
      <feGaussianBlur in="SourceAlpha" stdDeviation="10"/>
      <feOffset dy="8"/>
      <feColorMatrix type="matrix" values="0 0 0 0 0.02  0 0 0 0 0.08  0 0 0 0 0.06  0 0 0 0.55 0"/>
      <feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge>
    </filter>
  </defs>

  <rect width="1024" height="1024" fill="url(#bg)"/>
  <rect width="1024" height="1024" fill="url(#halo)"/>

  <!-- medallion rings -->
  <circle cx="512" cy="530" r="452" fill="none" stroke="#D6AE5C" stroke-width="2.5" opacity="0.45"/>
  <circle cx="512" cy="530" r="438" fill="none" stroke="#D6AE5C" stroke-width="1" opacity="0.3"/>
  <g fill="#E9CB85" opacity="0.7">
    <path d="M512 72 l6 14 l14 6 l-14 6 l-6 14 l-6 -14 l-14 -6 l14 -6 Z"/>
    <path d="M168 300 l3 8 l8 3 l-8 3 l-3 8 l-3 -8 l-8 -3 l8 -3 Z"/>
    <path d="M866 300 l3 8 l8 3 l-8 3 l-3 8 l-3 -8 l-8 -3 l8 -3 Z"/>
  </g>

  <!-- hoard -->
  <g filter="url(#shadow)">
    {stack_a}
    {stack_c}
    {stack_b}
  </g>
  <!-- silk bookmark laid across the tall stack, hanging down its side -->
  <g filter="url(#shadow)">
    <path d="M548 {top_b - 4} C584 {top_b - 10} 612 {top_b - 4} 626 {top_b + 8} L628 {top_b + 104} L615 {top_b + 90} L602 {top_b + 106} L602 {top_b + 22} C594 {top_b + 12} 574 {top_b + 10} 548 {top_b + 14} Z" fill="url(#silk)"/>
    <path d="M606 {top_b + 22} L606 {top_b + 94} M623 {top_b + 14} L623 {top_b + 92}" fill="none" stroke="#E2B86A" stroke-width="1.3" opacity="0.75"/>
  </g>
  <g fill="url(#coinFace)" stroke="#8A6526" stroke-width="1.6">
    
  </g>

  <!-- body -->
  <g filter="url(#shadow)">
    <path d="{body_d}" fill="url(#jade)" stroke="#3E6B59" stroke-width="2.5" stroke-linejoin="round"/>
  </g>
  <path d="{belly_d}" fill="url(#ivory)"/>
  <path d="{' '.join(plates)}" fill="none" stroke="#C8B48A" stroke-width="1.2" opacity="0.6" stroke-linecap="round"/>
  <path d="{' '.join(scales)}" fill="none" stroke="#6F9A84" stroke-width="1.6" stroke-linecap="round" opacity="0.55"/>
  <path d="{' '.join(mane)}" fill="none" stroke="#E2C27A" stroke-width="2.2" stroke-linecap="round" opacity="0.9"/>

  <!-- tail plume -->
  <g stroke="#E2C27A" stroke-width="1.8" stroke-linejoin="round" fill="#F2E7CF">
    <path d="M212 768 C186 744 150 716 146 692 C144 676 162 674 170 688 C184 712 200 738 214 760 Z"/>
    <path d="M210 778 C182 798 146 812 116 812 C100 812 102 796 116 794 C148 790 178 786 208 772 Z"/>
    <path d="M210 772 C176 772 136 760 116 740 C104 728 116 716 130 724 C156 740 184 756 210 766 Z"/>
  </g>
  <g fill="none" stroke="#C9A55E" stroke-width="1.1" stroke-linecap="round">
    <path d="M206 762 C188 738 168 714 160 690"/>
    <path d="M204 770 C176 762 148 748 126 730"/>
    <path d="M204 776 C178 790 148 800 118 804"/>
  </g>

  <!-- head -->
  <g filter="url(#shadow)" transform="translate(452 650) scale(1.38) translate(-452 -650)">
    <!-- far antler -->
    <g fill="none" stroke-linecap="round" opacity="0.75">
      <path d="M462 600 C446 560 434 528 404 504 M440 556 C448 534 462 520 480 512 M420 528 C406 520 390 520 376 526" stroke="#A97E34" stroke-width="8"/>
    </g>
    <!-- near antler -->
    <g fill="none" stroke-linecap="round">
      <path d="M438 600 C418 558 402 524 366 498 M416 552 C424 528 440 512 458 502 M392 522 C376 512 358 512 342 520" stroke="url(#gold)" stroke-width="9"/>
      <path d="M438 600 C418 558 402 524 366 498 M416 552 C424 528 440 512 458 502" stroke="#FBEBC0" stroke-width="2.4" opacity="0.7"/>
    </g>
    <!-- mane behind the head -->
    <g fill="none" stroke="#E2C27A" stroke-width="2.4" stroke-linecap="round">
      <path d="M420 640 C390 642 364 654 344 676"/>
      <path d="M416 652 C388 660 368 676 356 700"/>
      <path d="M424 626 C394 622 368 628 346 644"/>
      <path d="M430 664 C406 676 392 694 388 716"/>
    </g>
    <!-- ear -->
    <path d="M426 616 C400 594 368 586 344 592 C364 612 392 628 420 634 Z" fill="url(#jade)" stroke="#3E6B59" stroke-width="2.2" stroke-linejoin="round"/>
    <path d="M418 618 C398 604 376 598 360 598 C376 612 396 622 414 626 Z" fill="#E9C9B8"/>
    <!-- skull and snout -->
    <path d="M398 636 C398 596 440 578 482 588 C505 594 520 604 536 616 C556 622 578 630 588 646 C596 660 588 677 566 679 C522 684 470 686 430 680 C406 676 398 658 398 636 Z" fill="url(#jade)" stroke="#3E6B59" stroke-width="2.5" stroke-linejoin="round"/>
    <path d="M432 680 C472 686 522 684 566 679 C553 690 512 696 472 695 C452 694 440 690 432 680 Z" fill="url(#ivory)" stroke="#3E6B59" stroke-width="2"/>
    <path d="M456 612 Q482 600 510 614" fill="none" stroke="#3E6B59" stroke-width="2.2" stroke-linecap="round"/>
    <path d="M520 612 C540 620 560 626 576 636" fill="none" stroke="#6F9A84" stroke-width="1.6" stroke-linecap="round"/>
    <!-- closed eye -->
    <path d="M462 628 Q482 642 504 630" fill="none" stroke="#24423A" stroke-width="3.2" stroke-linecap="round"/>
    <path d="M470 636 L466 644 M480 639 L478 648 M491 638 L492 647" stroke="#24423A" stroke-width="1.8" stroke-linecap="round"/>
    <ellipse cx="486" cy="656" rx="18" ry="7" fill="#E6A8A0" opacity="0.35"/>
    <path d="M572 650 q5 -4 9 0" fill="none" stroke="#24423A" stroke-width="2.2" stroke-linecap="round"/>
    <path d="M528 672 Q548 678 568 671" fill="none" stroke="#3E6B59" stroke-width="2" stroke-linecap="round"/>
  </g>
  <!-- whiskers -->
  <g transform="translate(452 650) scale(1.38) translate(-452 -650)" fill="none" stroke="url(#gold)" stroke-linecap="round">
    <path d="M572 660 C612 690 640 652 690 676 C716 690 736 694 760 680" stroke-width="2.6"/>
    <path d="M566 668 C590 712 566 748 600 780 C612 792 628 796 644 790" stroke-width="2.6"/>
  </g>
</svg>
'''

with open(OUT, "w") as fh:
    fh.write(svg)
print("wrote", OUT)
