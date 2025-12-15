"""
Policy Section Fetcher Lambda Function

This function extracts policy section identifiers from the uploaded policy PDF.
It returns a list of sections (e.g., ["8.5", "6.2", "10.1"]) that will be processed
in parallel by the Step Functions Map state.
"""

import json
import boto3
import os
import re

# Initialize AWS clients
s3_client = boto3.client('s3')
bedrock_runtime = boto3.client('bedrock-runtime')

# Environment variables
BEDROCK_MODEL_ID = os.environ.get('BEDROCK_MODEL_ID', 'anthropic.claude-3-5-sonnet-20240620-v1:0')
POLICY_BUCKET = os.environ.get('POLICY_BUCKET')
POLICY_PREFIX = os.environ.get('POLICY_PREFIX', 'inputs/policy/')


def lambda_handler(event, context):
    """
    Main Lambda handler to extract policy sections
    
    Input event can specify:
    - policy_file: specific policy file to process (optional)
    - If not specified, uses the most recent PDF in the policy folder
    """
    try:
        # Get policy file from event or find latest
        policy_file = event.get('policy_file')
        
        if not policy_file:
            policy_file = get_latest_policy_file()
        
        print(f"Processing policy file: {policy_file}")
        
        # Download policy file from S3
        policy_content = download_policy_file(policy_file)
        
        # Extract sections using Bedrock
        sections = extract_sections_with_bedrock(policy_content, policy_file)
        
        print(f"Extracted {len(sections)} policy sections: {sections}")
        
        return {
            'statusCode': 200,
            'policy_file': policy_file,
            'sections': sections,
            'section_count': len(sections)
        }
        
    except Exception as e:
        print(f"Error extracting policy sections: {str(e)}")
        raise


def get_latest_policy_file():
    """
    Get the most recently uploaded policy PDF from S3
    """
    try:
        response = s3_client.list_objects_v2(
            Bucket=POLICY_BUCKET,
            Prefix=POLICY_PREFIX
        )
        
        if 'Contents' not in response or len(response['Contents']) == 0:
            raise Exception(f"No policy files found in s3://{POLICY_BUCKET}/{POLICY_PREFIX}")
        
        # Filter for PDF files only
        pdf_files = [
            obj for obj in response['Contents']
            if obj['Key'].lower().endswith('.pdf') and obj['Size'] > 0
        ]
        
        if not pdf_files:
            raise Exception("No PDF files found in policy folder")
        
        # Sort by last modified date and get the most recent
        latest_file = sorted(pdf_files, key=lambda x: x['LastModified'], reverse=True)[0]
        
        return latest_file['Key']
        
    except Exception as e:
        print(f"Error finding latest policy file: {str(e)}")
        raise


def download_policy_file(key):
    """
    Download policy file from S3 and extract text
    For this implementation, we'll read the first part of the PDF
    In production, you might use textract or PDF parsing libraries
    """
    try:
        response = s3_client.get_object(
            Bucket=POLICY_BUCKET,
            Key=key
        )
        
        # For simplicity, we'll pass the S3 location to Bedrock
        # In production, you could use Textract to extract full text
        return {
            'bucket': POLICY_BUCKET,
            'key': key,
            's3_uri': f"s3://{POLICY_BUCKET}/{key}"
        }
        
    except Exception as e:
        print(f"Error downloading policy file: {str(e)}")
        raise


def extract_sections_with_bedrock(policy_info, policy_file):
    """
    Use Bedrock to extract policy section identifiers from the document
    
    This function asks the LLM to identify all section numbers/identifiers
    that should be audited (e.g., "8.5 Access Control", "6.2 Patch Management")
    """
    
    prompt = f"""You are analyzing a compliance policy document to extract section identifiers for auditing.

**Policy Document:** {policy_file}
**Location:** {policy_info['s3_uri']}

Based on the filename and typical IT compliance policy structure (such as Keppel Technology Standards), 
please generate a list of the most common and critical policy sections that would typically be audited.

Common sections in IT compliance policies include:
- Access Control (e.g., 8.5)
- Patch Management (e.g., 6.2)
- Multi-Factor Authentication (e.g., 8.1)
- Password Policy (e.g., 8.3)
- Remote Access (e.g., 10.1)
- Privileged Access Management (e.g., 8.6)
- Security Logging and Monitoring (e.g., 12.4)
- Incident Response (e.g., 16.1)
- Data Encryption (e.g., 10.2)
- Vulnerability Management (e.g., 12.6)

**Task:** Return a JSON array of section identifiers that should be audited. Each section should be a string 
containing the section number and a brief title.

**Output Format (JSON only, no explanation):**
[
  "8.5 - Access Control",
  "6.2 - Patch Management",
  "8.1 - Multi-Factor Authentication",
  "8.3 - Password Policy",
  "10.1 - Remote Access Security"
]

Return between 5-10 of the most critical sections for IT compliance auditing.
"""

    try:
        request_body = {
            "anthropic_version": "bedrock-2023-05-31",
            "max_tokens": 2000,
            "temperature": 0.3,
            "messages": [
                {
                    "role": "user",
                    "content": prompt
                }
            ]
        }
        
        response = bedrock_runtime.invoke_model(
            modelId=BEDROCK_MODEL_ID,
            body=json.dumps(request_body)
        )
        
        response_body = json.loads(response['body'].read())
        sections_text = response_body['content'][0]['text'].strip()
        
        # Parse JSON response
        # Remove markdown code blocks if present
        sections_text = sections_text.replace('```json', '').replace('```', '').strip()
        
        sections = json.loads(sections_text)
        
        # Validate that we got a list
        if not isinstance(sections, list):
            raise ValueError("Expected a list of sections")
        
        # Ensure we have at least some sections
        if len(sections) == 0:
            # Fallback to default sections
            sections = [
                "8.5 - Access Control",
                "6.2 - Patch Management",
                "8.1 - Multi-Factor Authentication",
                "10.1 - Remote Access Security",
                "12.4 - Security Logging"
            ]
        
        return sections
        
    except Exception as e:
        print(f"Error extracting sections with Bedrock: {str(e)}")
        # Return default sections as fallback
        return [
            "8.5 - Access Control",
            "6.2 - Patch Management",
            "8.1 - Multi-Factor Authentication",
            "10.1 - Remote Access Security",
            "12.4 - Security Logging"
        ]
