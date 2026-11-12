"""Generates AppIcon-dragon-chest.svg: a winged crimson dragon perched on a treasure chest.

The tail is built from a Catmull-Rom centerline with a width profile so its
belly stripe, plates and dorsal spikes follow the same curve.
Run: python3 make_dragon_chest_icon.py
"""
import math
import os

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "AppIcon-dragon-chest.svg")
CHEST_CENTER = (512, 790)

TAIL = [(392, 596), (322, 648), (280, 742), (298, 852), (392, 930), (545, 958),
        (690, 936), (772, 882), (806, 826)]


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


def tail_width(u):
    return 8 + 58 * (1 - u) ** 1.15


line = catmull_rom(TAIL)
seg = [0.0]
for a, b in zip(line, line[1:]):
    seg.append(seg[-1] + math.dist(a, b))
total = seg[-1]

frames = []
for i, p in enumerate(line):
    a = line[max(i - 1, 0)]
    b = line[min(i + 1, len(line) - 1)]
    tx, ty = b[0] - a[0], b[1] - a[1]
    n = math.hypot(tx, ty) or 1
    tx, ty = tx / n, ty / n
    nx, ny = -ty, tx
    if (p[0] - CHEST_CENTER[0]) * nx + (p[1] - CHEST_CENTER[1]) * ny < 0:
        nx, ny = -nx, -ny
    u = seg[i] / total
    frames.append((p, (tx, ty), (nx, ny), tail_width(u), u))


def off(f, k):
    (px, py), _, (nx, ny), _, _ = f
    return (px + nx * k, py + ny * k)


def poly(points):
    return "M" + " L".join(f"{x:.1f} {y:.1f}" for x, y in points) + " Z"


tail_d = poly([off(f, f[3] / 2) for f in frames] + [off(f, -f[3] / 2) for f in frames][::-1])
belly = [f for f in frames if f[4] < 0.97]
tail_belly_d = poly([off(f, -f[3] / 2) for f in belly] + [off(f, -f[3] / 2 + f[3] * 0.42) for f in belly][::-1])

plates, spikes, scales = [], [], []
step = total / 34
nxt = step
for f, s in zip(frames, seg):
    if f[4] > 0.95:
        break
    if s >= nxt:
        a = off(f, -f[3] / 2 + 1)
        b = off(f, -f[3] / 2 + f[3] * 0.4)
        plates.append(f"M{a[0]:.1f} {a[1]:.1f} L{b[0]:.1f} {b[1]:.1f}")
        nxt += step

step = total / 26
nxt = step * 0.6
for f, s in zip(frames, seg):
    if f[4] > 0.93:
        break
    if s >= nxt:
        (px, py), (tx, ty), (nx, ny), w, u = f
        base = (px + nx * w * 0.45, py + ny * w * 0.45)
        h = 26 * (1 - u * 0.7)
        half = 11 * (1 - u * 0.5)
        b0 = (base[0] + tx * half, base[1] + ty * half)
        b1 = (base[0] - tx * half, base[1] - ty * half)
        tip = (base[0] + nx * h - tx * h * 0.6, base[1] + ny * h - ty * h * 0.6)
        spikes.append(f"M{b0[0]:.1f} {b0[1]:.1f} L{tip[0]:.1f} {tip[1]:.1f} L{b1[0]:.1f} {b1[1]:.1f} Z")
        nxt += step

step = total / 22
nxt = step * 0.8
for f, s in zip(frames, seg):
    if f[4] > 0.85:
        break
    if s >= nxt:
        (px, py), (tx, ty), (nx, ny), w, _ = f
        k = w * 0.18
        r = w * 0.12
        p0 = (px + nx * (k - r), py + ny * (k - r))
        p2 = (px + nx * (k + r), py + ny * (k + r))
        c = (px + nx * k - tx * r * 1.4, py + ny * k - ty * r * 1.4)
        scales.append(f"M{p0[0]:.1f} {p0[1]:.1f} Q{c[0]:.1f} {c[1]:.1f} {p2[0]:.1f} {p2[1]:.1f}")
        nxt += step

# arrowhead tail tip, oriented along the end of the tail
(ex, ey), (tx, ty), (nx, ny), _, _ = frames[-1]


def at(along, across):
    return (ex + tx * along + nx * across, ey + ty * along + ny * across)


spade_pts = [at(-6, 6), at(-20, 30), at(40, 0), at(-20, -30), at(-6, -6)]
spade_d = poly(spade_pts)

# scale marks on the torso, haunch and neck
SCALE_SPOTS = [(470, 470), (500, 500), (452, 520), (430, 470), (520, 450), (540, 380),
               (530, 330), (400, 560), (440, 590), (480, 560), (420, 520), (560, 300)]
torso_scales = " ".join(f"M{x - 10} {y} Q{x} {y + 10} {x + 10} {y} M{x - 6} {y + 4} Q{x} {y - 6} {x + 4} {y + 8}"
                        for x, y in SCALE_SPOTS)

svg = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <defs>
    <radialGradient id="bg" cx="50%" cy="48%" r="72%">
      <stop offset="0" stop-color="#2E1E28"/>
      <stop offset="0.6" stop-color="#1A1117"/>
      <stop offset="1" stop-color="#0C080B"/>
    </radialGradient>
    <radialGradient id="halo" cx="50%" cy="70%" r="38%">
      <stop offset="0" stop-color="#F2C46A" stop-opacity="0.22"/>
      <stop offset="1" stop-color="#F2C46A" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="hide" x1="0.2" y1="0" x2="0.8" y2="1">
      <stop offset="0" stop-color="#E5484A"/>
      <stop offset="0.6" stop-color="#C9313A"/>
      <stop offset="1" stop-color="#A12431"/>
    </linearGradient>
    <linearGradient id="membrane" x1="1" y1="1" x2="0" y2="0">
      <stop offset="0" stop-color="#E0574D"/>
      <stop offset="1" stop-color="#F7A27D"/>
    </linearGradient>
    <linearGradient id="belly" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#FAD3A6"/>
      <stop offset="1" stop-color="#EDAE7E"/>
    </linearGradient>
    <linearGradient id="wood" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#6E3E2A"/>
      <stop offset="1" stop-color="#3E2218"/>
    </linearGradient>
    <linearGradient id="lid" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#A2654A"/>
      <stop offset="1" stop-color="#6E3D2B"/>
    </linearGradient>
    <linearGradient id="gold" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#F8E0A2"/>
      <stop offset="0.5" stop-color="#D9AE5C"/>
      <stop offset="1" stop-color="#A97C33"/>
    </linearGradient>
    <radialGradient id="seamGlow" cx="50%" cy="50%" r="50%">
      <stop offset="0" stop-color="#FFE7A0" stop-opacity="0.9"/>
      <stop offset="1" stop-color="#FFC861" stop-opacity="0"/>
    </radialGradient>
    <!-- print-like grain over flat color -->
    <filter id="grain" filterUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024">
      <feTurbulence type="fractalNoise" baseFrequency="0.85" numOctaves="2" seed="7" result="n"/>
      <feColorMatrix in="n" type="matrix" values="0 0 0 0 0.25  0 0 0 0 0.05  0 0 0 0 0.08  0 0 0 -1.3 0.85" result="speck"/>
      <feComposite in="speck" in2="SourceGraphic" operator="atop"/>
    </filter>
    <filter id="shadow" filterUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024">
      <feGaussianBlur in="SourceAlpha" stdDeviation="12"/>
      <feOffset dy="10"/>
      <feColorMatrix type="matrix" values="0 0 0 0 0  0 0 0 0 0  0 0 0 0 0  0 0 0 0.6 0"/>
      <feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge>
    </filter>
  </defs>

  <rect width="1024" height="1024" fill="url(#bg)"/>
  <rect width="1024" height="1024" fill="url(#halo)"/>
  <circle cx="512" cy="520" r="452" fill="none" stroke="#D9AE5C" stroke-width="2.5" opacity="0.4"/>
  <circle cx="512" cy="520" r="438" fill="none" stroke="#D9AE5C" stroke-width="1" opacity="0.25"/>
  <g fill="#E9CB85" opacity="0.7">
    <path d="M168 330 l3 8 l8 3 l-8 3 l-3 8 l-3 -8 l-8 -3 l8 -3 Z"/>
    <path d="M876 420 l4 10 l10 4 l-10 4 l-4 10 l-4 -10 l-10 -4 l10 -4 Z"/>
    <path d="M820 200 l3 8 l8 3 l-8 3 l-3 8 l-3 -8 l-8 -3 l8 -3 Z"/>
  </g>

  <!-- far wing: peeks out behind the near one -->
  <g filter="url(#shadow)" transform="translate(96 -58) rotate(8 478 440)">
    <path d="M478 440 C440 360 410 300 372 248 C330 200 270 160 196 142
             C226 176 232 206 226 236 Q262 250 266 300
             C246 310 232 336 236 368 Q282 368 300 410
             C292 432 296 456 312 478 Q376 452 420 478 Z" fill="#8E2430"/>
    <g fill="none" stroke="#6E1C28" stroke-linecap="round">
      <path d="M480 446 C440 360 410 300 372 248" stroke-width="14"/>
      <path d="M372 248 C320 200 270 162 196 142" stroke-width="9"/>
      <path d="M372 250 C320 250 270 246 226 236" stroke-width="6"/>
      <path d="M372 252 C330 290 290 330 236 368" stroke-width="6"/>
    </g>
  </g>

  <!-- near wing -->
  <g filter="url(#shadow)">
    <path d="M478 440 C440 360 410 300 372 248 C330 200 270 160 196 142
             C226 176 232 206 226 236 Q262 250 266 300
             C246 310 232 336 236 368 Q282 368 300 410
             C292 432 296 456 312 478 Q376 452 420 478 Z" fill="url(#membrane)"/>
    <g fill="none" stroke="#B5283A" stroke-linecap="round">
      <path d="M480 446 C440 360 410 300 372 248" stroke-width="16"/>
      <path d="M372 248 C320 200 270 162 196 142" stroke-width="10"/>
      <path d="M372 250 C320 250 270 246 226 236" stroke-width="7"/>
      <path d="M372 252 C330 290 290 330 236 368" stroke-width="7"/>
      <path d="M374 254 C350 320 330 390 312 478" stroke-width="7"/>
    </g>
    <path d="M370 246 l-14 -22 l22 10 Z" fill="#F7DDB8"/>
  </g>

  <!-- treasure chest -->
  <g filter="url(#shadow)">
    <rect x="296" y="716" width="432" height="190" rx="10" fill="url(#wood)"/>
    <g stroke="#2E170F" stroke-width="2" opacity="0.6">
      <path d="M296 776 L728 776 M296 840 L728 840"/>
    </g>
    <!-- treasure spilling from the seam -->
    <ellipse cx="512" cy="712" rx="220" ry="26" fill="url(#seamGlow)"/>
    <path d="M300 718 L300 676 C300 628 364 606 512 606 C660 606 724 628 724 676 L724 718 Z" fill="url(#lid)"/>
    <path d="M312 664 C330 632 400 618 512 618 C624 618 694 632 712 664" fill="none" stroke="#C48A66" stroke-width="2" opacity="0.6"/>
    <!-- gold straps and corners -->
    <g fill="url(#gold)" stroke="#7A5420" stroke-width="2">
      <path d="M352 622 C356 620 370 616 380 614 L380 906 L352 906 Z"/>
      <path d="M672 622 C668 620 654 616 644 614 L644 906 L672 906 Z"/>
      <rect x="292" y="708" width="440" height="20" rx="4"/>
      <rect x="292" y="890" width="440" height="18" rx="4"/>
    </g>
    <g fill="#F3D68E">
      <circle cx="366" cy="760" r="4"/><circle cx="366" cy="820" r="4"/><circle cx="366" cy="872" r="4"/>
      <circle cx="658" cy="760" r="4"/><circle cx="658" cy="820" r="4"/><circle cx="658" cy="872" r="4"/>
    </g>
    <!-- lock plate with a bookmark-shaped keyhole -->
    <path d="M478 722 L546 722 L546 790 C546 812 530 826 512 834 C494 826 478 812 478 790 Z" fill="url(#gold)" stroke="#7A5420" stroke-width="2"/>
    <path d="M502 746 L522 746 L522 790 L512 781 L502 790 Z" fill="#2A1510"/>
    <!-- a necklace and coins slipping out -->
    <path d="M420 722 C428 760 452 772 470 766" fill="none" stroke="#F3D68E" stroke-width="4" stroke-dasharray="1 7" stroke-linecap="round"/>
    <circle cx="471" cy="768" r="8" fill="#58B6C9" stroke="#F3D68E" stroke-width="2.5"/>
    <g fill="url(#gold)" stroke="#7A5420" stroke-width="1.6">
      <ellipse cx="590" cy="716" rx="20" ry="7"/>
      <ellipse cx="616" cy="718" rx="18" ry="6"/>
      <ellipse cx="440" cy="714" rx="16" ry="6"/>
    </g>
  </g>

  <!-- tail -->
  <g filter="url(#shadow)">
    <path d="{tail_d}" fill="url(#hide)"/>
    <path d="{' '.join(spikes)}" fill="#B5283A"/>
    <path d="{spade_d}" fill="#C9313A"/>
  </g>
  <path d="{tail_belly_d}" fill="url(#belly)"/>
  <path d="{' '.join(plates)}" fill="none" stroke="#C9313A" stroke-width="1.6" opacity="0.55"/>
  <path d="{' '.join(scales)}" fill="none" stroke="#7E2347" stroke-width="2.2" stroke-linecap="round" opacity="0.6"/>

  <!-- body -->
  <g filter="url(#shadow)">
    <!-- dorsal spikes on neck and back -->
    <g fill="#B5283A">
      <path d="M548 236 L528 214 L556 222 Z"/>
      <path d="M538 272 L510 258 L542 252 Z"/>
      <path d="M526 310 L496 302 L526 290 Z"/>
      <path d="M514 350 L484 348 L510 332 Z"/>
      <path d="M498 392 L468 396 L490 374 Z"/>
      <path d="M462 428 L432 438 L448 412 Z"/>
      <path d="M424 462 L394 476 L406 448 Z"/>
      <path d="M396 506 L366 522 L376 492 Z"/>
      <path d="M380 552 L352 570 L358 538 Z"/>
    </g>
    <!-- neck -->
    <path d="M500 410 C512 350 520 300 556 258 L616 284 C588 318 598 362 572 414 Z" fill="url(#hide)"/>
    <!-- torso -->
    <path d="M505 392 C470 428 420 462 396 520 C372 576 372 610 392 620 L588 620 C612 590 628 540 618 490 C608 448 584 420 566 400 Z" fill="url(#hide)"/>
    <!-- haunch and hind foot -->
    <path d="M370 560 C372 500 430 476 480 490 C530 506 548 560 530 600 C516 626 470 630 420 626 C390 622 370 600 370 560 Z" fill="#B82B37"/>
    <path d="M456 600 C480 596 520 600 546 612 C552 620 548 628 540 628 L456 628 Z" fill="#B82B37"/>
    <g fill="#F7DDB8"><path d="M548 616 l12 4 l-10 6 Z"/><path d="M536 622 l12 6 l-12 4 Z"/></g>
    <path d="M396 556 C410 520 450 506 486 520" fill="none" stroke="#D9404A" stroke-width="3" opacity="0.7"/>
  </g>
  <!-- belly plates up the chest and throat -->
  <path d="M572 414 C598 362 588 318 616 284 L632 292 C610 326 624 372 600 420 C628 466 632 540 604 618 L578 618 C598 548 594 466 572 414 Z" fill="url(#belly)"/>
  <path d="M590 330 L624 314 M584 362 L620 352 M584 394 L614 392 M590 428 L616 436 M596 466 L620 476 M598 506 L622 514 M598 546 L620 554 M594 584 L614 590" fill="none" stroke="#C9313A" stroke-width="1.6" opacity="0.55"/>
  <path d="{torso_scales}" fill="none" stroke="#7E2347" stroke-width="2.4" stroke-linecap="round" opacity="0.55"/>

  <!-- front leg resting on the lid -->
  <g filter="url(#shadow)">
    <path d="M560 470 C600 480 616 520 612 560 C610 584 616 598 632 606 C642 612 640 622 628 622 L590 622 C584 600 578 570 566 548 C554 528 548 500 560 470 Z" fill="url(#hide)"/>
  </g>
  <g fill="#F7DDB8"><path d="M628 612 l14 2 l-10 8 Z"/><path d="M614 616 l14 4 l-12 6 Z"/></g>

  <!-- head -->
  <g filter="url(#shadow)">
    <!-- horns -->
    <path d="M578 218 C560 196 532 178 498 172 C520 188 538 206 552 230 Z" fill="#F7DDB8"/>
    <path d="M600 212 C590 186 570 162 540 148 C558 170 570 192 576 218 Z" fill="#EBC99A"/>
    <path d="M554 264 C558 226 588 204 624 206 C650 208 670 220 692 226 C714 230 726 242 720 256 C714 268 694 272 670 272 C650 274 632 282 614 290 C590 296 560 290 554 264 Z" fill="url(#hide)"/>
    <!-- cheek frill -->
    <path d="M572 284 L556 306 L580 296 L578 318 L596 296 Z" fill="#B5283A"/>
  </g>
  <path d="M640 272 C664 270 694 268 718 258" fill="none" stroke="#8E2430" stroke-width="2.4" stroke-linecap="round"/>
  <path d="M600 222 C614 212 636 212 650 220" fill="none" stroke="#8E2430" stroke-width="3" stroke-linecap="round"/>
  <!-- eye -->
  <path d="M606 238 Q626 222 646 236 Q626 248 606 238 Z" fill="#F4C452"/>
  <ellipse cx="628" cy="236" rx="4" ry="8" fill="#1A0E0E"/>
  <circle cx="632" cy="231" r="2.2" fill="#FFF6E0"/>
  <path d="M604 238 Q626 220 648 236" fill="none" stroke="#1A0E0E" stroke-width="2.4" stroke-linecap="round"/>
  <ellipse cx="706" cy="240" rx="4" ry="3" fill="#6E1C28"/>
  <path d="M600 256 Q610 250 622 256" fill="none" stroke="#7E2347" stroke-width="2.2" stroke-linecap="round" opacity="0.6"/>

  <!-- grain over everything printed -->
  <rect width="1024" height="1024" fill="#000" opacity="0" />
</svg>
'''

with open(OUT, "w") as fh:
    fh.write(svg)
print("wrote", OUT)
