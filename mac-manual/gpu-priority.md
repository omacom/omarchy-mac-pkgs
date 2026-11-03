# Compositor GPU priority

Omarchy Mac grants the packaged `/usr/bin/Hyprland` `cap_sys_nice=ep` during system setup and restores it after upgrades with a pacman hook. On an existing installation, activate a newly introduced hook once with `sudo /usr/lib/omarchy-mac/hyprland-capabilities`; verify with `getcap /usr/bin/Hyprland`. It takes effect when the compositor next starts. No session restart is performed by the helper.

The privilege permits HIGH GPU queues on supported kernels and also lets Hyprland request realtime CPU scheduling. It does not enable realtime GPU queues or GPU firmware preemption. See `omarchy-mac/README.md` for the version-specific behavior and first-install caveat. To opt out persistently, shadow `90-omarchy-mac-hyprland-capabilities.hook` in `/etc/pacman.d/hooks/` with a symlink to `/dev/null`, then run `sudo setcap -r /usr/bin/Hyprland`; later system setup grants it again.
