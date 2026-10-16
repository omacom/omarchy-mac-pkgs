# Whether GRUB is kept: omarchy-mac-boot-update regenerates GRUB's image only
# where GRUB's own tools exist, because update-grub fails without grub-probe.
# omarchy-mac-boot-update and provision.sh decide this one thing here, and
# nowhere else. OMARCHY_MAC_BOOT_UPDATE_GRUB is not part of it: it suppresses
# a rebuild, it does not stop GRUB from booting the image already there.
grub_tools_present() {
  omarchy-cmd-present grub-probe && omarchy-cmd-present grub-mkconfig
}
