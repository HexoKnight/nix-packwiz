{
  lib,
  stdenvNoCC,
  fetchurl,

  jq,
  zip,

  # the full thing will not be available without the overlay
  # but this will suffice for laziness
  minecraftServers,
}:

# TODO: maybe add support for specifying optional mods
{
  # path with pack.toml at its root
  packRoot,

  # use if the pack fromat has updated but this function still works
  ignorePackFormat ? false,
}:

let
  pack = lib.importTOML (lib.path.append packRoot "pack.toml");
  indexPath = lib.path.append packRoot pack.index.file;
  indexRoot = builtins.dirOf indexPath;
  index = lib.importTOML indexPath;

  files = map (file:
    let
      filePath = lib.path.append indexRoot file.file;
      destRoot = builtins.dirOf (lib.path.subpath.normalise file.file);

      fileIsMeta = file.metafile or false;
      meta = lib.importTOML filePath;
    in
    if fileIsMeta then
      {
        path = fetchurl {
          url = meta.download.url;
          outputHashAlgo = meta.download.hash-format;
          outputHash = meta.download.hash;
        };
        # existence of url attr will indicate an external file
        url = meta.download.url;

        dest = lib.removePrefix "./" (lib.path.subpath.join [ destRoot meta.filename ]);

        side = meta.side or "both";
      }
    else
      {
        path = filePath;

        dest =
          if file ? alias then
            lib.removePrefix "./" (lib.path.subpath.join [ destRoot file.alias ])
          else
            file.file;

        # packwiz has no way to represent side on local files
        side = "both";
      }
  ) index.files;

  loaders = {
    supportedBy = {
      serverPackage = [ "fabric" "quilt" ];
      packwiz = [
        "fabric" "quilt"
        "forge"
        "liteloader"
        # not documented but supported in reference binary
        "neoforge"
      ];
    };
    nameToModrinthDependency = {
      "fabric" = "fabric-loader";
      "quilt" = "quilt-loader";
      "forge" = "forge";
      "neoforge" = "neoforge";
    };
  };
in
assert lib.assertMsg (ignorePackFormat || pack.pack-format == "packwiz:1.1.0") ''
  parsePackwiz: only packwiz:1.1.0 is supported at the moment
  NOTE: use the following if you want to try anyway
  ```
  parsePackwiz {
    ...
    ignorePackFormat = true;
  }
  ```
'';
rec {
  # for introspection
  inherit pack files;
  minecraftVersion = pack.versions.minecraft;

  loader =
    let
      loaderVersions = lib.removeAttrs pack.versions [ "minecraft" ];
      loaderNames = lib.attrNames loaderVersions;
      hasLoader = lib.length loaderNames == 1;
    in
    assert lib.assertMsg (lib.length loaderNames <= 1) ''
      parsePackwiz: multiple mod loader versions are specified:
      ${lib.concatStrings (lib.mapAttrsToList (n: v: "  - ${n}: ${v}" loaderNames))}
    '';
    lib.optionalAttrs hasLoader rec {
      name = lib.head loaderNames;
      version = loaderVersions.${name};
    };

  build =
    {
      # which side mods to install
      side ? "both",
    }:
    assert lib.assertMsg (side == "client" || side == "server" || side == "both") ''
      parsePackwiz.build: `side` must be one of "client", "server" or "both"
    '';
    # mostly just manual linkFarm
    stdenvNoCC.mkDerivation {
      pname = pack.name;
      version = pack.version;

      enableParallelBuilding = true;

      preferLocalBuild = true;
      allowSubstitutes = false;

      buildCommand = ''
        mkdir -p $out
        cd $out
        ${lib.concatMapStrings (file:
          let
            fileIncluded = file.side == "both" || side == "both" || file.side == side;
          in
          lib.optionalString fileIncluded ''
            mkdir -p "$(dirname ${lib.escapeShellArg "${file.dest}"})"
            ln -s ${lib.escapeShellArg "${file.path}"} ${lib.escapeShellArg "${file.dest}"}
          ''
        ) files}
      '';
      passAsFile = [ "buildCommand" ];

      meta = {
        description = pack.description or "minecraft modpack";
        sourceProvenance = [
          lib.sourceTypes.binaryBytecode
        ];
      };
    };

  serverPackage =
    let
      serverVersion = lib.replaceStrings [ "." ] [ "_" ] minecraftVersion;

      serverAttrname =
        if loader ? name then
          "${loader.name}-${serverVersion}"
        else
          "vanilla-${serverVersion}";
    in
    assert lib.assertMsg (! loader ? name || lib.elem loader.name loaders.supportedBy.serverPackage) ''
      parsePackwiz.serverPackage: the following mod loader is not supported for `serverPackage` generation:
        - ${loader.name}
    '';
    assert lib.assertMsg (minecraftServers ? ${serverAttrname}) ''
      parsePackwiz.serverPackage: the following server package attr could not be found:
        - minecraftServers."${serverAttrname}"
      NOTE: you may be missing `minecraftServers` from `github.com/Infinidoge/nix-minecraft`,
      which can be supplied through an overlay or by overriding parsePackwiz
    '';
    if loader ? name then
      minecraftServers.${serverAttrname}.override {
        loaderVersion = loader.version;
      }
    else
      minecraftServers.${serverAttrname};

  modrinthModpack =
    assert lib.assertMsg (loaders.nameToModrinthDependency ? ${loader.name}) ''
      parsePackwiz.modrinthModpack: the following mod loader is not supported by modrinth:
        - ${loader.name}
    '';
    let
      manifest = {
        name = pack.name;
        versionId = pack.version;
        formatVersion = 1;
        game = "minecraft";

        dependencies = {
          minecraft = minecraftVersion;
          ${
            if loader ? name then
              loaders.nameToModrinthDependency.${loader.name}
            else
              null
          } = loader.version;
        };
      };
    in
    stdenvNoCC.mkDerivation {
      name = "${pack.name}-${pack.version}.mrpack";
      version = pack.version;

      enableParallelBuilding = true;

      buildCommand = ''
        mkdir zip
        cd zip
        (
          ${lib.concatMapStrings (file: lib.optionalString (file ? url) ''
            echo '{
              "path": ${builtins.toJSON file.dest},
              "hashes": {
                "sha1": "'$(sha1sum ${file.path} | cut -f1 -d' ')'",
                "sha512": "'$(sha512sum ${file.path} | cut -f1 -d' ')'"
              },
              "env": ${builtins.toJSON (
                # TODO: support for optional mods
                if file.side == "client" then {
                  client = "required";
                  server = "unsupported";
                } else if file.side == "server" then {
                  client = "unsupported";
                  server = "required";
                } else { # both
                  client = "required";
                  server = "required";
                }
              )},
              "downloads": ${builtins.toJSON [ file.url ]},
              "filesize": '$(stat -c%s ${file.path})'
            }'
          '') files}
        ) |
        ${lib.getExe jq} >modrinth.index.json \
          --slurp \
          --argjson manifest ${lib.escapeShellArg (builtins.toJSON manifest)} \
          '$manifest + {files: .}'

        ${lib.concatMapStrings (file: lib.optionalString (! file ? url) (
          let
            overrideFolder = {
              "both" = "overrides";
              # I don't believe these two are possible atm
              "client" = "client-overrides";
              "server" = "server-overrides";
            }.${file.side};
          in ''
            mkdir -p ${overrideFolder}
            cp --dereference --preserve=timestamp ${file.path} ${overrideFolder}/${file.dest}
          ''
        )) files}

        find . -exec touch --date=@1 {} +
        ${lib.getExe zip} -r -X $out .
      '';
      passAsFile = [ "buildCommand" ];

      meta = {
        description = pack.description or "minecraft modpack in modrinth format";
        sourceProvenance = [
          # mostly just links to such but eh
          lib.sourceTypes.binaryBytecode
        ];
      };
    };
}
