# cmux-adw ICU soname-collision fix (runtime, no toolchain rebuild).
#
# Root cause: Swift Foundation links darwin.ICU — Apple's ICU built with
# --disable-renaming, so its C symbols are UNSUFFIXED (ucnv_close) and it ships
# the GENERIC soname libicuuc.so.78. WebKit/GTK link the normal icu4c-78, whose
# C symbols are SUFFIXED (ucnv_close_78) under the SAME soname libicuuc.so.78.
# One soname, two symbol-disjoint libraries → whichever loads first, the other
# consumer's lookups fail (observed: libicuio.so.78: undefined symbol ucnv_close).
# On Ubuntu/Fedora this never happens: one system ICU serves both.
#
# Fix principle: the two symbol sets never actually overlap — only the soname
# collides. So give the darwin side a PRIVATE soname and the collision is gone,
# with no rebuild of the Swift toolchain or WebKit. We:
#   1. copy the 4 colliding darwin ICU libs, rename file+soname with a _cmux
#      suffix (C symbols stay unsuffixed), and repoint their cross-deps (abs);
#   2. copy darwin's libicucore.so (the thin forwarder Foundation needs) and
#      repoint it at the renamed siblings (abs);
#   3. copy the 4 Foundation libs and repoint their absolute NEEDED on
#      darwin's libicucore.so at our private copy.
# A launcher then prepends this lib dir to LD_LIBRARY_PATH; the patched
# Foundation copies win over the toolchain's (soname + LD_LIBRARY_PATH precedes
# RUNPATH), pull the private renamed ICU, while WebKit/GTK keep icu4c-78.
{ pkgs }:
let
  lib = pkgs.lib;
  icu = pkgs.darwin.ICU;   # unsuffixed Apple ICU that Swift Foundation uses
  swift = pkgs.swift;      # provides libFoundation*.so in $out/lib
  sfx = "_cmux";
  collide = [ "libicuuc" "libicui18n" "libicuio" "libicudata" ];
  foundation = [ "libFoundation.so" "libFoundationInternationalization.so"
                 "libFoundationNetworking.so" "libFoundationXML.so" ];
in
pkgs.runCommand "cmux-icu-fix" { nativeBuildInputs = [ pkgs.patchelf ]; } ''
  mkdir -p $out/lib
  cp -L ${icu}/lib/libicucore.so $out/lib/libicucore.so

  # 1. private, soname-renamed copies of the colliding darwin ICU libs
  for base in ${lib.concatStringsSep " " collide}; do
    cp -L ${icu}/lib/$base.so.78 $out/lib/''${base}${sfx}.so.78
    chmod u+w $out/lib/''${base}${sfx}.so.78
    patchelf --set-soname ''${base}${sfx}.so.78 $out/lib/''${base}${sfx}.so.78
  done

  # 2. repoint every cross-dependency on the generic sonames to the private
  #    copies, by ABSOLUTE path (a NEEDED containing '/' is used as a path, so
  #    no RUNPATH juggling is required). Applies to the renamed libs AND to
  #    libicucore.so (the forwarder Foundation loads).
  chmod u+w $out/lib/libicucore.so
  for f in $out/lib/*.so $out/lib/*.so.78; do
    for base in ${lib.concatStringsSep " " collide}; do
      patchelf --replace-needed $base.so.78 $out/lib/''${base}${sfx}.so.78 "$f" 2>/dev/null || true
    done
  done

  # 3. patched Foundation libs: their absolute NEEDED on darwin's libicucore.so
  #    is redirected to our private libicucore.so (which now pulls the renamed
  #    ICU). Everything else in these libs keeps its original RUNPATH.
  for fl in ${lib.concatStringsSep " " foundation}; do
    [ -e ${swift}/lib/$fl ] || continue
    cp -L ${swift}/lib/$fl $out/lib/$fl
    chmod u+w $out/lib/$fl
    patchelf --replace-needed ${icu}/lib/libicucore.so $out/lib/libicucore.so $out/lib/$fl
  done
''
