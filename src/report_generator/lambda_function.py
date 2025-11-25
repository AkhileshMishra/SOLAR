"""
Report Generator Lambda Function

This function aggregates compliance findings from the Bedrock Agent analysis
and generates a formatted Microsoft Word (.docx) report.

The report includes:
- Executive Summary
- Findings by Policy Section
- Detailed Evidence from Logs
- Risk Assessment
- Recommendations
"""

import json
import boto3
import os
from datetime import datetime
from docx import Document
from docx.shared import Inches, Pt, RGBColor
from docx.enum.text import WD_ALIGN_PARAGRAPH

# Initialize AWS clients
s3_client = boto3.client('s3')

# Environment variables
OUTPUT_BUCKET = os.environ.get('OUTPUT_BUCKET')
OUTPUT_PREFIX = os.environ.get('OUTPUT_PREFIX', 'outputs/reports/')


def lambda_handler(event, context):
    """
    Main Lambda handler to generate compliance report
    
    Input event structure:
    {
        "policy_file": "inputs/policy/TECH-S01-01.pdf",
        "findings": [
            {
                "section": "8.5 - Access Control",
                "analysis": "...",
                "compliance_status": "NON-COMPLIANT",
                "risk_level": "HIGH",
                "evidence": [...]
            },
            ...
        ]
    }
    """
    try:
        print(f"Received event: {json.dumps(event, default=str)}")
        
        # Parse input
        policy_file = event.get('policy_file', 'Unknown Policy')
        findings = event.get('findings', [])
        
        if not findings:
            raise ValueError("No findings provided to generate report")
        
        # Generate report document
        doc = create_compliance_report(policy_file, findings)
        
        # Save to temporary file
        report_filename = generate_report_filename(policy_file)
        temp_path = f"/tmp/{report_filename}"
        doc.save(temp_path)
        
        # Upload to S3
        s3_key = f"{OUTPUT_PREFIX}{report_filename}"
        s3_client.upload_file(
            temp_path,
            OUTPUT_BUCKET,
            s3_key
        )
        
        report_url = f"s3://{OUTPUT_BUCKET}/{s3_key}"
        print(f"Report generated successfully: {report_url}")
        
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


def create_compliance_report(policy_file, findings):
    """
    Create a formatted Word document with compliance findings
    """
    doc = Document()
    
    # Add title
    title = doc.add_heading('IT Compliance Audit Report', 0)
    title.alignment = WD_ALIGN_PARAGRAPH.CENTER
    
    # Add metadata section
    doc.add_paragraph(f"Policy Document: {policy_file}")
    doc.add_paragraph(f"Report Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S UTC')}")
    doc.add_paragraph(f"Total Sections Audited: {len(findings)}")
    doc.add_paragraph()
    
    # Add executive summary
    add_executive_summary(doc, findings)
    
    # Add page break
    doc.add_page_break()
    
    # Add detailed findings for each section
    add_detailed_findings(doc, findings)
    
    # Add recommendations section
    add_recommendations(doc, findings)
    
    return doc


def add_executive_summary(doc, findings):
    """
    Add executive summary section with overall compliance status
    """
    doc.add_heading('Executive Summary', 1)
    
    # Calculate statistics
    total_sections = len(findings)
    compliant_count = sum(1 for f in findings if f.get('compliance_status') == 'COMPLIANT')
    non_compliant_count = sum(1 for f in findings if f.get('compliance_status') == 'NON-COMPLIANT')
    attention_count = sum(1 for f in findings if f.get('compliance_status') == 'REQUIRES_ATTENTION')
    
    high_risk_count = sum(1 for f in findings if f.get('risk_level') == 'HIGH')
    medium_risk_count = sum(1 for f in findings if f.get('risk_level') == 'MEDIUM')
    low_risk_count = sum(1 for f in findings if f.get('risk_level') == 'LOW')
    
    # Add summary paragraph
    summary_text = f"""This compliance audit report analyzes {total_sections} policy sections against system logs 
from ServiceNow, Cato, Saviynt, and Syslog sources. The analysis was conducted using AI-powered log analysis 
and policy cross-referencing to identify compliance violations and security risks."""
    
    doc.add_paragraph(summary_text)
    doc.add_paragraph()
    
    # Add compliance status table
    doc.add_heading('Compliance Status Overview', 2)
    table = doc.add_table(rows=4, cols=2)
    table.style = 'Light Grid Accent 1'
    
    table.rows[0].cells[0].text = 'Compliance Status'
    table.rows[0].cells[1].text = 'Count'
    table.rows[1].cells[0].text = 'Compliant'
    table.rows[1].cells[1].text = str(compliant_count)
    table.rows[2].cells[0].text = 'Non-Compliant'
    table.rows[2].cells[1].text = str(non_compliant_count)
    table.rows[3].cells[0].text = 'Requires Attention'
    table.rows[3].cells[1].text = str(attention_count)
    
    doc.add_paragraph()
    
    # Add risk level table
    doc.add_heading('Risk Level Distribution', 2)
    risk_table = doc.add_table(rows=4, cols=2)
    risk_table.style = 'Light Grid Accent 1'
    
    risk_table.rows[0].cells[0].text = 'Risk Level'
    risk_table.rows[0].cells[1].text = 'Count'
    risk_table.rows[1].cells[0].text = 'High Risk'
    risk_table.rows[1].cells[1].text = str(high_risk_count)
    risk_table.rows[2].cells[0].text = 'Medium Risk'
    risk_table.rows[2].cells[1].text = str(medium_risk_count)
    risk_table.rows[3].cells[0].text = 'Low Risk'
    risk_table.rows[3].cells[1].text = str(low_risk_count)
    
    doc.add_paragraph()


def add_detailed_findings(doc, findings):
    """
    Add detailed findings for each policy section
    """
    doc.add_heading('Detailed Findings by Policy Section', 1)
    
    for idx, finding in enumerate(findings, 1):
        section = finding.get('section', 'Unknown Section')
        compliance_status = finding.get('compliance_status', 'UNKNOWN')
        risk_level = finding.get('risk_level', 'UNKNOWN')
        analysis = finding.get('analysis', 'No analysis provided')
        evidence = finding.get('evidence', [])
        
        # Section heading
        section_heading = doc.add_heading(f"{idx}. {section}", 2)
        
        # Status and risk badges
        status_para = doc.add_paragraph()
        status_para.add_run(f"Status: {compliance_status}").bold = True
        status_para.add_run(f" | Risk Level: {risk_level}").bold = True
        
        # Analysis text
        doc.add_heading('Analysis', 3)
        doc.add_paragraph(analysis)
        
        # Evidence section
        if evidence:
            doc.add_heading('Evidence from Logs', 3)
            
            # Create evidence table
            evidence_table = doc.add_table(rows=1, cols=4)
            evidence_table.style = 'Light List Accent 1'
            
            # Header row
            header_cells = evidence_table.rows[0].cells
            header_cells[0].text = 'Timestamp'
            header_cells[1].text = 'Source'
            header_cells[2].text = 'User/Entity'
            header_cells[3].text = 'Event Details'
            
            # Add evidence rows
            for ev in evidence[:10]:  # Limit to first 10 evidence items
                row_cells = evidence_table.add_row().cells
                row_cells[0].text = str(ev.get('timestamp', 'N/A'))
                row_cells[1].text = str(ev.get('source', 'N/A'))
                row_cells[2].text = str(ev.get('user', 'N/A'))
                row_cells[3].text = str(ev.get('details', 'N/A'))
        
        doc.add_paragraph()


def add_recommendations(doc, findings):
    """
    Add recommendations section based on findings
    """
    doc.add_page_break()
    doc.add_heading('Recommendations', 1)
    
    # Filter high-risk non-compliant findings
    high_priority = [
        f for f in findings 
        if f.get('risk_level') == 'HIGH' and f.get('compliance_status') == 'NON-COMPLIANT'
    ]
    
    if high_priority:
        doc.add_heading('High Priority Actions', 2)
        for finding in high_priority:
            section = finding.get('section', 'Unknown')
            recommendation = finding.get('recommendation', 'Immediate remediation required')
            
            p = doc.add_paragraph(style='List Bullet')
            p.add_run(f"{section}: ").bold = True
            p.add_run(recommendation)
    
    # General recommendations
    doc.add_heading('General Recommendations', 2)
    general_recs = [
        "Implement automated compliance monitoring and alerting",
        "Conduct regular security awareness training for all users",
        "Review and update access control policies quarterly",
        "Enable multi-factor authentication for all privileged accounts",
        "Establish a formal patch management process with defined SLAs"
    ]
    
    for rec in general_recs:
        doc.add_paragraph(rec, style='List Bullet')


def generate_report_filename(policy_file):
    """
    Generate a timestamped filename for the report
    """
    timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
    policy_name = policy_file.split('/')[-1].replace('.pdf', '')
    return f"Compliance_Report_{policy_name}_{timestamp}.docx"
