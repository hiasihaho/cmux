{ config, pkgs, lib, ... }:
{
  # ---- base VM ----
  # nixos-generators' qcow format supplies the disk/bootloader wiring; keep
  # growable root and a serial console for libvirt.
  boot.growPartition = true;
  boot.kernelParams = [ "console=ttyS0" ];
  networking.hostName = "cmux-nixos";
  networking.networkmanager.enable = true;
  time.timeZone = "Europe/Vienna";

  # ---- GNOME 50 + GDM + remote desktop (grd 50.2 → touch via RDPEI) ----
  services.xserver.enable = true;
  services.displayManager.gdm.enable = true;
  services.desktopManager.gnome.enable = true;
  # The system RDP service (the headless single-user session is wired by hand
  # in a follow-up, mirroring what we did on Ubuntu).
  services.gnome.gnome-remote-desktop.enable = true;

  # Minimal GNOME, adminvm "no extras" shape.
  environment.gnome.excludePackages = with pkgs; [
    gnome-tour epiphany geary gnome-music totem gnome-maps gnome-weather
    gnome-contacts simple-scan yelp
  ];

  # ---- users ----
  users.users.mobile = {
    isNormalUser = true;
    password = "mobile";                 # DEV-ONLY, LAN-only VM
    extraGroups = [ "video" "render" ];
    linger = true;                       # user manager stays up for the headless session
  };
  users.users.admin = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJjiYUfqt7LfavY0n06SUjnxyeHK7XSgkKd4Cd1ZVP5T adminvm-test"
    ];
  };
  security.sudo.wheelNeedsPassword = false;

  services.openssh.enable = true;
  services.openssh.settings.PermitRootLogin = "no";

  # Native cmux-adw build happens in the VM (like the Ubuntu path) OR via the
  # flake dev shell — ship the toolchain + the GTK stack so `swift build` works.
  environment.systemPackages = with pkgs; [
    git rsync
    swift swiftpm pkg-config
    gtk4 libadwaita vte-gtk4 webkitgtk_6_0 glib
  ];

  # Flatpak available too (the app's eventual delivery is host-independent).
  services.flatpak.enable = true;

  system.stateVersion = "25.11";
}
