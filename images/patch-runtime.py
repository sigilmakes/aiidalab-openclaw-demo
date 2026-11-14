"""Apply narrow compatibility fixes to the pinned, released OpenClaw package."""
from pathlib import Path
import sys


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise SystemExit(f"Pinned runtime changed: expected one occurrence of {old!r}")
    return text.replace(old, new, 1)


def patch(root):
    root = Path(root)
    candidates = [candidate for candidate in (root / "dist").glob("agent-roles-*.mjs")
                  if "async function loadAgentRole(role) {" in candidate.read_text()]
    if len(candidates) != 1:
        raise SystemExit("Expected exactly one bundled agent-role module")
    target = candidates[0]
    text = target.read_text()
    text = 'import { tmpdir as nixRoleTmpdir } from "node:os";\n' + text
    helper = r'''// Nix may hardlink identical immutable store files. Copy only this package's
// bundled role into a private directory; never relax the general Claw reader.
async function copyNixBundledRoleTree(source, target) {
    for (const entry of await fs.readdir(source, { withFileTypes: true })) {
        const from = path.join(source, entry.name);
        const to = path.join(target, entry.name);
        if (entry.isDirectory()) {
            await fs.mkdir(to, { mode: 0o700 });
            await copyNixBundledRoleTree(from, to);
        } else if (entry.isFile()) {
            await fs.copyFile(from, to);
        } else {
            throw new Error("Bundled role contains an unsupported filesystem entry");
        }
    }
}
async function withNixBundledRole(role, read) {
    const source = await resolveCatalogFile(role, "CLAW.md");
    const bundled = new URL("../docs/reference/templates/roles/" + role + "/CLAW.md", import.meta.url);
    if (!bundled.pathname.startsWith("/nix/store/") ||
        await fs.realpath(source) !== await fs.realpath(bundled)) return read(source);
    const scratch = await fs.mkdtemp(path.join(nixRoleTmpdir(), "openclaw-bundled-role-"));
    try {
        await copyNixBundledRoleTree(path.dirname(source), scratch);
        return await read(path.join(scratch, "CLAW.md"));
    } finally {
        await fs.rm(scratch, { recursive: true, force: true });
    }
}
'''
    text = replace_once(text, "async function loadAgentRole(role) {", helper + "async function loadAgentRole(role) {")
    text = replace_once(text,
        '\tconst read = await readClawManifestFile(await resolveCatalogFile(role, "CLAW.md"));',
        '\treturn withNixBundledRole(role, async (source) => {\n\tconst read = await readClawManifestFile(source);')
    text = replace_once(text, "\n}\nasync function loadAgentTeamPreset", "\n\t});\n}\nasync function loadAgentTeamPreset")
    target.write_text(text)

    # Linux-only: macOS and browser layouts keep their own window chrome.
    css_name = "native-chrome.css"
    css = '''html.openclaw-native-desktop[data-native-platform="linux"] {
    --openclaw-native-window-controls-width: 0px !important;
}
html.openclaw-native-desktop[data-native-platform="linux"] .openclaw-window-controls {
    display: none !important;
}
'''
    ui = root / "dist/control-ui"
    html = (ui / "index.html").read_text()
    html = replace_once(html, "</head>", f'<link rel="stylesheet" href="./{css_name}" />\n</head>')
    (ui / css_name).write_text(css)
    (ui / "index.html").write_text(html)


if __name__ == "__main__":
    patch(sys.argv[1])
