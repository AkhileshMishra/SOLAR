"""
Report Generator Lambda Function
Generates compliance reports in both DOCX and HTML formats.
"""

import json
import boto3
import os
from datetime import datetime
from docx import Document
from docx.shared import Pt
from docx.enum.text import WD_ALIGN_PARAGRAPH

s3_client = boto3.client('s3')

OUTPUT_BUCKET = os.environ.get('OUTPUT_BUCKET')
OUTPUT_PREFIX = os.environ.get('OUTPUT_PREFIX', 'outputs/reports/')


def lambda_handler(event, context):
    try:
        print(f"Received event: {json.dumps(event, default=str)}")
        
        policy_file = event.get('policy_file', 'Unknown Policy')
        system_name = event.get('system_name', '')
        findings = event.get('findings', [])
        
        if not findings:
            raise ValueError("No findings provided to generate report")
        
        # Generate DOCX
        doc = create_compliance_report(policy_file, system_name, findings)
        report_filename = generate_report_filename(policy_file, system_name, 'docx')
        temp_docx = f"/tmp/{report_filename}"
        doc.save(temp_docx)
        
        docx_key = f"{OUTPUT_PREFIX}{report_filename}"
        s3_client.upload_file(temp_docx, OUTPUT_BUCKET, docx_key)
        
        # Generate HTML
        html_content = create_html_report(policy_file, system_name, findings)
        html_filename = generate_report_filename(policy_file, system_name, 'html')
        html_key = f"{OUTPUT_PREFIX}{html_filename}"
        s3_client.put_object(
            Bucket=OUTPUT_BUCKET, 
            Key=html_key, 
            Body=html_content, 
            ContentType='text/html'
        )
        
        print(f"Reports generated: docx={docx_key}, html={html_key}")
        
        return {
            'statusCode': 200,
            'report_location': f"s3://{OUTPUT_BUCKET}/{docx_key}",
            'html_location': f"s3://{OUTPUT_BUCKET}/{html_key}",
            'report_filename': report_filename,
            'html_key': html_key,
            's3_bucket': OUTPUT_BUCKET,
            's3_key': docx_key,
            'findings_count': len(findings)
        }
        
    except Exception as e:
        print(f"Error generating report: {str(e)}")
        raise


def create_html_report(policy_file, system_name, findings):
    timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S UTC')
    sections_list = ", ".join([f.get('section', 'Unknown') for f in findings])
    
    html = f"""<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>Compliance Audit Report</title>
    <style>
        body {{ font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; max-width: 900px; margin: 0 auto; padding: 20px; background: #f5f5f5; }}
        .report {{ background: white; padding: 30px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }}
        h1 {{ color: #1976d2; border-bottom: 3px solid #1976d2; padding-bottom: 10px; }}
        h2 {{ color: #333; margin-top: 30px; }}
        h3 {{ color: #555; }}
        .meta {{ background: #e3f2fd; padding: 15px; border-radius: 4px; margin: 20px 0; }}
        .meta p {{ margin: 5px 0; }}
        .finding {{ background: #fafafa; border-left: 4px solid #1976d2; padding: 15px; margin: 20px 0; border-radius: 0 4px 4px 0; }}
        .status {{ font-weight: bold; padding: 5px 10px; border-radius: 4px; display: inline-block; margin: 10px 0; }}
        .status.COMPLIANT {{ background: #c8e6c9; color: #2e7d32; }}
        .status.PARTIALLY_COMPLIANT {{ background: #fff9c4; color: #f9a825; }}
        .status.NON_COMPLIANT {{ background: #ffcdd2; color: #c62828; }}
        .analysis {{ white-space: pre-wrap; line-height: 1.6; }}
        table {{ width: 100%; border-collapse: collapse; margin: 15px 0; }}
        th, td {{ border: 1px solid #ddd; padding: 10px; text-align: left; }}
        th {{ background: #1976d2; color: white; }}
        tr:nth-child(even) {{ background: #f9f9f9; }}
    </style>
</head>
<body>
    <div class="report">
        <h1>📋 IT Compliance Audit Report</h1>
        
        <div class="meta">
            <p><strong>Policy Document:</strong> {policy_file}</p>
            <p><strong>System Validated:</strong> {system_name or 'N/A'}</p>
            <p><strong>Report Generated:</strong> {timestamp}</p>
            <p><strong>Sections Audited:</strong> {len(findings)}</p>
        </div>
        
        <h2>Executive Summary</h2>
        <p>This compliance audit analyzed {len(findings)} policy section(s): {sections_list}.</p>
        {f'<p>The analysis validated controls against {system_name} SOC2 report and available system logs.</p>' if system_name else ''}
        
        <h2>Sections Overview</h2>
        <table>
            <tr><th>Section</th><th>Status</th></tr>
"""
    
    for f in findings:
        status = f.get('compliance_status', 'PARTIALLY_COMPLIANT')
        html += f"""            <tr>
                <td>{f.get('section', 'Unknown')}</td>
                <td><span class="status {status}">{status.replace('_', ' ')}</span></td>
            </tr>
"""
    
    html += """        </table>
        
        <h2>Detailed Findings</h2>
"""
    
    for idx, f in enumerate(findings, 1):
        section = f.get('section', 'Unknown')
        status = f.get('compliance_status', 'PARTIALLY_COMPLIANT')
        analysis = f.get('analysis', 'No analysis provided')
        analysis = analysis.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')
        
        html += f"""
        <div class="finding">
            <h3>{idx}. {section}</h3>
            <span class="status {status}">{status.replace('_', ' ')}</span>
            <h4>Analysis</h4>
            <div class="analysis">{analysis}</div>
        </div>
"""
    
    html += """
    </div>
</body>
</html>"""
    
    return html


def create_compliance_report(policy_file, system_name, findings):
    doc = Document()
    
    title = doc.add_heading('IT Compliance Audit Report', 0)
    title.alignment = WD_ALIGN_PARAGRAPH.CENTER
    
    doc.add_paragraph(f"Policy Document: {policy_file}")
    if system_name:
        doc.add_paragraph(f"System Validated: {system_name}")
    doc.add_paragraph(f"Report Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S UTC')}")
    doc.add_paragraph(f"Sections Audited: {len(findings)}")
    doc.add_paragraph()
    
    add_executive_summary(doc, findings, system_name)
    doc.add_page_break()
    add_detailed_findings(doc, findings)
    
    return doc


def add_executive_summary(doc, findings, system_name):
    doc.add_heading('Executive Summary', 1)
    sections_list = ", ".join([f.get('section', 'Unknown') for f in findings])
    summary = f"This compliance audit analyzed {len(findings)} policy section(s): {sections_list}."
    if system_name:
        summary += f" The analysis validated controls against {system_name} SOC2 report and available system logs."
    doc.add_paragraph(summary)
    doc.add_paragraph()
    
    doc.add_heading('Sections Analyzed', 2)
    table = doc.add_table(rows=1, cols=2)
    table.style = 'Light Grid Accent 1'
    header = table.rows[0].cells
    header[0].text = 'Section'
    header[1].text = 'Status'
    
    for finding in findings:
        row = table.add_row().cells
        row[0].text = finding.get('section', 'Unknown')
        row[1].text = finding.get('compliance_status', 'PARTIALLY_COMPLIANT').replace('_', ' ')


def add_detailed_findings(doc, findings):
    doc.add_heading('Detailed Findings', 1)
    
    for idx, finding in enumerate(findings, 1):
        section = finding.get('section', 'Unknown Section')
        status = finding.get('compliance_status', 'PARTIALLY_COMPLIANT').replace('_', ' ')
        analysis = finding.get('analysis', 'No analysis provided')
        
        doc.add_heading(f"{idx}. {section}", 2)
        status_para = doc.add_paragraph()
        status_para.add_run(f"Status: {status}").bold = True
        doc.add_heading('Analysis', 3)
        doc.add_paragraph(analysis)
        doc.add_paragraph()


def generate_report_filename(policy_file, system_name, ext):
    timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
    policy_name = policy_file.split('/')[-1].replace('.pdf', '')[:30]
    system_suffix = f"_{system_name}" if system_name else ""
    return f"Compliance_Report_{policy_name}{system_suffix}_{timestamp}.{ext}"
