{
  # NixOS prototype of the cmux mobile target — a reproducible VM with GNOME 50
  # and gnome-remote-desktop 50.2 (touch via RDPEI), to compare against the
  # Ubuntu 26.04 harness (../). The whole system — GNOME, grd, Swift toolchain,
  # every lib — is pinned by flake.lock, which is the point: the version-matching
  # pain we fought across Fedora/Debian/Ubuntu becomes one lockfile.
  description = "cmux mobile NixOS prototype VM (GNOME 50 + gnome-remote-desktop 50.2)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixos-generators }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      packages.${system} = {
        # Bootable qcow2 for libvirt:  nix build .#qcow
        qcow = nixos-generators.nixosGenerate {
          inherit system;
          modules = [ ./configuration.nix ];
          format = "qcow";
        };

        # Runtime ICU soname-collision fix (see icu-fix.nix for the full why).
        # Swift Foundation's darwin.ICU (unsuffixed C symbols) and WebKit/GTK's
        # icu4c-78 (suffixed) both claim soname libicuuc.so.78 and are symbol-
        # disjoint, so cmux-adw BUILDS but crashes at startup
        # (libicuio.so.78: undefined symbol: ucnv_close). This derivation ships
        # private soname-renamed copies; prepend its /lib to LD_LIBRARY_PATH
        # when RUNNING cmux-adw. Tiny (~62 MB), no toolchain/WebKit rebuild.
        #   nix build .#icuFix
        icuFix = import ./icu-fix.nix { inherit pkgs; };
      };

      # The system itself (for nixos-rebuild / inspection).
      nixosConfigurations.cmux-nixos = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [ ./configuration.nix ];
      };

      # A dev shell that builds cmux-adw with a pinned Swift + the matching GTK
      # stack. Verified 2026-11-05: produces the cmux-adw binary. Two Nix-only
      # build details, both set up here, because adwaita-swift's C shim targets
      # carry no pkg-config metadata (so on Nix neither headers nor link libs
      # are found automatically):
      #   - CPATH for the C module includes
      #   - CMUX_NIX_LDFLAGS (-Xlinker …) for the link stage
      # Build with:  cmux-adw-build   (wrapper on PATH), or
      #   swift build --product cmux-adw $CMUX_NIX_LDFLAGS
      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          swift swiftpm pkg-config
          gtk4 libadwaita vte-gtk4 webkitgtk_6_0 glib
          (writeShellScriptBin "cmux-adw-build" ''
            cd "''${CMUX_LINUX_DIR:-$PWD}"
            exec swift build --product cmux-adw $CMUX_NIX_LDFLAGS "$@"
          '')
          # Run the built cmux-adw WITH the ICU fix on the library path. Without
          # it the binary crashes at startup on the Foundation-vs-WebKit ICU
          # soname collision (see icu-fix.nix). Use this, not the bare binary.
          (writeShellScriptBin "cmux-adw-run" ''
            cd "''${CMUX_LINUX_DIR:-$PWD}"
            export LD_LIBRARY_PATH="${self.packages.${system}.icuFix}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
            exec .build/debug/cmux-adw "$@"
          '')
        ];
        shellHook = ''
          export CPATH=$(pkg-config --cflags-only-I libadwaita-1 vte-2.91-gtk4 webkitgtk-6.0 gtk4 \
            | tr ' ' '\n' | sed 's/^-I//' | grep . | paste -sd:)
          export CMUX_NIX_LDFLAGS=$(pkg-config --libs gtk4 libadwaita-1 vte-2.91-gtk4 webkitgtk-6.0 \
            gio-2.0 gobject-2.0 glib-2.0 | tr ' ' '\n' | grep -E '^-[lL]' | sed 's/^/-Xlinker /' | tr '\n' ' ')
          echo "cmux-adw nix dev shell: Swift $(swift --version 2>/dev/null | grep -oE '[0-9]+\.[0-9.]+' | head -1), run cmux-adw-build in linux/"
        '';
      };

      # Report the pinned grd/GNOME version:  nix eval .#grdVersion
      grdVersion = pkgs.gnome-remote-desktop.version;
    };
}
