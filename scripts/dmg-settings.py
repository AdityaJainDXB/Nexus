# dmgbuild settings for Nexus (no Finder scripting required)
import os
app = defines.get("app", "dist/Nexus.app")
bg = defines.get("background", "dist/background.tiff")
volume_name = "Nexus"
format = "ULFO"
filesystem = "APFS"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = "Resources/AppIcon.icns"
badge_icon = None
background = bg
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
window_rect = ((200, 120), (660, 442))
default_view = "icon-view"
icon_size = 108
text_size = 13
icon_locations = {"Nexus.app": (170, 205), "Applications": (490, 205)}
arrange_by = None
