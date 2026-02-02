import boto3
import json
import os
import logging
import urllib.parse
import io
from pypdf import PdfReader

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3 = boto3.client('s3')
bedrock = boto3.client('bedrock-runtime', region_name=os.environ.get('AWS_REGION', 'ap-southeast-1'))
glue = boto3.client('glue')

def lambda_handler(event, context):
    bucket = event['Records'][0]['s3']['bucket']['name']
    key = urllib.parse.unquote_plus(event['Records'][0]['s3']['object']['key'])
    
    logger.info(f"Processing VAPT PDF: s3://{bucket}/{key}")
    
    # Extract system name from path: inputs/VAPT/{SystemName}/file.pdf
    path_parts = key.split('/')
    system_name = path_parts[2] if len(path_parts) > 2 else 'unknown'
    
    # Read PDF text
    pdf_text = extract_pdf_text(bucket, key)
    if not pdf_text:
        return {"status": "Failed", "error": "Could not extract PDF text"}
    
    # Use LLM to extract structured vulnerability data
    vulnerabilities = extract_vulnerabilities_with_llm(pdf_text, system_name)
    
    if not vulnerabilities:
        return {"status": "Failed", "error": "No vulnerabilities extracted"}
    
    # Save as CSV
    csv_content = convert_to_csv(vulnerabilities)
    output_key = f"processed/vapt/{system_name}/vulnerabilities.csv"
    
    s3.put_object(Bucket=bucket, Key=output_key, Body=csv_content)
    logger.info(f"Saved {len(vulnerabilities)} vulnerabilities to {output_key}")
    
    # Trigger Glue crawler
    start_crawler()
    
    return {"status": "Success", "count": len(vulnerabilities)}

def extract_pdf_text(bucket, key):
    try:
        response = s3.get_object(Bucket=bucket, Key=key)
        reader = PdfReader(io.BytesIO(response['Body'].read()))
        text = ""
        for page in reader.pages:
            text += page.extract_text() + "\n"
        return text[:50000]  # Limit to 50k chars for LLM context
    except Exception as e:
        logger.error(f"PDF extraction error: {e}")
        return None

def extract_vulnerabilities_with_llm(pdf_text, system_name):
    prompt = f"""Extract ALL vulnerabilities from this VAPT report as JSON array.

For each vulnerability, extract:
- cve_id: CVE identifier if present, otherwise "N/A"
- title: vulnerability name/title
- severity: Critical/High/Medium/Low/Info
- cvss_score: numeric score if present, otherwise null
- affected_host: IP/hostname affected
- status: Open/Closed/Remediated
- description: brief description
- recommendation: remediation recommendation

Return ONLY valid JSON array, no other text.

VAPT Report for {system_name}:
{pdf_text}

JSON:"""

    response = bedrock.invoke_model(
        modelId=os.environ.get('MODEL_ID', 'anthropic.claude-3-sonnet-20240229-v1:0'),
        body=json.dumps({
            "anthropic_version": "bedrock-2023-05-31",
            "max_tokens": 8000,
            "messages": [{"role": "user", "content": prompt}]
        })
    )
    
    result = json.loads(response['body'].read())
    content = result['content'][0]['text']
    
    # Parse JSON from response
    try:
        # Handle markdown code blocks
        if '```json' in content:
            content = content.split('```json')[1].split('```')[0]
        elif '```' in content:
            content = content.split('```')[1].split('```')[0]
        return json.loads(content.strip())
    except json.JSONDecodeError as e:
        logger.error(f"JSON parse error: {e}")
        return []

def convert_to_csv(vulnerabilities):
    headers = ['cve_id', 'title', 'severity', 'cvss_score', 'affected_host', 'status', 'description', 'recommendation']
    lines = [','.join(headers)]
    
    for v in vulnerabilities:
        row = []
        for h in headers:
            val = str(v.get(h, '')).replace('"', '""').replace('\n', ' ')
            row.append(f'"{val}"')
        lines.append(','.join(row))
    
    return '\n'.join(lines)

def start_crawler():
    crawler_name = f"{os.environ.get('PROJECT_NAME', 'compliance-reporting')}-log-crawler"
    try:
        glue.start_crawler(Name=crawler_name)
        logger.info(f"Started crawler: {crawler_name}")
    except glue.exceptions.CrawlerRunningException:
        logger.info("Crawler already running")
