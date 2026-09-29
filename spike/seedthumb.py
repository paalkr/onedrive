# Seed freedesktop thumbnails for files on the mount from a local rendering, without touching the mount's file content.
import sys, os, hashlib, subprocess, gi
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import GdkPixbuf
mount_dir, local_dir, tmp = sys.argv[1], sys.argv[2], sys.argv[3]
sizes = {"normal": 128, "large": 256, "x-large": 512, "xx-large": 1024}
for name in sorted(os.listdir(mount_dir)):
    mp = os.path.join(mount_dir, name); lp = os.path.join(local_dir, name)
    uri = "file://" + mp  # plain ASCII paths in this spike, no escaping needed
    mtime = str(int(os.stat(mp).st_mtime))  # stat only, no open
    h = hashlib.md5(uri.encode()).hexdigest()
    src = os.path.join(tmp, "src-" + name + ".png")
    if name.endswith(".pdf") or name.endswith(".webm"):
        # stand-in image: this spike tests cache lookup, not rendering quality
        GdkPixbuf.Pixbuf.new_from_file_at_size("/usr/share/backgrounds/Fuji_san_by_amaral.png", 1024, 1024).savev(src, "png", [], [])
    else:
        GdkPixbuf.Pixbuf.new_from_file_at_size(lp, 1024, 1024).savev(src, "png", [], [])
    for d, px in sizes.items():
        pb = GdkPixbuf.Pixbuf.new_from_file_at_size(src, px, px)
        os.makedirs(os.path.expanduser(f"~/.cache/thumbnails/{d}"), mode=0o700, exist_ok=True)
        out = os.path.expanduser(f"~/.cache/thumbnails/{d}/{h}.png")
        pb.savev(out, "png", ["tEXt::Thumb::URI", "tEXt::Thumb::MTime"], [uri, mtime])
    print(name, h)
