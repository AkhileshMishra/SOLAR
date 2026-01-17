"""
Report Generator Lambda Function
Generates compliance reports based on user-selected sections only.
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
        
        doc = create_compliance_report(policy_file, system_name, findings)
        
        report_filename = generate_report_filename(policy_file, system_name)
        temp_path = f"/tmp/{report_filename}"
        doc.save(temp_path)
        
        s3_key = f"{OUTPUT_PREFIX}{report_filename}"
        s3_client.upload_file(temp_path, OUTPUT_BUCKET, s3_key)
        
        report_url = f"s3://{OUTPUT_BUCKET}/{s3_key}"
        print(f"Report generated: {report_url}")
        
        return {
            'statusCode': 200,
            'report_location': report_url,
            'report_filename': report_filename,
            's3_bucket': OUTPUT_BUCKET,
            's3_key': s3_key,
            'findings_count': len(findings)
        }
        
    except Exception as e:
        print(f"Error generating report: {str(e)}")
        raise


def create_compliance_report(policy_file, system_name, findings):
    doc = Document()
    
    # Title
    title = doc.add_heading('IT Compliance Audit Report', 0)
    title.alignment = WD_ALIGN_PARAGRAPH.CENTER
    
    # Metadata
    doc.add_paragraph(f"Policy Document: {policy_file}")
    if system_name:
        doc.add_paragraph(f"System Validated: {system_name}")
    doc.add_paragraph(f"Report Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S UTC')}")
    doc.add_paragraph(f"Sections Audited: {len(findings)}")
    doc.add_paragraph()
    
    # Executive Summary
    add_executive_summary(doc, findings, system_name)
    
    doc.add_page_break()
    
    # Detailed Findings
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
    
    # Sections analyzed table
    doc.add_heading('Sections Analyzed', 2)
    table = doc.add_table(rows=1, cols=2)
    table.style = 'Light Grid Accent 1'
    
    header = table.rows[0].cells
    header[0].text = 'Section'
    header[1].text = 'Status'
    
    for finding in findings:
        row = table.add_row().cells
        row[0].text = finding.get('section', 'Unknown')
        row[1].text = finding.get('compliance_status', 'REQUIRES_REVIEW')


def add_detailed_findings(doc, findings):
    doc.add_heading('Detailed Findings', 1)
    
    for idx, finding in enumerate(findings, 1):
        section = finding.get('section', 'Unknown Section')
        status = finding.get('compliance_status', 'UNKNOWN')
        risk = finding.get('risk_level', 'UNKNOWN')
        analysis = finding.get('analysis', 'No analysis provided')
        
        # Section heading
        doc.add_heading(f"{idx}. {section}", 2)
        
        # Status line
        status_para = doc.add_paragraph()
        status_para.add_run(f"Status: {status} | Risk: {risk}").bold = True
        
        # Analysis
        doc.add_heading('Analysis', 3)
        doc.add_paragraph(analysis)
        
        doc.add_paragraph()


def generate_report_filename(policy_file, system_name):
    timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
    policy_name = policy_file.split('/')[-1].replace('.pdf', '')[:30]
    system_suffix = f"_{system_name}" if system_name else ""
    return f"Compliance_Report_{policy_name}{system_suffix}_{timestamp}.docx"
