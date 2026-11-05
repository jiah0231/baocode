"""Verify visual-input provenance and geometry without launching a renderer."""

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[3]
FIXTURES = ROOT / "test/fixtures/office_preview"


def local(element):
    return element.tag.rsplit("}", 1)[-1]


def inspect(path):
    counts = {}
    with zipfile.ZipFile(path) as package:
        names = package.namelist()
        assert len(names) == len(set(names)), f"{path.name}: duplicate ZIP paths"
        assert package.testzip() is None, f"{path.name}: invalid CRC"
        for name in names:
            parts = PurePosixPath(name).parts
            assert not name.startswith("/") and ".." not in parts and "\\" not in name
            assert "vbaproject" not in name.lower(), "Visual corpus must not contain macros"
            if not name.endswith((".xml", ".rels")):
                continue
            data = package.read(name)
            assert b"<!DOCTYPE" not in data and b"<!ENTITY" not in data
            for element in ET.fromstring(data).iter():
                key = local(element)
                counts[key] = counts.get(key, 0) + 1
        counts["zipParts"] = len(names)
    return counts


def authored_contracts():
    def xml(file, part):
        with zipfile.ZipFile(FIXTURES / file) as package:
            return ET.fromstring(package.read(part))

    def elements(root, tag):
        return [element for element in root.iter() if local(element) == tag]

    word = xml("authored-layout.docx", "word/document.xml")
    size = elements(word, "pgSz")[0]
    values = {key.rsplit("}", 1)[-1]: value for key, value in size.attrib.items()}
    assert (values["w"], values["h"]) == ("12240", "15840")
    assert any(e.attrib.get("{http://schemas.openxmlformats.org/wordprocessingml/2006/main}type") == "page" for e in elements(word, "br"))
    assert elements(word, "gridSpan") and elements(word, "drawing")
    presentation = xml("authored-layout.pptx", "ppt/presentation.xml")
    slide_size = elements(presentation, "sldSz")[0]
    assert (slide_size.attrib["cx"], slide_size.attrib["cy"]) == ("10972800", "6172200")
    assert len(elements(presentation, "sldId")) == 2
    sheet = xml("authored-layout.xlsx", "xl/worksheets/sheet1.xml")
    assert any(e.attrib["ref"] == "A1:F2" for e in elements(sheet, "mergeCell"))
    assert any(e.attrib["r"] == "4" and e.attrib["ht"] == "42" for e in elements(sheet, "row"))
    assert any(e.attrib["min"] == "2" and e.attrib["width"] == "20" for e in elements(sheet, "col"))
    return {"wordPageCssPixels": [816, 1056], "pptSlideCssPixels": [1152, 648], "xlsxMergedRange": "A1:F2", "xlsxRow4CssPixels": 56}


def verify():
    manifest = json.loads((FIXTURES / "manifest.json").read_text())
    assert manifest["schemaVersion"] == 1
    assert (FIXTURES / "apache-poi/LICENSE").is_file()
    assert (FIXTURES / "apache-poi/NOTICE").is_file()
    identifiers = set()
    checked = []
    for fixture in manifest["fixtures"]:
        assert fixture["id"] not in identifiers
        identifiers.add(fixture["id"])
        path = (FIXTURES / fixture["path"]).resolve()
        assert path.is_relative_to(FIXTURES.resolve()), "Manifest path escapes fixture root"
        data = path.read_bytes()
        assert len(data) == fixture["bytes"], f"{path.name}: changed byte length"
        assert hashlib.sha256(data).hexdigest() == fixture["sha256"], f"{path.name}: changed SHA256"
        if fixture["origin"] == "upstream-regression-fixture":
            assert fixture["upstreamCommit"] in fixture["source"]
            assert fixture["upstreamCommit"] in fixture["download"]
        checked.append({"id": fixture["id"], "sha256": fixture["sha256"], "parts": inspect(path)})
    assert len(checked) == 13
    return {"schemaVersion": 1, "inputValidation": "passed", "browserExecuted": False, "visualReferenceStatus": "not-yet-reviewed", "authoredContracts": authored_contracts(), "fixtures": checked}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    result = verify()
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(result, indent=2) + "\n")
    print(f"Verified {len(result['fixtures'])} pinned Office fixtures and authored geometry contracts.")
    print("No browser was launched. Visual comparison is not verified by this check.")
