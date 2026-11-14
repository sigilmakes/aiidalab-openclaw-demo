{ pkgs }:

# Copy the manifest tree, fill the site placeholders, and render two computed
# pieces: the AiiDALab bootstrap ConfigMap and four content checksums. A final
# pass fails the build if any @TOKEN@ survived, so a renamed option cannot ship
# a literal placeholder into the cluster.
{ source, hold ? [ ], substitutions, openclawImage ? null }:

let
    lib = pkgs.lib;
    sha = s: builtins.hashString "sha256" s;

    openclawChecksum =
        if openclawImage == null then "unset"
        else builtins.substring 0 16 (sha (toString openclawImage));
    cryoemChecksum = builtins.substring 0 16 (sha (builtins.readFile ../images/cryoem/Dockerfile));
    bootstrapScript = builtins.readFile ../images/aiidalab/bootstrap.sh;
    bootstrapHash = builtins.substring 0 8 (sha bootstrapScript);

    bootstrapLines = lib.splitString "\n" (lib.removeSuffix "\n" bootstrapScript);

    bootstrapConfigMap = pkgs.writeText "aiidalab-bootstrap-configmap.yaml" ''
        apiVersion: v1
        kind: ConfigMap
        metadata:
          name: aiidalab-bootstrap
          namespace: aiidalab
        data:
          bootstrap.sh: |+
        ${lib.concatMapStrings (line: "            ${line}\n") bootstrapLines}
    '';

    sedArgs = lib.concatStringsSep " " (lib.mapAttrsToList
        (k: v: "-e ${lib.escapeShellArg "s|@${k}@|${toString v}|g"}")
        substitutions);
in
pkgs.runCommand "aiidalab-openclaw-demo-manifests" { } (''
    cp -r ${source} $out
    chmod -R u+w $out
'' + lib.concatMapStrings (path: ''
    rm -rf $out/${path}
'') hold + ''
    cp ${bootstrapConfigMap} $out/40-aiidalab/45-bootstrap-configmap.yaml

    checksum=$(sha256sum $out/40-aiidalab/60-mcp.yaml | cut -c1-16)
    sed -i -e "s|@MCP_CODE_CHECKSUM@|$checksum|g" $out/40-aiidalab/60-mcp.yaml
    sed -i -e "s|@OPENCLAW_IMAGE_CHECKSUM@|${openclawChecksum}|g" $out/60-openclaw/20-deployment.yaml
    sed -i -e "s|@CRYOEM_IMAGE_CHECKSUM@|${cryoemChecksum}|g" $out/35-slurm/40-cryoem-ops.yaml
    sed -i -e "s|@BOOTSTRAP_HASH@|${bootstrapHash}|g" $out/40-aiidalab/80-bootstrap-job.yaml

    find $out -type f -print0 | while IFS= read -r -d "" f; do
        ${pkgs.gnused}/bin/sed -i ${sedArgs} "$f"
    done

    if ${pkgs.gnugrep}/bin/grep -RIn -E '@[A-Z_][A-Z0-9_]*@' $out; then
        echo "unsubstituted placeholder remains" >&2
        exit 1
    fi
'')
