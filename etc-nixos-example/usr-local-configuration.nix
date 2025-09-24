{
  pkgs,
  lib,
  usr-local,
  host-info,
  hostname,
  CONTACT,
  DOWNDRAFT,
  POLLY,
  ...
}:

let

  usr-local-packages-data = import ./usr-local-packages-data.nix;

  rcopy = "cp --recursive --symbolic-link --one-file-system --update=all --remove-destination";
  link = "ln --no-dereference --symbolic --force";
  setfacl = "${pkgs.acl}/bin/setfacl";
  sed = "${pkgs.gnused}/bin/sed";
  find = "${pkgs.findutils}/bin/find";
  xargs = "${pkgs.findutils}/bin/xargs";
  tar = "${pkgs.gnutar}/bin/tar";
  btrfs = "${pkgs.btrfs-progs}/bin/btrfs";

  #
  # I am not sure the kernel’s overlay filesystem works with btrfs,
  # but fuse-overlayfs seems to work alright.
  #
  # Perhaps one could put the packages on any kind of filesystem
  # mounted via loopback device. Of course, a simple alternative is to
  # use a different volume entirely, a tmpfs for a copy of each
  # package, or a tmpfs of symlinks for each package. You can copy a
  # directory structure in symlinks using either GNU coreutils (with
  # ‘cp --recursive --symbolic-link’) or ‘make-toolchain-environment’
  # (https://github.com/chemoelectric-nixos/make-toolchain-environment).
  #
  fuse-overlayfs = "${pkgs.fuse-overlayfs}/bin/fuse-overlayfs";

  #
  # You can use either fusermount or ordinary umount to unmount the
  # FUSE filesystem.
  #
  fusermount = "${pkgs.fuse}/bin/fusermount";

  ul = "/usr/local";
  coreDir = "/mount/usr-local/core/the-core";
  packagesDir = "/mount/usr-local/packages";

  glibc = "${pkgs.glibc.out}";
  glibc-static = "${pkgs.glibc.static}";
  glibc-dev = "${pkgs.glibc.dev}";
  glibc-locales-utf8 = "${pkgs.glibcLocalesUtf8}";
  glibc-iconv = "${pkgs.iconv}";
  glibc-getent = "${pkgs.glibc.getent}";
  glibc-info = "${pkgs.glibcInfo}";
  crypt = "${pkgs.libxcrypt.out}";

  glibc-libxcrypt =
    "${glibc} ${glibc-static} ${glibc-dev} "
    + "${glibc-locales-utf8} ${glibc-iconv} "
    + "${glibc-getent} ${glibc-info} "
    + "${crypt}";

  dirs = "lib etc libexec share include bin";

  echo-targeted-host-stuff = targeted-host: ''
    echo '    TARGETED_ARCH="''${TARGETED_ARCH:-${host-info.${targeted-host}.architecture.cpu}}"'
    echo '    TARGETED_TUNE="''${TARGETED_TUNE:-${host-info.${targeted-host}.architecture.cpu}}"'
    echo '    _BUILD=${host-info.${hostname}.host-platform}'
    echo '    _HOST=${host-info.${targeted-host}.host-platform}'
    echo '    _TARGET=${host-info.${targeted-host}.host-platform}'
  '';

  echo-generic-host-stuff = targeted-host: ''
    echo '    TARGETED_ARCH="''${TARGETED_ARCH:-${host-info.${targeted-host}.architecture.cpu}}"'
    echo '    TARGETED_TUNE="''${TARGETED_TUNE:-k8}"'
    echo '    _BUILD=${host-info.${hostname}.host-platform}'
    echo '    _HOST=${host-info.${targeted-host}.host-platform}'
    echo '    _TARGET=${host-info.${targeted-host}.host-platform}'
  '';

  put-package-there =
    package-name:
    let
      subvol-name = "@" + package-name;
      path = packagesDir + "/" + subvol-name;
      src = pkgs.fetchurl {
        url = usr-local-packages-data.${package-name}.url;
        hash = usr-local-packages-data.${package-name}.hash;
      };
      compression = usr-local-packages-data.${package-name}.compression;
    in
    ''
      if [[ -e ${path} ]]; then
        :
      else
        ${btrfs} subvolume create ${path} &&
          if [[ x${compression} = x ]]; then
            :
          else
            ${btrfs} property set ${path} compression "${compression}"
          fi &&
          env PATH="${pkgs.xz}/bin:${pkgs.gzip}/bin:${pkgs.bzip2}/bin:${pkgs.zstd}/bin:$PATH" \
            ${tar} --extract --no-same-owner --file ${src} --directory ${path} &&
          ${btrfs} property set ${path} ro true
      fi
    '';

in

{

  systemd.services = {

    # The following creates ‘start’ and ‘stop’ init scripts for the
    # /usr/local. The /usr/local will be mounted on initial program
    # load. You can unmount and once again mount the /usr/local with
    # ‘systemctl stop usr-local’ and then ‘systemctl start usr-local’.
    "usr-local" =
      let
        packages = usr-local.packages;
        lowerdirs = lib.strings.concatStringsSep ":" (
          lib.lists.map (pack: "${packagesDir}/@${pack}${ul}") packages
        );

        make-the-usr-local-packages-available = ''
          echo "Making the /usr/local packages available."
          ${lib.strings.concatStringsSep "\n" (lib.lists.map (pack: put-package-there pack) packages)}
        '';
        clean-out-the-old-core = ''
          echo "Cleaning out the old ${coreDir}."
          rm -R -f ${coreDir}
        '';
        copy-glibc-libxcrypt = ''
          echo "Copying glibc and libxcrypt."
          install -d ${coreDir}
          for d in ${dirs}; do
            for p in ${glibc-libxcrypt}; do
              if [[ -d $p ]] && [[ -d $p/$d ]]; then
                ${rcopy} $p/$d ${coreDir}
                chmod --recursive u+w ${coreDir}/$d
              fi
            done
          done            
        '';
        rewrite-implicit-linker-scripts = ''
          #
          # Rewrite implicit linker scripts so they refer to ${ul}
          # instead of the Nix store.
          #
          echo "Rewriting linker scripts."
          ${sed} -i -E 's:/nix/store/[^[:space:]]+(/lib/[^/[:space:]]+):${ul}\1:g' \
                 ${coreDir}/lib/lib[cm].so
        '';
        make-cc-a-synonym-for-gcc = ''
          echo "Making ‘cc’ a synonym for ‘gcc’."
          install -d ${coreDir}/bin
          (cd ${coreDir}/bin && ${link} gcc cc)        
        '';
        write-a-configsite-file = ''
          #
          # Write a /usr/local/share/config.site file.
          #
          echo "Writing /usr/local/share/config.site"
          install -d ${coreDir}/share
          (
              echo '# This config.site was created by the NixOS configuration.'
              echo
              echo 'TARGETED_HOST="''${TARGETED_HOST:-${hostname}}"'
              echo
              echo 'case "$TARGETED_HOST" in'
              echo '  ${CONTACT} )'
              ${echo-targeted-host-stuff CONTACT}
              echo '    ;;'
              echo '  ${DOWNDRAFT} )'
              ${echo-targeted-host-stuff DOWNDRAFT}
              echo '    ;;'
              echo '  ${POLLY} )'
              ${echo-targeted-host-stuff POLLY}
              echo '    ;;'
              echo '  x86_64-linux-gnu )'
              ${echo-generic-host-stuff "x86_64-linux-gnu"}
              echo '    ;;'
              echo '  x86_64-unknown-linux-gnu )'
              ${echo-generic-host-stuff "x86_64-unknown-linux-gnu"}
              echo '    ;;'
              echo '  x86_64-pc-linux-gnu )'
              ${echo-generic-host-stuff "x86_64-pc-linux-gnu"}
              echo '    ;;'
              echo '  * )'
              echo '    echo "unrecognized TARGETED_HOST: ‘$TARGETED_HOST’"'
              echo '    exit 1'
              echo '    ;;'
              echo 'esac'
              echo
              echo 'ac_cv_build="''${ac_cv_build-$_BUILD}"'
              echo 'ac_cv_host="''${ac_cv_host-$_HOST}"'
              echo 'ac_cv_target="''${ac_cv_target-$_TARGET}"'
              echo
              echo 'test "$prefix" = NONE && prefix=${ul}'
              echo
              echo 'test "$enable_maintainer_mode" = NONE && enable_maintainer_mode=no'
              echo 'test "$enable_silent_rules" = NONE && enable_silent_rules=yes'
              echo 'test "$enable_nls" = NONE && enable_nls=no'
              echo
              echo 'CFLAGS="''${CFLAGS}''${CFLAGS+ }-g -O2 -march=""$TARGETED_ARCH"" -mtune=""$TARGETED_TUNE"'
              echo 'CXXFLAGS="''${CXXFLAGS}''${CXXFLAGS+ }-g -O2 -march=""$TARGETED_ARCH"" -mtune=""$TARGETED_TUNE"'
          ) > ${coreDir}/share/config.site
        '';
        construct-the-overlayfs = ''
          echo "Constructing /usr/local as a readonly overlay filesystem."
          install -d "${ul}"
          ${fuse-overlayfs} -o ro -o lowerdir="${lowerdirs}:${coreDir}" "${ul}"
        '';
        unmount-the-overlayfs = ''
          echo "Unmounting /usr/local lazily."
          ${fusermount} -u -z "${ul}"
        '';
      in
      {
        after = [
          "usr-local\\x2dpackages.mount"
          "usr-local\\x2dcore.mount"
        ];

        wantedBy = [ "multi-user.target" ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };

        script = ''
          ${make-the-usr-local-packages-available}
          ${clean-out-the-old-core}
          ${copy-glibc-libxcrypt}
          ${rewrite-implicit-linker-scripts}
          ${make-cc-a-synonym-for-gcc}
          ${write-a-configsite-file}
          ${construct-the-overlayfs}
        '';
        preStop = ''
          ${unmount-the-overlayfs}
        '';
      };

  };

}
