"""
scripts/dmg_settings.py
dmgbuild configuration for Chicken Fork's macOS installer DMG.
"""

import os

REPO_ROOT = defines["repo_root"]
application = defines["app_path"]
app_name = os.path.basename(application.rstrip("/"))

format = "UDZO"
compression_level = 9

icon = os.path.join(REPO_ROOT, "cotvnc", "Resources", "icon.icns")
background = os.path.join(REPO_ROOT, "cotvnc", "Resources", "dmg", "background.tiff")

window_rect = ((200, 200), (600, 360))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

icon_size = 128
text_size = 14

files = [application]
symlinks = {"Applications": "/Applications"}
icon_locations = {
    app_name: (165, 195),
    "Applications": (435, 195),
}
