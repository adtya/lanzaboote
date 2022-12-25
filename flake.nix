{
  description = "Lanzaboot Secure Boot Madness";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable-small";
    nixpkgs-test.url = "github:RaitoBezarius/nixpkgs/simplified-qemu-boot-disks";

    crane = {
      url = "github:ipetkov/crane";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.rust-overlay.follows = "rust-overlay";
      inputs.flake-utils.follows = "flake-utils";
    };

    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };

    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, nixpkgs-test, crane, rust-overlay, ... }:
  let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
    pkgsFor = system: import nixpkgs {
      inherit system;
      overlays = [
        rust-overlay.overlays.default
      ];
    };
    in {
      overlays.default = final: prev: {
        lanzatool = self.packages.${prev.system}.lanzatool;
      };

      nixosModules.lanzaboote = { pkgs, lib, ... }: {
        imports = [ ./nix/lanzaboote.nix ];
        boot.lanzaboote.package = lib.mkDefault self.packages.${pkgs.system}.lanzatool;
      };

      packages = forAllSystems (system:
      let
        pkgs = pkgsFor system;
        lib = pkgs.lib;

        rust-nightly = pkgs.rust-bin.fromRustupToolchainFile ./rust/lanzaboote/rust-toolchain.toml;
        craneLib = crane.lib.${system}.overrideToolchain rust-nightly;

        uefi-run = pkgs.callPackage ./nix/uefi-run.nix {
          inherit craneLib;
        };

        # Build attributes for a Rust application.
        buildRustApp = {
          src, target ? null, doCheck ? true
        }: let
          cleanedSrc = craneLib.cleanCargoSource src;
          commonArgs = {
            src = cleanedSrc;
            CARGO_BUILD_TARGET = target;
            inherit doCheck;
          };

          cargoArtifacts = craneLib.buildDepsOnly commonArgs;
        in {
          package = craneLib.buildPackage (commonArgs // {
            inherit cargoArtifacts;
          });

          clippy = craneLib.cargoClippy (commonArgs // {
            inherit cargoArtifacts;
            cargoClippyExtraArgs = "-- --deny warnings";
          });
        };

        lanzabooteCrane = buildRustApp {
          src = ./rust/lanzaboote;
          target = "${(lib.systems.elaborate system).parsed.cpu.name}-unknown-uefi";
          doCheck = false;
        };

        lanzatoolCrane = buildRustApp {
          src = ./rust/lanzatool;
        };

        lanzaboote = lanzabooteCrane.package;
        lanzatool-unwrapped = lanzatoolCrane.package;

        lanzatool = pkgs.runCommand "lanzatool" {
          nativeBuildInputs = [ pkgs.makeWrapper ];
        } ''
          mkdir -p $out/bin

          # Clean PATH to only contain what we need to do objcopy. Also
          # tell lanzatool where to find our UEFI binaries.
          makeWrapper ${lanzatool-unwrapped}/bin/lanzatool $out/bin/lanzatool \
            --set PATH ${lib.makeBinPath [ pkgs.binutils-unwrapped pkgs.sbsigntool ]} \
            --set RUST_BACKTRACE full \
            --set LANZABOOTE_STUB ${lanzaboote}/bin/lanzaboote.efi
        '';
      in
      {
        inherit lanzaboote lanzatool;
        lanzatoolClippy = lanzatoolCrane.clippy;
        lanzabooteClippy = lanzabooteCrane.clippy;
        default = lanzatool;
      });

      devShells = forAllSystems (system: let
        pkgs = pkgsFor system;
      in
      {
        default = pkgs.mkShell {
          packages = [
              # deprecated: self.packages.${system}.uefi-run
              self.packages.${system}.lanzatool
              pkgs.openssl
              (pkgs.sbctl.override {
                databasePath = "pki";
              })
              # pkgs.sbsigntool
              pkgs.efitools
              pkgs.python39Packages.ovmfvartool
              pkgs.qemu
            ];

            inputsFrom = [
              self.packages."${system}".lanzaboote
            ];
      };
    });

    checks = forAllSystems (system: let
      pkgs = pkgsFor system;
        mkSecureBootTest = { name, machine ? {}, testScript }: nixpkgs-test.legacyPackages.${system}.nixosTest {
          inherit name testScript;
          nodes.machine = { lib, ... }: {
            imports = [
              self.nixosModules.lanzaboote
              machine
            ];

            nixpkgs.overlays = [ self.overlays.default ];

            virtualisation = {
              useBootLoader = true;
              useEFIBoot = true;
              useSecureBoot = true;
            };

            boot.loader.efi = {
              canTouchEfiVariables = true;
            };
            boot.lanzaboote = {
              enable = true;
              enrollKeys = lib.mkDefault true;
              pkiBundle = ./pki;
            };
          };
        };

        # Execute a boot test that is intended to fail.
        #
        mkUnsignedTest = { name, path, appendCrap ? false }: mkSecureBootTest {
          inherit name;
          testScript = ''
            import json
            import os.path
            bootspec = None

            def convert_to_esp(store_file_path):
                store_dir = os.path.basename(os.path.dirname(store_file_path))
                filename = os.path.basename(store_file_path)
                return f'/boot/EFI/nixos/{store_dir}-{filename}.efi'

            machine.start()
            bootspec = json.loads(machine.succeed("cat /run/current-system/boot.json")).get('v1')
            assert bootspec is not None, "Unsupported bootspec version!"
            src_path = ${path.src}
            dst_path = ${path.dst}
            machine.succeed(f"cp -rf {src_path} {dst_path}")
          '' + nixpkgs.lib.optionalString appendCrap ''
            machine.succeed(f"echo Foo >> {dst_path}")
          '' +
          ''
            machine.succeed("sync")
            machine.crash()
            machine.start()
            machine.wait_for_console_text("Hash mismatch")
          '';
        };
      in
        {
          lanzatool-clippy = self.packages.${system}.lanzatoolClippy;
          lanzaboote-clippy = self.packages.${system}.lanzabooteClippy;

          # TODO: user mode: OK
          # TODO: how to get in: {deployed, audited} mode ?
          lanzaboote-boot = mkSecureBootTest {
            name = "signed-files-boot-under-secureboot";
            testScript = ''
              machine.start()
              assert "Secure Boot: enabled (user)" in machine.succeed("bootctl status")
            '';
          };

          lanzaboote-boot-under-sd-stage1 = mkSecureBootTest {
            name = "signed-files-boot-under-secureboot-systemd-stage-1";
            machine = { ... }: {
              boot.initrd.systemd.enable = true;
            };
            testScript = ''
              machine.start()
              assert "Secure Boot: enabled (user)" in machine.succeed("bootctl status")
            '';
          };

          # So, this is the responsibility of the lanzatool install
          # to run the append-initrd-secret script
          # This test assert that lanzatool still do the right thing
          # preDeviceCommands should not have any root filesystem mounted
          # so it should not be able to find /etc/iamasecret, other than the
          # initrd's one.
          # which should exist IF lanzatool do the right thing.
          lanzaboote-with-initrd-secrets = mkSecureBootTest {
            name = "signed-files-boot-with-secrets-under-secureboot";
            machine = { ... }: {
              boot.initrd.secrets = {
                "/etc/iamasecret" = (pkgs.writeText "iamsecret" "this is a very secure secret");
              };

              boot.initrd.preDeviceCommands = ''
                grep "this is a very secure secret" /etc/iamasecret
              '';
            };
            testScript = ''
            machine.start()
            assert "Secure Boot: enabled (user)" in machine.succeed("bootctl status")
          '';
          };

          # The initrd is not directly signed. Its hash is embedded
          # into lanzaboote. To make integrity verification fail, we
          # actually have to modify the initrd. Appending crap to the
          # end is a harmless way that would make the kernel still
          # accept it.
          is-initrd-secured = mkUnsignedTest {
            name = "unsigned-initrd-do-not-boot-under-secureboot";
            path = {
              src = "bootspec.get('initrd')";
              dst = "convert_to_esp(bootspec.get('initrd'))";
            };
            appendCrap = true;
          };

          is-kernel-secured = mkUnsignedTest {
            name = "unsigned-kernel-do-not-boot-under-secureboot";
            path = {
              src = "bootspec.get('kernel')";
              dst = "convert_to_esp(bootspec.get('kernel'))";
            };
          };
          specialisation-works = mkSecureBootTest {
            name = "specialisation-still-boot-under-secureboot";
            machine = { pkgs, ... }: {
              specialisation.variant.configuration = {
                environment.systemPackages = [
                  pkgs.efibootmgr
                ];
              };
            };
            testScript = ''
              machine.start()
              print(machine.succeed("ls -lah /boot/EFI/Linux"))
              print(machine.succeed("cat /run/current-system/boot.json"))
              # TODO: make it more reliable to find this filename, i.e. read it from somewhere?
              machine.succeed("bootctl set-default nixos-generation-1-specialisation-variant.efi")
              machine.succeed("sync")
              machine.fail("efibootmgr")
              machine.crash()
              machine.start()
              print(machine.succeed("bootctl"))
              # We have efibootmgr in this specialisation.
              machine.succeed("efibootmgr")
            '';
          };
        });
    };
}
