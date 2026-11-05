"""Rebuild project-owned Office layout fixtures, never visual reference images.

Requires python-docx, python-pptx, openpyxl and Pillow. The checked-in binaries
are the CI inputs; CI does not install these generators or update the fixtures.
"""

from datetime import datetime
from io import BytesIO
import hashlib
import json
from pathlib import Path
import zipfile

from PIL import Image, ImageDraw
from docx import Document
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Inches, Pt, RGBColor
from pptx import Presentation
from pptx.chart.data import CategoryChartData
from pptx.dml.color import RGBColor as PptColor
from pptx.enum.chart import XL_CHART_TYPE
from pptx.enum.shapes import MSO_SHAPE
from pptx.util import Inches as PptInches, Pt as PptPt
from openpyxl import Workbook
from openpyxl.chart import BarChart, Reference
from openpyxl.drawing.image import Image as SheetImage
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / "test/fixtures/office_preview"
FIXED_DATE = datetime(2020, 1, 1)


def normalize(path):
    """Stable ZIP timestamps and order; preserve all Office content parts."""
    source = path.read_bytes()
    with zipfile.ZipFile(BytesIO(source)) as original:
        with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as target:
            for name in sorted(original.namelist()):
                info = zipfile.ZipInfo(name, (2020, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                target.writestr(info, original.read(name))


def picture():
    image = Image.new("RGB", (200, 100), "#1473C0")
    draw = ImageDraw.Draw(image)
    draw.rectangle((0, 0, 99, 99), fill="#E15554")
    draw.ellipse((125, 25, 175, 75), fill="#FFCC33")
    output = BytesIO()
    image.save(output, format="PNG")
    return output.getvalue()


def make_word():
    doc = Document()
    props = doc.core_properties
    props.author = "BaoCode test fixture"
    props.created = props.modified = FIXED_DATE
    props.title = "Office layout acceptance fixture"
    section = doc.sections[0]
    section.page_width, section.page_height = Inches(8.5), Inches(11)
    section.top_margin = section.bottom_margin = Inches(0.75)
    section.left_margin = section.right_margin = Inches(0.75)
    normal = doc.styles["Normal"]
    normal.font.name, normal.font.size = "Arial", Pt(11)
    section.header.paragraphs[0].text = "CONFIDENTIALITY FREE TEST HEADER"
    section.footer.paragraphs[0].text = "BaoCode layout acceptance footer"
    title = doc.add_paragraph().add_run("Authored layout report")
    title.font.name, title.font.size = "Arial", Pt(24)
    title.font.color.rgb, title.bold = RGBColor.from_string("8E244D"), True
    doc.add_paragraph("Original typography, merged cells and image placement.")
    table = doc.add_table(rows=3, cols=3)
    table.autofit = False
    table.style = "Table Grid"
    for column, width in zip(table.columns, [2, 2, 3]):
        column.width = Inches(width)
    merged = table.cell(0, 0).merge(table.cell(0, 1))
    merged.text = "MERGED HEADER"
    table.cell(0, 2).text = "Budget"
    for row in table.rows:
        row.height = Inches(0.4)
    for c in table.rows[0].cells:
        shade = OxmlElement("w:shd")
        shade.set(qn("w:fill"), "12304A")
        c._tc.get_or_add_tcPr().append(shade)
        for run in c.paragraphs[0].runs:
            run.font.color.rgb = RGBColor(255, 255, 255)
    for index, values in enumerate([["North", "Q1", "$1,234.50"], ["South", "Q2", "$2,345.60"]], 1):
        for cell, text in zip(table.rows[index].cells, values):
            cell.text = text
    doc.add_picture(BytesIO(picture()), width=Inches(2), height=Inches(1))
    doc.add_paragraph("Image remains 2:1 and follows the table.")
    doc.add_page_break()
    doc.add_heading("SECOND PAGE MARKER", level=1)
    doc.add_paragraph("This starts on the second page, not in a reflowed text list.")
    for item in ["First authored list item", "Second authored list item"]:
        doc.add_paragraph(item, style="List Number")
    path = OUT / "authored-layout.docx"
    doc.save(path)
    normalize(path)


def make_slides():
    deck = Presentation()
    deck.core_properties.author = "BaoCode test fixture"
    deck.core_properties.created = deck.core_properties.modified = FIXED_DATE
    deck.slide_width, deck.slide_height = PptInches(12), PptInches(6.75)
    slide = deck.slides.add_slide(deck.slide_layouts[6])
    slide.background.fill.solid()
    slide.background.fill.fore_color.rgb = PptColor.from_string("12304A")
    box = slide.shapes.add_textbox(PptInches(1), PptInches(0.5), PptInches(10), PptInches(0.75))
    paragraph = box.text_frame.paragraphs[0]
    paragraph.text = "POSITION AND COLOR CONTRACT"
    paragraph.font.size, paragraph.font.bold = PptPt(28), True
    paragraph.font.color.rgb = PptColor.from_string("FFFFFF")
    for x, fill, label in [(1, "FFCC33", "LEFT BLOCK"), (8, "DD33AA", "RIGHT BLOCK")]:
        shape = slide.shapes.add_shape(MSO_SHAPE.ROUNDED_RECTANGLE, PptInches(x), PptInches(2), PptInches(3), PptInches(2))
        shape.fill.solid()
        shape.fill.fore_color.rgb = PptColor.from_string(fill)
        shape.text = label
        shape.text_frame.paragraphs[0].font.size = PptPt(22)
        shape.text_frame.paragraphs[0].font.color.rgb = PptColor.from_string("12304A")
    slide.shapes.add_picture(BytesIO(picture()), PptInches(5), PptInches(2), width=PptInches(2), height=PptInches(1))
    table = slide.shapes.add_table(2, 3, PptInches(1), PptInches(4.8), PptInches(10), PptInches(1.2)).table
    table.cell(0, 0).merge(table.cell(0, 1))
    for r, row in enumerate([["MERGED TABLE HEADER", "", "Value"], ["First", "Second", "42"]]):
        for c, text in enumerate(row):
            if text:
                table.cell(r, c).text = text
    chart_slide = deck.slides.add_slide(deck.slide_layouts[6])
    data = CategoryChartData()
    data.categories = ["North", "South", "West"]
    data.add_series("Revenue", (12, 18, 9))
    chart_slide.shapes.add_chart(XL_CHART_TYPE.COLUMN_CLUSTERED, PptInches(1), PptInches(1), PptInches(10), PptInches(4.75), data)
    path = OUT / "authored-layout.pptx"
    deck.save(path)
    normalize(path)


def make_workbook():
    book = Workbook()
    book.properties.creator = "BaoCode test fixture"
    book.properties.created = book.properties.modified = FIXED_DATE
    sheet = book.active
    sheet.title = "Styled budget"
    sheet.merge_cells("A1:F2")
    sheet["A1"] = "MERGED BUDGET TITLE"
    sheet["A1"].font = Font(name="Arial", size=22, bold=True, color="FFFFFF")
    sheet["A1"].fill = PatternFill("solid", fgColor="12304A")
    sheet["A1"].alignment = Alignment(horizontal="center", vertical="center")
    for column, width in {"A": 12, "B": 20, "C": 16, "D": 14, "E": 18, "F": 16}.items():
        sheet.column_dimensions[column].width = width
    for row in [1, 2]:
        sheet.row_dimensions[row].height = 24
    sheet.row_dimensions[3].height = 30
    sheet.freeze_panes = "B4"
    for row in [("Region", "Revenue", "Date", "Change", "Notes", "Count"), ("North", 1234.5, datetime(2020, 1, 2), 0.15, "Wrapped text with two lines", 12), ("South", 2345.6, datetime(2020, 2, 3), -0.05, "Styled border", 18), ("West", 987.65, datetime(2020, 3, 4), 0.20, "No formula evaluation", 9)]:
        sheet.append(row)
    side = Side(style="thin", color="1473C0")
    for row in sheet.iter_rows(min_row=3, max_row=6, min_col=1, max_col=6):
        for cell in row:
            cell.font = Font(name="Arial", size=11, color="12304A")
            cell.border = Border(left=side, right=side, top=side, bottom=side)
            cell.alignment = Alignment(vertical="center", wrap_text=True)
            cell.fill = PatternFill("solid", fgColor="DDEEFF" if cell.row % 2 == 0 else "FFFFFF")
    for row in range(4, 7):
        sheet[f"B{row}"].number_format = '"$"#,##0.00'
        sheet[f"C{row}"].number_format = "yyyy-mm-dd"
        sheet[f"D{row}"].number_format = "0.0%"
    sheet.row_dimensions[4].height = 42
    image = SheetImage(BytesIO(picture()))
    image.width, image.height = 200, 100
    sheet.add_image(image, "A9")
    chart = BarChart()
    chart.title = "Revenue chart"
    chart.add_data(Reference(sheet, min_col=2, min_row=3, max_row=6), titles_from_data=True)
    chart.set_categories(Reference(sheet, min_col=1, min_row=4, max_row=6))
    sheet.add_chart(chart, "D9")
    other = book.create_sheet("Second sheet")
    other["A1"] = "SECOND SHEET MARKER"
    other["A1"].font = Font(size=20, color="8E244D")
    other.column_dimensions["A"].width = 35
    path = OUT / "authored-layout.xlsx"
    book.save(path)
    normalize(path)


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    make_word()
    make_slides()
    make_workbook()
    manifest_path = OUT / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    manifest["fixtures"] = [f for f in manifest["fixtures"] if f["origin"] != "project-authored"]
    for kind in ["docx", "pptx", "xlsx"]:
        path = OUT / f"authored-layout.{kind}"
        data = path.read_bytes()
        manifest["fixtures"].append({"id": f"authored-{kind}", "path": path.name, "kind": kind, "origin": "project-authored", "source": "tool/office_preview/test/generate_fixtures.py", "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data), "license": "GPL-3.0-only", "features": ["authored geometry", "original colors", "images", "tables"], "referenceStatus": "not-yet-reviewed"})
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    print("Generated three layout fixtures. No screenshots or reference approvals were generated.")
