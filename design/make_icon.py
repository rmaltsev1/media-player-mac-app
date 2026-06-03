"""Generate the RezkaPlayer 1024x1024 app icon master (deterministic, local)."""
from PIL import Image, ImageDraw

SIZE = 1024
RADIUS = 180

# Colors
TOP_LEFT = (0x1B, 0x1E, 0x2B)   # deep slate
BOT_RIGHT = (0xE1, 0x1D, 0x2A)  # crimson


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def make_gradient(size, c0, c1):
    """Diagonal gradient: top-left -> bottom-right."""
    grad = Image.new("RGB", (size, size))
    px = grad.load()
    max_d = (size - 1) * 2
    for y in range(size):
        for x in range(size):
            t = (x + y) / max_d
            px[x, y] = lerp(c0, c1, t)
    return grad


def main():
    # Supersample for crisp edges.
    ss = 2
    s = SIZE * ss
    r = RADIUS * ss

    # Gradient at full resolution (build at base size then resize up for speed).
    grad = make_gradient(SIZE, TOP_LEFT, BOT_RIGHT).resize((s, s), Image.BILINEAR).convert("RGBA")

    # Rounded-rect mask.
    mask = Image.new("L", (s, s), 0)
    md = ImageDraw.Draw(mask)
    md.rounded_rectangle([0, 0, s - 1, s - 1], radius=r, fill=255)

    base = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    base.paste(grad, (0, 0), mask)

    # Subtle translucent white circle behind the triangle.
    overlay = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    od = ImageDraw.Draw(overlay)
    cx = cy = s / 2
    circle_r = s * 0.30
    od.ellipse(
        [cx - circle_r, cy - circle_r, cx + circle_r, cy + circle_r],
        fill=(255, 255, 255, 28),
    )

    # White play triangle, ~38% of canvas width, pointing right, optically centered.
    tw = s * 0.38            # triangle width
    th = tw * 1.12           # triangle height (slightly taller for balance)
    # Optical centering: shift right a touch so it looks centered inside the circle.
    off_x = s * 0.022
    left = cx - tw / 2 + off_x
    right = cx + tw / 2 + off_x
    top = cy - th / 2
    bottom = cy + th / 2
    od.polygon(
        [(left, top), (right, cy), (left, bottom)],
        fill=(255, 255, 255, 235),  # ~92% opacity
    )

    base = Image.alpha_composite(base, overlay)

    # Downsample to final size.
    icon = base.resize((SIZE, SIZE), Image.LANCZOS)
    icon.save("design/icon-1024.png")
    assert icon.size == (SIZE, SIZE), icon.size
    assert icon.mode == "RGBA", icon.mode
    print("OK", icon.size, icon.mode)


if __name__ == "__main__":
    main()
