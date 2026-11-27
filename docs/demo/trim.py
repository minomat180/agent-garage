"""Shorten the vhs recording: frames that differ from the previous one only by
a blinking cursor or a typed character are merged, and every pause is capped,
so waiting for the in-bay checks does not take half the GIF.

    python3 docs/demo/trim.py docs/demo/garage.gif docs/demo/garage.gif 2500
"""
import sys

from PIL import Image, ImageChops, ImageSequence

src, dst, cap = sys.argv[1], sys.argv[2], int(sys.argv[3])
frames, durs, prev = [], [], None
with Image.open(src) as im:
    for f in ImageSequence.Iterator(im):
        rgb = f.convert("RGB")
        d = f.info.get("duration", 40)
        if prev is not None:
            box = ImageChops.difference(rgb, prev).getbbox()
            if box is None or (box[2] - box[0]) * (box[3] - box[1]) < 600:
                durs[-1] = min(durs[-1] + d, cap)
                continue
        frames.append(rgb)
        durs.append(min(d, cap))
        prev = rgb
durs[-1] = 6000  # hold the final screen
pal = [fr.quantize(colors=64, method=Image.Quantize.MEDIANCUT) for fr in frames]
pal[0].save(dst, save_all=True, append_images=pal[1:], duration=durs, loop=0, disposal=1)
print(f"{len(frames)} frames, {sum(durs) / 1000:.1f} s")
