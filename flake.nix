{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    flake-utils.url = "github:numtide/flake-utils";
    star-lang = {
      url = "git+https://git.starintel.actor/starintel-labs/star-lang?rev=7db89986450d4e513ff4b5c9617bf4d196b3cfb4";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      star-lang,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        lib = pkgs.lib;

        starLangPkg = star-lang.packages.${system}.star-lang;
        starLangSrc = "${starLangPkg}/share/common-lisp/source/star-lang";

        sbcl = pkgs.sbcl.withPackages (ps: [
          ps.fiveam
          ps.ironclad
          ps.yason
          ps.babel
        ]);

        faceEngine =
          pkgs.python3.withPackages (ps: [
            ps.opencv4
            ps.numpy
          ]);

        pipelineDeps = [
          faceEngine
          sbcl
          starLangPkg
          pkgs.yt-dlp
          pkgs.ffmpeg
          pkgs.jq
        ];

        envExports = ''
          export STAR_LANG_SRC="${starLangSrc}"
          export STARLANG_BIN="${starLangPkg}/bin/starlang"
          export STAR_FACE_SBCL="${sbcl}/bin/sbcl"
          export CL_SOURCE_REGISTRY="${starLangSrc}//:${self}/lisp//"
        '';

        gate = name: script:
          pkgs.stdenvNoCC.mkDerivation {
            pname = "star-face-${name}";
            version = "0.1.0";
            src = self;
            strictDeps = true;
            nativeBuildInputs = [ starLangPkg sbcl pkgs.python3 ];
            dontConfigure = true;
            buildPhase = ''
              export HOME="$TMPDIR/home"
              mkdir -p "$HOME"
              export STAR_LANG_SRC="${starLangSrc}"
              export STAR_FACE_ROOT="$PWD"
              export STARLANG_BIN="${starLangPkg}/bin/starlang"
              export STAR_FACE_SBCL="${sbcl}/bin/sbcl"
              bash tests/run-gates.sh
            '';
            installPhase = ''
              mkdir -p "$out"
              cp -r manifest "$out/"
            '';
            dontFixup = true;
          };
      in
      {
        packages = {
          default = gate "gates" "tests/run-gates.sh";
          star-face = gate "gates" "tests/run-gates.sh";
          star-face-pipeline =
            let
              script = pkgs.writeShellScriptBin "star-face-pipeline" ''
                ${envExports}
                export PATH="${pkgs.lib.makeBinPath pipelineDeps}:$PATH"
                export STAR_FACE_ROOT="${self}"
                exec bash "${self}/scripts/pipeline-video" "$@"
              '';
            in
            pkgs.symlinkJoin {
              name = "star-face-pipeline-env";
              paths = [ script ] ++ pipelineDeps;
              meta.mainProgram = "star-face-pipeline";
            };
        };

        apps = {
          pipeline.type = "app";
          pipeline.program = "${self.packages.${system}.star-face-pipeline}/bin/star-face-pipeline";
          engine.type = "app";
          engine.program = "${faceEngine}/bin/python3";
          engine.args = [ "${self}/engine/face_engine.py" ];
        };

        checks.default = self.packages.${system}.star-face;

        devShells.default = pkgs.mkShell {
          packages = pipelineDeps ++ [ pkgs.git ];
          shellHook = ''
            ${envExports}
            export STAR_FACE_ROOT="${self}"
            echo "star-face dev shell: star-lang src at ${starLangSrc}"
          '';
        };
      }
    );
}
