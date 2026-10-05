# The look of Grab's disk image window, for dmgbuild (used by scripts/release.sh).
#
#   dmgbuild -s packaging/dmg_settings.py -D app=build/Grab.app -D background=… "Grab 1.4.0" Grab-1.4.0.dmg
#
# Icon spots must match the arrow and light pools drawn by scripts/make_dmg_background.swift.
import os.path

app = defines["app"]  # noqa: F821 (provided by dmgbuild)
app_name = os.path.basename(app)

format = "UDZO"
compression_level = 9
filesystem = "HFS+"

files = [app]
symlinks = {"Applications": "/Applications"}

icon = defines.get("icon")  # noqa: F821
background = defines["background"]  # noqa: F821

# The window's outer size: title bar, 460 points of background, and room for Finder's
# path and status bars, which some people keep on everywhere (they'd hide 60 points).
window_rect = ((200, 120), (660, 488))
default_view = "icon-view"
show_toolbar = False
show_status_bar = False
show_pathbar = False
show_sidebar = False
show_tab_view = False
show_icon_preview = False
show_item_info = False
include_icon_view_settings = True
include_list_view_settings = False

icon_size = 128
text_size = 13
label_pos = "bottom"
arrange_by = None
icon_locations = {
    app_name: (165, 196),
    "Applications": (495, 196),
}
