#!/usr/bin/env python3
"""Refuse to build anything that does not carry the HamDeck mark.

⚠️ THIS EXISTS BECAUSE THE APP SHIPPED WITH FLUTTER'S OWN LOGO. Every Windows
build up to and including the one installed on the test box used the stock
`app_icon.ico` that `flutter create` writes - so the taskbar, the Start menu and
Add/Remove Programs all showed somebody else's product, and the installer had no
icon at all. The .desktop file on Linux named an icon that nothing installed.
It was asked for more than once and missed every time, which is precisely the
case for a check that refuses rather than a note that reminds.

Run by tools/preflight.sh. Exit 1 means do not build.
"""
import hashlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BRAND = ROOT / "packaging" / "branding"
problems = []


def digest(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def same(a: Path, b: Path, what: str) -> None:
    if not a.exists():
        problems.append(f"{what}: missing {a.relative_to(ROOT)}")
    elif not b.exists():
        problems.append(f"{what}: missing brand source {b.relative_to(ROOT)}")
    elif digest(a) != digest(b):
        problems.append(
            f"{what}: {a.relative_to(ROOT)} is not the shipped mark "
            f"({b.relative_to(ROOT)}) - regenerate it from hamdeck-site/brand"
        )


# ⚠️ The exact bytes flutter create writes. Matching this is not "an icon is
# present", it is "the icon is a stranger's logo", which is the failure seen.
FLUTTER_DEFAULT_SHA = None
win_icon = ROOT / "client/windows/runner/resources/app_icon.ico"
same(win_icon, BRAND / "hamdeck.ico", "Windows app icon")

# The installer itself
iss = ROOT / "packaging/hamdeck-panel.iss"
text = iss.read_text() if iss.exists() else ""
for directive in ("SetupIconFile", "WizardSmallImageFile"):
    m = re.search(rf"^{directive}=(.+)$", text, re.M)
    if not m:
        problems.append(f"installer: {directive} is not set in {iss.name}")
        continue
    ref = (ROOT / "packaging" / m.group(1).strip().replace("\\", "/"))
    if not ref.exists():
        problems.append(f"installer: {directive} points at a missing file: {m.group(1).strip()}")

# macOS
for s in (16, 32, 64, 128, 256, 512, 1024):
    same(
        ROOT / f"client/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_{s}.png",
        Path("/home/ubuntu/hamdeck-site/brand") / f"mac-{s}.png",
        f"macOS app icon {s}px",
    ) if (Path("/home/ubuntu/hamdeck-site/brand") / f"mac-{s}.png").exists() else None

# Linux: the .desktop names an icon, so an icon file has to be installed.
deb = (ROOT / "packaging/build-deb.sh").read_text()
icon_name = re.search(r"^Icon=(.+)$", deb, re.M)
if icon_name:
    name = icon_name.group(1).strip()
    if f"/apps/{name}.png" not in deb:
        problems.append(
            f"Linux: the .desktop says Icon={name} but build-deb.sh installs no "
            f"usr/share/icons/hicolor/*/apps/{name}.png"
        )
missing = [s for s in (16, 24, 32, 48, 64, 128, 256, 512)
           if not (BRAND / "hicolor" / f"{s}.png").exists()]
if missing:
    problems.append(f"Linux: missing launcher icon sizes {missing} in packaging/branding/hicolor")

# ⚠️ The window title is branding too. "hamdeck_panel" is the build target's
# name, and it is what an operator saw in the title bar and in alt-tab.
for src in ("client/windows/runner/main.cpp", "client/linux/runner/my_application.cc"):
    p = ROOT / src
    if p.exists() and '"hamdeck_panel"' in p.read_text():
        problems.append(f"{src}: the window title is still the build target name, not 'HamDeck Panel'")

if problems:
    print("BRANDING IS NOT COMPLETE - refusing to build:")
    for p in problems:
        print(f"  - {p}")
    sys.exit(1)
print("branding: the mark is on the app, the installer, the shortcuts and the launcher")
