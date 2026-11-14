import argparse, datetime, fcntl, hashlib, json, os, re, shutil, sys, traceback
from pathlib import Path

from aiida import load_profile
load_profile()
from aiida.orm import load_node, QueryBuilder, CalcJobNode, FolderData, Dict, StructureData, KpointsData

NOTEBOOKS_ROOT = Path("/home/aiida/notebooks")
LEDGER_DIR = Path("/home/aiida/.aiida-files-export")
CHECKPOINT_PATH = LEDGER_DIR / "checkpoint.json"
MANIFEST_NAME = "MANIFEST.json"
SUMMARY_NAME = "SUMMARY.md"
EXPORTER_NAME = "files_export.py"
EXPORTER_VERSION = "1.1.0"
MANIFEST_SCHEMA = "demo-provenance/1"
EXPORTER_ID = "seat5:filer"
TERMINAL_STATES = ("finished", "excepted", "killed")

def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()

def sha(b):
    return hashlib.sha256(b).hexdigest()

def san(s):
    return re.sub(r"[^A-Za-z0-9_.-]", "_", str(s))

PLANNED = {"inputs", "retrieved", SUMMARY_NAME, MANIFEST_NAME, "_old-partial", ".ipynb_checkpoints"}

def load_checkpoint():
    LEDGER_DIR.mkdir(parents=True, exist_ok=True)
    if CHECKPOINT_PATH.exists():
        try:
            return json.loads(CHECKPOINT_PATH.read_text())
        except Exception:
            return fresh_checkpoint("checkpoint-unreadable-reset")
    return fresh_checkpoint()

def fresh_checkpoint(note=None):
    cp = {"cache": "filer-export-progress-only; provenance validation never consults this",
          "schema": MANIFEST_SCHEMA, "exporter": EXPORTER_NAME + " " + EXPORTER_VERSION,
          "updated_at": now_iso(), "last_node_mtime": None, "exported": {}}
    if note: cp["integrity_note"] = note
    return cp

def save_checkpoint(cp):
    cp["updated_at"] = now_iso()
    CHECKPOINT_PATH.write_text(json.dumps(cp, indent=1, sort_keys=True))

def entry_fresh(cp, pk):
    e = cp.get("exported", {}).get(str(pk))
    if not e:
        return False, "no-checkpoint-entry"
    if e.get("schema") != MANIFEST_SCHEMA:
        return False, "manifest-schema-bumped"
    if e.get("verdict") != "P":
        return False, "last-verdict-not-P"
    d = NOTEBOOKS_ROOT / (str(pk) + "-files")
    if not ((d / "inputs").is_dir() and (d / "retrieved").is_dir() and (d / SUMMARY_NAME).is_file()):
        return False, "folder-incomplete"
    mpath = d / MANIFEST_NAME
    if not mpath.is_file():
        return False, "manifest-missing"
    try:
        if sha(mpath.read_bytes()) != e.get("manifest_sha256"):
            return False, "manifest-hash-drift"
    except Exception:
        return False, "manifest-unreadable"
    return True, "fresh"

def links_in(proc):
    return [(lt.link_label, lt.node) for lt in proc.base.links.get_incoming()]

def links_out(proc):
    return [(lt.link_label, lt.node) for lt in proc.base.links.get_outgoing()]

def node_hash(nd):
    try:
        return nd.base.extras.all.get("_aiida_hash")
    except Exception:
        return None

def content_hash(nd):
    try:
        if isinstance(nd, Dict):
            return sha(json.dumps(nd.get_dict(), sort_keys=True, separators=(",", ":")).encode())
        names = nd.base.repository.list_object_names()
        if len(names) == 1:
            with nd.base.repository.open(names[0], mode="rb") as fh:
                return sha(fh.read())
    except Exception:
        return None
    return None

def formula_from_nodes(struct):
    if struct is None:
        return "N/A"
    kmap = {k.name: (k.symbols[0] if k.symbols else k.name) for k in struct.kinds}
    counts, order = {}, []
    for s in struct.sites:
        el = kmap.get(s.kind_name, re.sub(r"[0-9]+$", "", s.kind_name))
        if el not in counts: order.append(el)
        counts[el] = counts.get(el, 0) + 1
    return "".join(el + (str(counts[el]) if counts[el] > 1 else "") for el in order)

def expected_input_bytes(link_lab, nd, npk, pk, label):
    if isinstance(nd, Dict) and link_lab == "parameters":
        return "inputs/parameters.json", json.dumps(nd.get_dict(), indent=2, sort_keys=True).encode()
    if isinstance(nd, StructureData):
        sites = nd.sites
        kmap = {k.name: (k.symbols[0] if k.symbols else k.name) for k in nd.kinds}
        lines = [str(len(sites))]
        cell = nd.cell
        lines.append("# structure input of " + str(label) + " pk " + str(pk) + " | StructureData pk " + str(npk))
        lines.append("# cell (Angstrom, rows = a1 a2 a3): " + ";".join(" ".join("%.8f" % x for x in row) for row in cell))
        for s in sites:
            sym = kmap.get(s.kind_name, re.sub(r"[0-9]+$", "", s.kind_name))
            p = s.position
            lines.append(sym + " %.8f %.8f %.8f" % (p[0], p[1], p[2]))
        fn = "inputs/structure.xyz" if link_lab == "structure" else "inputs/structure-" + san(link_lab) + ".xyz"
        return fn, ("\n".join(lines) + "\n").encode()
    if isinstance(nd, KpointsData):
        txt = ["kpoints input of " + str(label) + " pk " + str(pk) + " — link label '" + link_lab + "', KpointsData node pk " + str(npk)]
        try:
            mesh, offset = nd.get_kpoints_mesh()
            txt.append("mesh: " + str(list(mesh)))
            txt.append("offset: " + str(list(offset)))
        except Exception:
            try:
                kp = nd.get_kpoints()
                txt.append("explicit list of " + str(len(kp)) + " points:")
                for v in kp[:200]:
                    txt.append(" ".join("%.6f" % x for x in v))
            except Exception as e:
                txt.append("(mesh + kpoints both failed: " + repr(e) + ")")
        fn = "inputs/kpoints.txt" if link_lab == "kpoints" else "inputs/kpoints-" + san(link_lab) + ".txt"
        return fn, ("\n".join(txt) + "\n").encode()
    return None, None

def agent_block(extras):
    want = {}
    fp = extras.get("submit_token_fingerprint")
    if isinstance(fp, str) and fp.startswith("sha256:") and len(fp) <= 64:
        want["submit_token_fingerprint"] = fp
    for k in ("agent_id", "conversation_id", "requested_by"):
        v = extras.get(k)
        if v is not None:
            want[k] = v
    return want

def sched_block(proc):
    attrs = dict(proc.base.attributes.all)
    try:
        ex = dict(proc.base.extras.all)
    except Exception:
        ex = {}
    stamped = {k: ex[k] for k in ex if k.lower().startswith("slurm_")}
    src_note = "extras" if stamped else "attributes.job_id" if "job_id" in attrs else None
    lji = attrs.get("last_job_info")
    wall = None
    if isinstance(lji, dict) and isinstance(lji.get("wallclock_seconds"), (int, float)):
        wall = int(lji["wallclock_seconds"])
    elif isinstance(lji, dict) and isinstance(lji.get("requested_wallclock_time_seconds"), (int, float)):
        wall = None  # requested cap is not used wallclock; keep null
    block = {
        "slurm_jobid": (int(stamped["slurm_jobid"]) if stamped.get("slurm_jobid") is not None else (int(attrs["job_id"]) if isinstance(attrs.get("job_id"), (int, str)) else None)),
        "slurm_node": stamped.get("slurm_node"),
        "slurm_wallclock_s": (int(stamped["slurm_wallclock_s"]) if stamped.get("slurm_wallclock_s") is not None else wall),
        "slurm_exit_code": (int(stamped["slurm_exit_code"]) if stamped.get("slurm_exit_code") is not None else None),
    }
    return block, src_note

def export_pk(pk, cp, fd, force=False, mode="cmd"):
    row = {"pk": pk}
    try:
        proc = load_node(pk)
        if not isinstance(proc, CalcJobNode):
            owner = None
            try:
                owner = [lt.node.pk for lt in proc.base.links.get_incoming() if isinstance(lt.node, CalcJobNode)]
            except Exception:
                pass
            row.update({"status": "failed", "verdict": "F", "reason": "pk " + str(pk) + " is " + proc.__class__.__name__ + ", not a CalcJobNode" + ("; owning process pk: " + str(owner[0]) if owner else "")})
            return row
        st = proc.process_state.value
        if st not in TERMINAL_STATES:
            row.update({"status": "skipped-nonterminal", "verdict": None, "reason": "process_state=" + st})
            return row
        m_iso = proc.mtime.isoformat()
        if not force:
            fresh, why = entry_fresh(cp, pk)
            if fresh:
                e = cp["exported"][str(pk)]
                row.update({"status": "skipped-fresh", "verdict": "P", "reason": why, "manifest": "notebooks/" + str(pk) + "-files/" + MANIFEST_NAME, "n_files": e.get("n_files"), "total_bytes": e.get("total_bytes")})
                return row
        label = getattr(proc, "process_label", None) or getattr(proc, "label", None) or proc.process_type.rsplit(":", 1)[-1]
        attrs = dict(proc.base.attributes.all)
        d = NOTEBOOKS_ROOT / (str(pk) + "-files")
        (d / "inputs").mkdir(parents=True, exist_ok=True)
        (d / "retrieved").mkdir(parents=True, exist_ok=True)
        old_dir = d / "_old-partial"
        for f in d.iterdir():
            if f.name in PLANNED: continue
            if f.is_file():
                old_dir.mkdir(exist_ok=True)
                shutil.move(str(f), str(old_dir / f.name))

        code_node = None
        params_in, struct_in, kpts_in, other_in = [], [], [], []
        for lab, nd in links_in(proc):
            if lab == "code":
                code_node = nd
            elif isinstance(nd, Dict): params_in.append((lab, nd, nd.pk))
            elif isinstance(nd, StructureData): struct_in.append((lab, nd, nd.pk))
            elif isinstance(nd, KpointsData): kpts_in.append((lab, nd, nd.pk))
            else: other_in.append((lab, nd, nd.pk))

        outputs = []
        def out_add(relname, data, src_pk):
            dst = d / relname
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_bytes(data)
            dsha = sha(dst.read_bytes())
            outputs.append({"name": relname, "size_bytes": len(data), "sha256": dsha, "source_node_pk": src_pk, "src_sha256": sha(data), "match": dsha == sha(data)})
            return outputs[-1]

        for lab, nd, npk in params_in:
            out_add("inputs/" + san(lab) + ".json", json.dumps(nd.get_dict(), indent=2, sort_keys=True).encode(), npk)
        main_struct = None
        for lab, nd, npk in struct_in:
            fn, b = expected_input_bytes(lab, nd, npk, pk, label)
            out_add(fn, b, npk)
            if lab == "structure": main_struct = nd
        kdesc = ""
        for lab, nd, npk in kpts_in:
            fn, b = expected_input_bytes(lab, nd, npk, pk, label)
            out_add(fn, b, npk)
            if lab == "kpoints":
                try:
                    mesh, offset = nd.get_kpoints_mesh()
                    kdesc = str(list(mesh)) + " mesh" if list(offset) == [0.0, 0.0, 0.0] else str(list(mesh)) + " mesh shift " + str(list(offset))
                except Exception:
                    try: kdesc = str(len(nd.get_kpoints())) + " explicit k-points"
                    except Exception: kdesc = "kpoints (opaque)"
        if not struct_in and not params_in and not kpts_in:
            fallback = "No standard QE inputs (parameters/structure/kpoints) linked to this process.\nInput links present: " + str([(l, n2.__class__.__name__) for l, n2 in links_in(proc)]) + "\n"
            out_add("inputs/README.txt", fallback.encode(), None)
        rmain = None
        for lab, nd in links_out(proc):
            if isinstance(nd, FolderData) and lab == "retrieved":
                rmain = nd
                break
        if rmain is None:
            for lab, nd in links_out(proc):
                if isinstance(nd, FolderData):
                    rmain = nd
                    break
        retrieved_pk = rmain.pk if rmain else None
        retrieved_files = []
        if rmain is not None:
            for nm in rmain.base.repository.list_object_names():
                with rmain.base.repository.open(nm, mode="rb") as fh:
                    data = fh.read()
                rec = out_add("retrieved/" + nm, data, retrieved_pk)
                retrieved_files.append({"name": nm, "bytes": len(data), "sha256": rec["sha256"]})
        opp = None
        for lab, nd in links_out(proc):
            if isinstance(nd, Dict):
                opp = nd
                if lab == "output_parameters":
                    break
        opk = opp.pk if opp is not None else None
        energy = fermi = None
        energy_txt = "energy: (not present in output_parameters)"
        fermi_txt = "fermi_energy: (not present)"
        scf_txt = "scf_converged: (not present)"
        qe_version_out = None
        if opp is not None:
            op = opp.get_dict()
            if "energy" in op:
                energy = str(op["energy"]) + " " + str(op.get("energy_units", ""))
                energy_txt = energy
            if "fermi_energy" in op:
                fermi = str(op["fermi_energy"]) + " " + str(op.get("fermi_energy_units", ""))
                fermi_txt = fermi
            if "scf_converged" in op:
                scf_txt = "scf_converged: " + str(bool(op["scf_converged"]))
            qe_version_out = op.get("creator_version")

        flines = [
            "# " + str(label) + " pk " + str(pk) + " — " + formula_from_nodes(main_struct) + " " + (kdesc or "no kpoints input"),
            "",
            "- AiiDA process: " + str(label) + " (process_type " + str(getattr(proc, "process_type", "")) + "), node pk " + str(pk),
            "- State: " + st + ", exit_status " + str(proc.exit_status) + (", slurm job id: " + str(attrs.get("job_id")) if attrs.get("job_id") is not None else ""),
            "- Code: " + (str(getattr(code_node, "label", "?" )) if code_node is not None else "n/a") + ("" if code_node is None else " (pk " + str(code_node.pk) + ") — files in retrieved/"),
            "",
            "## Result summary (from output_parameters" + ("" if opp is None else " Dict pk " + str(opk)) + ")",
            "- " + energy_txt,
            "- " + fermi_txt,
            "- " + scf_txt,
            "",
            "## Inputs (AiiDA nodes)",
            "- parameters: Dict pk " + str(params_in[0][2] if params_in else None) + " -> inputs/parameters.json",
            "- structure: StructureData pk " + str(struct_in[0][2] if struct_in else None) + " -> inputs/structure.xyz",
            "- kpoints: KpointsData pk " + str(kpts_in[0][2] if kpts_in else None) + " -> inputs/kpoints.txt",
        ]
        for lab, nd, npk in other_in:
            fn0 = None
            try:
                names0 = nd.base.repository.list_object_names()
                if names0: fn0 = names0[0]
            except Exception:
                pass
            if fn0:
                try: szs = nd.base.repository.get_object_size(fn0)
                except Exception: szs = None
                flines.append("- " + lab + ": " + nd.__class__.__name__ + " pk " + str(npk) + (" (" + fn0 + ", " + str(szs) + " bytes pseudo)" if szs is not None else ""))
            else:
                flines.append("- " + lab + ": " + nd.__class__.__name__ + " pk " + str(npk))
        flines += [
            "",
            "## Output nodes (linked)",
            "- output_parameters: Dict pk " + str(opk) + " (summarized above)",
            "- output_band / output_trajectory / remote_folder: linked nodes; the actual QE output files live in retrieved/",
            "",
            "## Retrieved files (FolderData pk " + str(retrieved_pk) + ") — copied verbatim into retrieved/",
            "",
            "| file | bytes |",
            "|---|---|",
        ]
        for rf in retrieved_files:
            flines.append("| " + rf["name"] + " | " + str(rf["bytes"]) + " |")
        flines += ["", "Full provenance record incl. sha256 hashes: MANIFEST.json (schema " + MANIFEST_SCHEMA + ")."]
        out_add(SUMMARY_NAME, ("\n".join(flines) + "\n").encode(), None)

        inp_extras = {}
        pseudo_family = pseudo_url = pseudo_ck = None
        for lab, nd, npk in other_in:
            try:
                pe = dict(nd.base.extras.all)
            except Exception:
                pe = {}
            pseudo_family = pseudo_family or pe.get("pseudo_family")
            pseudo_url = pseudo_url or pe.get("pseudo_source_url")
            pseudo_ck = pseudo_ck or pe.get("pseudo_checksum")
        code_ex = {}
        try:
            code_ex = dict(code_node.base.extras.all) if code_node is not None else {}
        except Exception:
            code_ex = {}
        sched, sched_src = sched_block(proc)
        manifest = {
            "schema": MANIFEST_SCHEMA,
            "pk": pk,
            "uuid": str(proc.uuid),
            "label": label,
            "process_state": st,
            "exit_status": proc.exit_status,
            "ctime": proc.ctime.isoformat(),
            "export_time": now_iso(),
            "inputs": [
                {"label": lab, "pk": npk, "uuid": str(nd.uuid), "node_type": nd.node_type, "content_hash": content_hash(nd)}
                for lab, nd, npk in params_in + struct_in + kpts_in + other_in
            ],
            "environment": {
                "image_digest": code_ex.get("image_digest"),
                "qe_version": code_ex.get("qe_version"),
                "pseudo_family": pseudo_family,
                "pseudo_source_url": pseudo_url,
                "pseudo_checksum": pseudo_ck,
                "image_tag": code_ex.get("image_tag"),
            },
            "scheduler": sched,
            "agent": agent_block({k: v for k, v in dict(proc.base.extras.all).items()}),
            "outputs": [],
            "verification": {"two_pass": None, "verified_at": now_iso(), "verifier": EXPORTER_ID},
            "filer": {
                "note": "fields below are exporter bookkeeping beyond the demo-provenance/1 top-level set; all values re-derivable from the profile + bundle",
                "process_type": getattr(proc, "process_type", None),
                "exit_message": getattr(proc, "exit_message", None),
                "node_mtime": m_iso,
                "formula": formula_from_nodes(main_struct),
                "kpoints": kdesc or "no kpoints input",
                "output_parameters_pk": opk,
                "retrieved_node_pk": retrieved_pk,
                "energy": energy,
                "fermi_energy": fermi,
                "qe_version_from_output": qe_version_out,
                "scheduler_source": sched_src,
                "exporter": EXPORTER_NAME + " " + EXPORTER_VERSION,
                "checkpoint_path": str(CHECKPOINT_PATH),
                "run_mode": mode,
            },
        }
        manifest["outputs"] = [{"name": o["name"], "size_bytes": o["size_bytes"], "sha256": o["sha256"], "source_node_pk": o["source_node_pk"]} for o in outputs]
        mb = json.dumps(manifest, indent=1, sort_keys=True).encode()
        (d / MANIFEST_NAME).write_bytes(mb)

        # PASS 2 — independent re-derivation + re-read
        notes = []
        ok2 = True
        for o in outputs:
            dst = d / o["name"]
            try:
                disk = dst.read_bytes()
            except Exception as e2:
                ok2 = False; notes.append(o["name"] + " unreadable " + repr(e2)); continue
            if sha(disk) != o["sha256"] or sha(disk) != o["src_sha256"]:
                ok2 = False; notes.append(o["name"] + " hash-mismatch")
            if o["name"].startswith("retrieved/") and rmain is not None:
                rel = o["name"].split("/", 1)[1]
                try:
                    with rmain.base.repository.open(rel, mode="rb") as fh:
                        if sha(fh.read()) != sha(disk):
                            ok2 = False; notes.append(rel + " node-recheck-mismatch")
                except Exception as e3:
                    ok2 = False; notes.append(rel + " node-recheck-error " + repr(e3))
        pr2 = load_node(pk)
        for lab, nd in links_in(pr2):
            fn, bexp = expected_input_bytes(lab, nd, nd.pk, pk, label)
            if fn and (d / fn).exists():
                if sha((d / fn).read_bytes()) != sha(bexp):
                    ok2 = False; notes.append(fn + " regen-mismatch")
        if rmain is not None and sha((d / MANIFEST_NAME).read_bytes()) != sha(mb):
            ok2 = False; notes.append("manifest-self-mismatch")
        two_pass = ok2

        total = sum(o["size_bytes"] for o in outputs)
        manifest["verification"]["two_pass"] = two_pass
        if notes:
            manifest["filer"]["self_check_notes"] = notes
        mb2 = json.dumps(manifest, indent=1, sort_keys=True).encode()
        (d / MANIFEST_NAME).write_bytes(mb2)
        msha = sha(mb2)
        verdict = "P" if two_pass else "F"

        cp.setdefault("exported", {})[str(pk)] = {
            "schema": MANIFEST_SCHEMA,
            "node_mtime": m_iso,
            "exported_at": now_iso(),
            "verdict": verdict,
            "n_files": len(outputs) + 1,
            "total_bytes": total + len(mb2),
            "manifest_sha256": msha,
            "state": st,
            "exit_status": proc.exit_status,
        }
        prev = cp.get("last_node_mtime")
        if prev is None or m_iso > prev:
            cp["last_node_mtime"] = m_iso
        save_checkpoint(cp)
        try:
            run_nb = find_run_notebook(pk)
            info = {"st": st, "exit_status": proc.exit_status, "formula": formula_from_nodes(main_struct), "kdesc": kdesc or "no kpoints input", "label": label, "slurm_jobid": sched["slurm_jobid"], "energy": energy, "fermi": fermi, "run_notebook": run_nb, "bundle_links": manifest["outputs"]}
            row["index_action"] = index_append(pk, info)
        except Exception:
            row["index_action"] = "index-update-failed: " + traceback.format_exc()[-200:]
        row.update({"status": "exported", "verdict": verdict, "manifest": "notebooks/" + str(pk) + "-files/" + MANIFEST_NAME, "n_files": len(outputs) + 1, "total_bytes": total + len(mb2), "energy": energy, "slurm_jobid": sched["slurm_jobid"], "pf_line": "pk " + str(pk) + ": " + verdict + " files=" + str(len(outputs) + 1) + " bytes=" + str(total) + " (" + st + ")" + (" notes:" + str(notes)[:200] if notes else "")})
        return row
    except Exception:
        row.update({"status": "failed", "verdict": "F", "reason": traceback.format_exc()[-1200:]})
        return row
def index_row_source(pk, info):
    if info["exit_status"] is None:
        state_wording = info["st"]
    elif info["exit_status"] == 0 and info["st"] == "finished":
        state_wording = info["st"] + " (exit 0)"
    else:
        state_wording = info["st"] + " (exit_status " + str(info["exit_status"]) + ")"
    l1 = "## pk " + str(pk) + " — " + info["formula"] + " " + info["kdesc"] + " — " + info["label"]
    l2 = "- state: " + state_wording + (" · slurm jobid: " + str(info["slurm_jobid"]) if info.get("slurm_jobid") is not None else "")
    enl = "- energy: " + (info["energy"] if info.get("energy") else "(not present in output_parameters)")
    if info.get("fermi"):
        enl += " · fermi: " + info["fermi"]
    links = ["[" + str(pk) + "-files/](" + str(pk) + "-files/)", "[" + SUMMARY_NAME + "](" + str(pk) + "-files/" + SUMMARY_NAME + ")"]
    nblink = info.get("run_notebook")
    if nblink:
        links.append("[run notebook:" + nblink + "](" + nblink + ")")
    else:
        l2 += " · no run notebook found for this pk"
    drel = str(pk) + "-files/"
    for o in info["bundle_links"]:
        rel = o["name"]
        links.append("[" + rel + "](" + drel + rel + ")")
    src = "\n\n".join([l1, l2, enl, "- " + " · ".join(links), ""])
    return src

def find_run_notebook(pk):
    # notebook filename embedding pk as a digit token: 346-h2.ipynb | e2e-mcp-repro-292.ipynb
    best = None
    for f in sorted(NOTEBOOKS_ROOT.glob("*.ipynb")):
        if f.name.startswith("Untitled"): continue
        if re.search(r"(^|[^0-9])" + str(pk) + r"([^0-9]|$)", f.name):
            if f.name.startswith(str(pk) + "-"):
                best = f.name
                break
            best = best or f.name
    return best

def index_append(pk, info):
    ip = NOTEBOOKS_ROOT / "FILES-INDEX.ipynb"
    if ip.exists():
        try:
            nb = json.loads(ip.read_text())
        except Exception:
            nb = None
    else:
        nb = None
    if not nb:
        nb = {"cells": [], "metadata": {"kernelspec": {"display_name": "Python 3", "language": "python", "name": "python3"}, "language_info": {"name": "python"}}, "nbformat": 4, "nbformat_minor": 5}
    cells = nb["cells"]
    if not cells:
        intro = "**open in file browser, links are plain — the agent chat needs absolute URLs, the notebook does not.**\n\n# QE files — exported calculation inputs & outputs\n\nAuto-appended rows by " + EXPORTER_NAME + " (" + EXPORTER_ID + ", schema " + MANIFEST_SCHEMA + " + row contract). Each run: one row, state line, energy line, plain links. Per-bundle provenance: <pk>-files/MANIFEST.json."
        cells.append({"cell_type": "markdown", "metadata": {}, "source": intro})
    marker = re.compile(r"\bpk " + str(pk) + r"\b")
    src = index_row_source(pk, info)
    replace_idx = None
    for i, c in enumerate(cells):
        if c.get("cell_type") == "markdown" and i > 0 and marker.search(c.get("source", "")):
            replace_idx = i
            break
    cell = {"cell_type": "markdown", "metadata": {}, "source": src}
    if replace_idx is not None:
        cells[replace_idx] = cell
        action = "updated-row"
    else:
        last = len(cells)
        for i, c in enumerate(cells):
            if c.get("cell_type") == "markdown" and c.get("source", "").startswith("## Verification"):
                last = i
                break
        cells.insert(last, cell)
        action = "appended-row"
    ip.write_text(json.dumps(nb, indent=1))
    return action


def cmd_check(cp, machine=False):
    rows = []
    for pk_s, e in sorted(cp.get("exported", {}).items(), key=lambda x: int(x[0])):
        pk = int(pk_s)
        try:
            proc = load_node(pk)
            m_iso = proc.mtime.isoformat()
        except Exception:
            rows.append({"pk": pk, "status": "failed", "verdict": "F", "reason": "node no longer loadable"})
            continue
        fresh, why = entry_fresh(cp, pk)
        fresh2 = fresh and e.get("node_mtime") == m_iso
        rows.append({"pk": pk, "status": "checked-fresh" if fresh2 else "stale:" + str(why), "verdict": "P" if fresh2 else "F"})
        if not machine:
            print("CHECK pk " + str(pk) + ": " + ("P" if fresh2 else "F (" + str(why) + ("" if e.get("node_mtime") == m_iso else ", node mtime moved)") + ")"), flush=True)
    cp["last_check"] = now_iso()
    save_checkpoint(cp)
    return rows

def iter_deltas(since_iso, cp):
    if since_iso:
        try:
            dt = datetime.datetime.fromisoformat(since_iso)
        except Exception:
            dt = None
    else:
        dt = None
    qb = QueryBuilder()
    f = {"mtime": {">": dt}} if dt is not None else {}
    qb.append(CalcJobNode, filters=f, project="id")
    for (pid,) in qb.all():
        try:
            n = load_node(int(pid))
        except Exception:
            continue
        if not isinstance(n, CalcJobNode): continue
        if n.process_state.value not in TERMINAL_STATES: continue
        if not any(isinstance(nd, FolderData) for _, nd in links_out(n)): continue
        yield n.pk

def main():
    ap = argparse.ArgumentParser(description="AiiDA artifact exporter (browsable <pk>-files/ + demo-provenance/1 MANIFEST.json + progress checkpoint)")
    ap.add_argument("--pk", action="append", type=int, help="CalcJob pk to export (repeatable)")
    ap.add_argument("--all-terminal", action="store_true", help="export terminal CalcJobNodes with retrieved FolderData since the checkpoint watermark (delta)")
    ap.add_argument("--all-history", action="store_true", help="with --all-terminal: ignore watermark (everything terminal)")
    ap.add_argument("--since", type=str, default=None, help="with --all-terminal: explicit ISO watermark")
    ap.add_argument("--force", action="store_true", help="re-export even if fresh per checkpoint")
    ap.add_argument("--check", action="store_true", help="verify existing exports only (no export writes)")
    ap.add_argument("--json", action="store_true", help="machine output: one JSON object per line")
    args = ap.parse_args()
    LEDGER_DIR.mkdir(parents=True, exist_ok=True)
    fid = open(CHECKPOINT_PATH, "a+")
    try:
        fcntl.flock(fid, fcntl.LOCK_EX)
        cp = load_checkpoint()
        rows = []
        if args.check:
            rows = cmd_check(cp, machine=args.json)
        else:
            pks = list(args.pk) if args.pk else []
            if args.all_terminal:
                since = args.since or None
                if not args.all_history and since is None:
                    since = cp.get("last_node_mtime")
                pks = sorted(set(pks) | set(iter_deltas(since, cp)))
            mode = "mcp" if args.json and not args.pk else "cmd"  # rough mode tag; MCP wrapper passes --json --pk N
            for pk in pks:
                rows.append(export_pk(pk, cp, fid, force=args.force, mode=mode))
        if not args.json:
            for r in rows:
                print(r.get("pf_line") or (str(r.get("pk")) + " " + str(r.get("status")) + (": " + str(r.get("reason", ""))[:200] if r.get("reason") else "")), flush=True)
        for r in rows:
            slim = {k: v for k, v in r.items() if not (k == "pf_line" and args.json) and (v is not None or k in ("verdict", "status"))}
            print("ROW " + json.dumps(slim), flush=True)
        np_ = sum(1 for r in rows if r.get("verdict") == "P")
        nf_ = sum(1 for r in rows if r.get("verdict") == "F")
        print("RUN-VERDICT passes=" + str(np_) + " fails=" + str(nf_) + " rows=" + str(len(rows)), flush=True)
    except Exception:
        traceback.print_exc()
        print("RUN-FATAL", flush=True)
        raise SystemExit(2)
    finally:
        try: fcntl.flock(fid, fcntl.LOCK_UN)
        except Exception: pass
        fid.close()

if __name__ == "__main__":
    main()
