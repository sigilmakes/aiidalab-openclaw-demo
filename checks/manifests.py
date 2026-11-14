import json
import pathlib
import re
import sys

import yaml


def main(root: pathlib.Path) -> None:
    placeholder = re.compile(r"@[A-Z_][A-Z0-9_]*@")
    files = 0
    documents = 0
    for path in sorted(root.rglob("*.yaml")):
        text = path.read_text()
        files += 1
        remaining = placeholder.findall(text)
        if remaining:
            sys.exit(f"{path}: unsubstituted placeholder {remaining[0]}")
        for index, document in enumerate(yaml.safe_load_all(text)):
            documents += 1
            if document is None:
                continue
            if not isinstance(document, dict):
                sys.exit(f"{path}: document {index} is not a mapping")
            for key in ("apiVersion", "kind"):
                if key not in document:
                    sys.exit(f"{path}: document {index} has no {key}")
            metadata = document.get("metadata") or {}
            if "name" not in metadata and "generateName" not in metadata:
                sys.exit(f"{path}: document {index} ({document['kind']}) has no metadata.name")

    for rel, key in (
        ("60-openclaw/10-configmap.yaml", "openclaw.json"),
        ("50-bifrost/10-configmap.yaml", "config.json"),
    ):
        document = yaml.safe_load((root / rel).read_text())
        data = document.get("data") or {}
        if key not in data:
            sys.exit(f"{rel} has no {key}")
        json.loads(data[key])

    bootstrap = root / "40-aiidalab" / "45-bootstrap-configmap.yaml"
    if not bootstrap.is_file():
        sys.exit("40-aiidalab/45-bootstrap-configmap.yaml was not rendered")
    config_map = yaml.safe_load(bootstrap.read_text())
    if "bootstrap.sh" not in (config_map.get("data") or {}):
        sys.exit("the bootstrap ConfigMap has no bootstrap.sh entry")
    print(f"{files} manifest files, {documents} documents")


if __name__ == "__main__":
    main(pathlib.Path(sys.argv[1]))
