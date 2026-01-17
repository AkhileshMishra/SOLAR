import json
import boto3
import os
import base64

s3_client = boto3.client('s3')
bedrock_runtime = boto3.client('bedrock-runtime')
dynamodb = boto3.resource('dynamodb')

BEDROCK_MODEL_ID = os.environ.get('BEDROCK_MODEL_ID', 'anthropic.claude-3-5-sonnet-20240620-v1:0')
POLICY_BUCKET = os.environ.get('POLICY_BUCKET')
POLICY_PREFIX = os.environ.get('POLICY_PREFIX', 'inputs/policy/')
DYNAMODB_TABLE = os.environ.get('DYNAMODB_TABLE')

def lambda_handler(event, context):
    try:
        policy_file = event.get('policy_file') or get_latest_policy_file()
        print(f"Processing policy file: {policy_file}")
        
        # Try DynamoDB first (pre-indexed)
        if DYNAMODB_TABLE:
            sections = get_sections_from_dynamodb(policy_file)
            if sections:
                print(f"Found {len(sections)} sections in DynamoDB cache")
                return {
                    'statusCode': 200,
                    'policy_file': policy_file,
                    'sections': sections,
                    'section_count': len(sections),
                    'source': 'cache'
                }
        
        # Fallback: extract via Bedrock
        print("Cache miss - extracting via Bedrock")
        policy_bytes = download_policy_bytes(policy_file)
        sections = extract_sections_with_bedrock(policy_bytes)
        
        return {
            'statusCode': 200,
            'policy_file': policy_file,
            'sections': sections,
            'section_count': len(sections),
            'source': 'bedrock'
        }
        
    except Exception as e:
        print(f"Error: {str(e)}")
        return {
            'statusCode': 200,
            'policy_file': event.get('policy_file', 'Unknown'),
            'sections': ["Error reading PDF - Check CloudWatch Logs"],
            'error': str(e)
        }

def get_sections_from_dynamodb(policy_file):
    try:
        table = dynamodb.Table(DYNAMODB_TABLE)
        response = table.get_item(Key={'policy_file': policy_file})
        if 'Item' in response:
            return response['Item'].get('sections', [])
    except Exception as e:
        print(f"DynamoDB lookup failed: {e}")
    return None

def get_latest_policy_file():
    response = s3_client.list_objects_v2(Bucket=POLICY_BUCKET, Prefix=POLICY_PREFIX)
    pdf_files = [obj for obj in response.get('Contents', []) if obj['Key'].lower().endswith('.pdf') and obj['Size'] > 0]
    if not pdf_files:
        raise Exception("No PDF files found")
    return sorted(pdf_files, key=lambda x: x['LastModified'], reverse=True)[0]['Key']

def download_policy_bytes(key):
    return s3_client.get_object(Bucket=POLICY_BUCKET, Key=key)['Body'].read()

def extract_sections_with_bedrock(file_bytes):
    encoded_pdf = base64.b64encode(file_bytes).decode("utf-8")
    
    response = bedrock_runtime.invoke_model(
        modelId=BEDROCK_MODEL_ID,
        body=json.dumps({
            "anthropic_version": "bedrock-2023-05-31",
            "max_tokens": 2000,
            "temperature": 0,
            "messages": [{
                "role": "user",
                "content": [
                    {"type": "document", "source": {"type": "base64", "media_type": "application/pdf", "data": encoded_pdf}},
                    {"type": "text", "text": "Extract all section numbers and titles containing auditable technical controls. Return ONLY a JSON array like [\"5.1 - Password Policy\"]. No other text."}
                ]
            }]
        })
    )
    
    body = json.loads(response['body'].read())
    text = body['content'][0]['text'].strip()
    
    if "```json" in text:
        text = text.split("```json")[1].split("```")[0].strip()
    elif "```" in text:
        text = text.split("```")[1].split("```")[0].strip()
        
    return json.loads(text)
