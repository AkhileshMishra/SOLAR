import json
import boto3
import os
import base64

# Initialize AWS clients
s3_client = boto3.client('s3')
bedrock_runtime = boto3.client('bedrock-runtime')

# Environment variables
BEDROCK_MODEL_ID = os.environ.get('BEDROCK_MODEL_ID', 'anthropic.claude-3-5-sonnet-20240620-v1:0')
POLICY_BUCKET = os.environ.get('POLICY_BUCKET')
POLICY_PREFIX = os.environ.get('POLICY_PREFIX', 'inputs/policy/')

def lambda_handler(event, context):
    try:
        # Get policy file from event or find latest
        policy_file = event.get('policy_file')
        
        if not policy_file:
            policy_file = get_latest_policy_file()
        
        print(f"Processing policy file: {policy_file}")
        
        # 1. READ THE ACTUAL FILE CONTENT (Fixes the guessing issue)
        policy_bytes = download_policy_bytes(policy_file)
        
        # 2. SEND CONTENT TO AI TO EXTRACT SECTIONS
        sections = extract_sections_with_bedrock(policy_bytes, policy_file)
        
        print(f"Extracted {len(sections)} policy sections: {sections}")
        
        return {
            'statusCode': 200,
            'policy_file': policy_file,
            'sections': sections,
            'section_count': len(sections)
        }
        
    except Exception as e:
        print(f"Error extracting policy sections: {str(e)}")
        # Fallback only if the real extraction crashes hard
        return {
            'statusCode': 200,
            'policy_file': event.get('policy_file', 'Unknown'),
            'sections': ["Error reading PDF - Check CloudWatch Logs"],
            'error': str(e)
        }

def get_latest_policy_file():
    try:
        response = s3_client.list_objects_v2(Bucket=POLICY_BUCKET, Prefix=POLICY_PREFIX)
        if 'Contents' not in response or len(response['Contents']) == 0:
            raise Exception(f"No policy files found in s3://{POLICY_BUCKET}/{POLICY_PREFIX}")
        
        pdf_files = [obj for obj in response['Contents'] if obj['Key'].lower().endswith('.pdf') and obj['Size'] > 0]
        if not pdf_files:
            raise Exception("No PDF files found in policy folder")
            
        latest_file = sorted(pdf_files, key=lambda x: x['LastModified'], reverse=True)[0]
        return latest_file['Key']
    except Exception as e:
        print(f"Error finding latest policy file: {str(e)}")
        raise

def download_policy_bytes(key):
    """Download the actual bytes of the PDF"""
    try:
        response = s3_client.get_object(Bucket=POLICY_BUCKET, Key=key)
        return response['Body'].read()
    except Exception as e:
        print(f"Error downloading policy file: {str(e)}")
        raise

def extract_sections_with_bedrock(file_bytes, filename):
    """Send PDF bytes to Claude to get REAL sections"""
    
    # Encode PDF for Bedrock
    encoded_pdf = base64.b64encode(file_bytes).decode("utf-8")
    
    prompt = """You are an expert Compliance Officer.
    Analyze the attached policy document.
    Identify the specific section numbers and titles that contain auditable technical controls (e.g., Password History, MFA, Logging).
    
    Return ONLY a JSON array of strings. Format: "Section_Number - Section_Title".
    Example: ["5.1 - Password Policy", "9.2 - Access Control"]
    Do not output any other text."""

    request_body = {
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": 2000,
        "temperature": 0,
        "messages": [
            {
                "role": "user",
                "content": [
                    {
                        "type": "document",
                        "source": {
                            "type": "base64",
                            "media_type": "application/pdf",
                            "data": encoded_pdf
                        }
                    },
                    {
                        "type": "text",
                        "text": prompt
                    }
                ]
            }
        ]
    }

    try:
        response = bedrock_runtime.invoke_model(
            modelId=BEDROCK_MODEL_ID,
            body=json.dumps(request_body)
        )
        
        response_body = json.loads(response['body'].read())
        content_text = response_body['content'][0]['text'].strip()
        
        # Clean up JSON formatting (remove markdown block)
        if "```json" in content_text:
            content_text = content_text.split("```json")[1].split("```")[0].strip()
        elif "```" in content_text:
            content_text = content_text.split("```")[1].split("```")[0].strip()
            
        sections = json.loads(content_text)
        return sections
        
    except Exception as e:
        print(f"Bedrock extraction failed: {str(e)}")
        # Raise exception so the main handler catches it
        raise e