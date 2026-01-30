import json
import boto3
import os
import base64
import urllib.parse

s3_client = boto3.client('s3')
bedrock_runtime = boto3.client('bedrock-runtime')
dynamodb = boto3.resource('dynamodb')

BEDROCK_MODEL_ID = os.environ.get('BEDROCK_MODEL_ID', 'anthropic.claude-3-5-sonnet-20240620-v1:0')
POLICY_BUCKET = os.environ.get('POLICY_BUCKET')
POLICY_PREFIX = os.environ.get('POLICY_PREFIX', 'inputs/policy/')
DYNAMODB_TABLE = os.environ.get('DYNAMODB_TABLE')

def lambda_handler(event, context):
    try:
        # Detect if S3 trigger or direct invoke
        if 'Records' in event and event['Records'][0].get('s3'):
            # S3 trigger - extract and cache
            bucket = event['Records'][0]['s3']['bucket']['name']
            key = urllib.parse.unquote_plus(event['Records'][0]['s3']['object']['key'])
            print(f"S3 trigger: indexing {key}")
            
            sections = extract_and_cache(bucket, key)
            return {'statusCode': 200, 'indexed': key, 'sections': len(sections)}
        
        # Direct invoke - fetch sections
        policy_file = event.get('policy_file') or get_latest_policy_file()
        print(f"Fetching sections for: {policy_file}")
        
        # Try cache first
        if DYNAMODB_TABLE:
            sections = get_from_cache(policy_file)
            if sections:
                return {'statusCode': 200, 'policy_file': policy_file, 'sections': sections, 'section_count': len(sections), 'source': 'cache'}
        
        # Cache miss - extract and cache
        sections = extract_and_cache(POLICY_BUCKET, policy_file)
        return {'statusCode': 200, 'policy_file': policy_file, 'sections': sections, 'section_count': len(sections), 'source': 'bedrock'}
        
    except Exception as e:
        print(f"Error: {str(e)}")
        return {'statusCode': 200, 'sections': ["Error - Check CloudWatch Logs"], 'error': str(e)}

def get_from_cache(policy_file):
    try:
        table = dynamodb.Table(DYNAMODB_TABLE)
        response = table.get_item(Key={'policy_file': policy_file})
        return response.get('Item', {}).get('sections')
    except:
        return None

def extract_and_cache(bucket, key):
    pdf_bytes = s3_client.get_object(Bucket=bucket, Key=key)['Body'].read()
    sections = extract_sections(pdf_bytes)
    
    if DYNAMODB_TABLE:
        table = dynamodb.Table(DYNAMODB_TABLE)
        table.put_item(Item={'policy_file': key, 'sections': sections, 'section_count': len(sections)})
        print(f"Cached {len(sections)} sections for {key}")
    
    return sections

def extract_sections(pdf_bytes):
    encoded = base64.b64encode(pdf_bytes).decode('utf-8')
    
    response = bedrock_runtime.invoke_model(
        modelId=BEDROCK_MODEL_ID,
        body=json.dumps({
            "anthropic_version": "bedrock-2023-05-31",
            "max_tokens": 2000,
            "temperature": 0,
            "messages": [{
                "role": "user",
                "content": [
                    {"type": "document", "source": {"type": "base64", "media_type": "application/pdf", "data": encoded}},
                    {"type": "text", "text": "Extract all section numbers and titles containing auditable technical controls. Return ONLY a JSON array like [\"5.1 - Password Policy\"]. No other text."}
                ]
            }]
        })
    )
    
    text = json.loads(response['body'].read())['content'][0]['text'].strip()
    if "```" in text:
        text = text.split("```json")[-1].split("```")[0].strip() if "```json" in text else text.split("```")[1].split("```")[0].strip()
    
    return json.loads(text)

def get_latest_policy_file():
    response = s3_client.list_objects_v2(Bucket=POLICY_BUCKET, Prefix=POLICY_PREFIX)
    pdf_files = [obj for obj in response.get('Contents', []) if obj['Key'].lower().endswith('.pdf') and obj['Size'] > 0]
    if not pdf_files:
        raise Exception("No PDF files found")
    return sorted(pdf_files, key=lambda x: x['LastModified'], reverse=True)[0]['Key']
