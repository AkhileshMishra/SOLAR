"""
VAPT/Qualys Processor Lambda
Extracts vulnerability data from VAPT and Qualys reports for patching compliance validation.
"""

import json
import boto3
import os
import re
from datetime import datetime, timedelta
import csv
import io

s3_client = boto3.client('s3')
bedrock = boto3.client('bedrock-runtime')

BUCKET_NAME = os.environ.get('BUCKET_NAME')
BEDROCK_MODEL = os.environ.get('BEDROCK_MODEL_ID', 'anthropic.claude-3-5-sonnet-20240620-v1:0')

# Policy compliance timeframes (days)
COMPLIANCE_TIMEFRAMES = {
    'CRITICAL': 30,
    'HIGH': 90,
    'MEDIUM': 180,
    'LOW': 365
}


def lambda_handler(event, context):
    """
    Process VAPT and Qualys reports for a system.
    Returns vulnerability data with compliance status.
    """
    system_name = event.get('system_name', '')
    
    if not system_name:
        return {'statusCode': 400, 'error': 'system_name required'}
    
    print(f"Processing VAPT/Qualys for system: {system_name}")
    
    result = {
        'system_name': system_name,
        'vapt_data': [],
        'qualys_data': [],
        'vapt_found': False,
        'qualys_found': False,
        'gaps': []
    }
    
    # Process VAPT reports
    vapt_prefix = f"inputs/VAPT/{system_name}/"
    vapt_files = list_s3_files(vapt_prefix)
    
    if vapt_files:
        result['vapt_found'] = True
        for file_key in vapt_files:
            vulnerabilities = extract_vulnerabilities(file_key, 'VAPT')
            result['vapt_data'].extend(vulnerabilities)
    else:
        result['gaps'].append(f"No VAPT reports found for {system_name}")
    
    # Process Qualys reports
    qualys_prefix = f"inputs/QUALYS/{system_name}/"
    qualys_files = list_s3_files(qualys_prefix)
    
    if qualys_files:
        result['qualys_found'] = True
        for file_key in qualys_files:
            vulnerabilities = extract_vulnerabilities(file_key, 'QUALYS')
            result['qualys_data'].extend(vulnerabilities)
    else:
        result['gaps'].append(f"No Qualys reports found for {system_name}")
    
    # Merge and deduplicate vulnerabilities
    all_vulnerabilities = merge_vulnerabilities(result['vapt_data'], result['qualys_data'])
    
    # Calculate compliance deadlines
    for vuln in all_vulnerabilities:
        vuln['compliance_deadline'] = calculate_deadline(vuln)
        vuln['compliance_status'] = 'PENDING_VALIDATION'
    
    result['vulnerabilities'] = all_vulnerabilities
    result['total_count'] = len(all_vulnerabilities)
    result['by_severity'] = count_by_severity(all_vulnerabilities)
    
    return {
        'statusCode': 200,
        'body': result
    }


def list_s3_files(prefix):
    """List files in S3 with given prefix."""
    try:
        response = s3_client.list_objects_v2(Bucket=BUCKET_NAME, Prefix=prefix)
        files = []
        for obj in response.get('Contents', []):
            key = obj['Key']
            if key != prefix and not key.endswith('/'):
                files.append(key)
        return files
    except Exception as e:
        print(f"Error listing S3 files: {e}")
        return []


def extract_vulnerabilities(file_key, source_type):
    """Extract vulnerability data from file using appropriate parser."""
    try:
        file_ext = file_key.lower().split('.')[-1]
        
        response = s3_client.get_object(Bucket=BUCKET_NAME, Key=file_key)
        content = response['Body'].read()
        
        if file_ext == 'csv':
            return parse_csv_vulnerabilities(content, source_type, file_key)
        elif file_ext == 'json':
            return parse_json_vulnerabilities(content, source_type, file_key)
        elif file_ext == 'pdf':
            return parse_pdf_vulnerabilities(content, source_type, file_key)
        else:
            print(f"Unsupported file format: {file_ext}")
            return []
    except Exception as e:
        print(f"Error extracting from {file_key}: {e}")
        return []


def parse_csv_vulnerabilities(content, source_type, file_key):
    """Parse CSV vulnerability report."""
    vulnerabilities = []
    try:
        text = content.decode('utf-8')
        reader = csv.DictReader(io.StringIO(text))
        
        for row in reader:
            vuln = normalize_vulnerability(row, source_type, file_key)
            if vuln:
                vulnerabilities.append(vuln)
    except Exception as e:
        print(f"CSV parse error: {e}")
    return vulnerabilities


def parse_json_vulnerabilities(content, source_type, file_key):
    """Parse JSON vulnerability report."""
    vulnerabilities = []
    try:
        data = json.loads(content.decode('utf-8'))
        items = data if isinstance(data, list) else data.get('vulnerabilities', [])
        
        for item in items:
            vuln = normalize_vulnerability(item, source_type, file_key)
            if vuln:
                vulnerabilities.append(vuln)
    except Exception as e:
        print(f"JSON parse error: {e}")
    return vulnerabilities


def parse_pdf_vulnerabilities(content, source_type, file_key):
    """Use Bedrock to extract vulnerabilities from PDF."""
    try:
        import base64
        pdf_b64 = base64.b64encode(content).decode('utf-8')
        
        prompt = """Extract all vulnerabilities from this security report. For each vulnerability, provide:
- vulnerability_id: CVE ID or internal ID
- title: Brief description
- severity: CRITICAL, HIGH, MEDIUM, or LOW
- identified_date: Date discovered (YYYY-MM-DD format)
- recommended_fix: Patch or remediation action
- affected_component: System/software affected

Return as JSON array. If no vulnerabilities found, return empty array []."""

        response = bedrock.invoke_model(
            modelId=BEDROCK_MODEL,
            body=json.dumps({
                "anthropic_version": "bedrock-2023-05-31",
                "max_tokens": 4096,
                "messages": [{
                    "role": "user",
                    "content": [
                        {"type": "document", "source": {"type": "base64", "media_type": "application/pdf", "data": pdf_b64}},
                        {"type": "text", "text": prompt}
                    ]
                }]
            })
        )
        
        result = json.loads(response['Body'].read())
        text = result['content'][0]['text']
        
        # Extract JSON from response
        json_match = re.search(r'\[.*\]', text, re.DOTALL)
        if json_match:
            items = json.loads(json_match.group())
            return [normalize_vulnerability(item, source_type, file_key) for item in items if item]
    except Exception as e:
        print(f"PDF parse error: {e}")
    return []


def normalize_vulnerability(data, source_type, file_key):
    """Normalize vulnerability data to standard format."""
    # Map common field names
    field_mappings = {
        'vulnerability_id': ['vulnerability_id', 'cve', 'cve_id', 'vuln_id', 'id', 'qid'],
        'title': ['title', 'name', 'vulnerability', 'description', 'vuln_name'],
        'severity': ['severity', 'risk', 'risk_level', 'criticality', 'priority'],
        'identified_date': ['identified_date', 'date', 'discovered', 'first_detected', 'detection_date'],
        'recommended_fix': ['recommended_fix', 'fix', 'solution', 'remediation', 'patch'],
        'affected_component': ['affected_component', 'component', 'asset', 'host', 'system']
    }
    
    vuln = {'source': source_type, 'source_file': file_key}
    
    for standard_field, possible_names in field_mappings.items():
        for name in possible_names:
            # Check both exact and case-insensitive matches
            value = data.get(name) or data.get(name.upper()) or data.get(name.lower())
            if value:
                vuln[standard_field] = str(value).strip()
                break
        if standard_field not in vuln:
            vuln[standard_field] = ''
    
    # Normalize severity
    severity = vuln.get('severity', '').upper()
    if 'CRIT' in severity:
        vuln['severity'] = 'CRITICAL'
    elif 'HIGH' in severity or severity in ['4', '5']:
        vuln['severity'] = 'HIGH'
    elif 'MED' in severity or severity == '3':
        vuln['severity'] = 'MEDIUM'
    elif 'LOW' in severity or severity in ['1', '2']:
        vuln['severity'] = 'LOW'
    else:
        vuln['severity'] = 'MEDIUM'  # Default
    
    return vuln if vuln.get('vulnerability_id') or vuln.get('title') else None


def merge_vulnerabilities(vapt_data, qualys_data):
    """Merge and deduplicate vulnerabilities from both sources."""
    merged = {}
    
    for vuln in vapt_data + qualys_data:
        key = vuln.get('vulnerability_id') or vuln.get('title', '')
        if key:
            if key not in merged:
                merged[key] = vuln
            else:
                # Merge sources
                merged[key]['source'] = f"{merged[key]['source']}, {vuln['source']}"
    
    return list(merged.values())


def calculate_deadline(vuln):
    """Calculate compliance deadline based on severity and identification date."""
    severity = vuln.get('severity', 'MEDIUM')
    days = COMPLIANCE_TIMEFRAMES.get(severity, 180)
    
    identified_date = vuln.get('identified_date', '')
    if identified_date:
        try:
            date_obj = datetime.strptime(identified_date[:10], '%Y-%m-%d')
            deadline = date_obj + timedelta(days=days)
            return deadline.strftime('%Y-%m-%d')
        except:
            pass
    return 'UNKNOWN'


def count_by_severity(vulnerabilities):
    """Count vulnerabilities by severity level."""
    counts = {'CRITICAL': 0, 'HIGH': 0, 'MEDIUM': 0, 'LOW': 0}
    for vuln in vulnerabilities:
        severity = vuln.get('severity', 'MEDIUM')
        counts[severity] = counts.get(severity, 0) + 1
    return counts
