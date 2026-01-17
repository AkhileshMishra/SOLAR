import json
import boto3
import os
import base64
import urllib.parse

dynamodb = boto3.resource('dynamodb')
s3 = boto3.client('s3')
bedrock = boto3.client('bedrock-runtime')

TABLE_NAME = os.environ.get('DYNAMODB_TABLE')
MODEL_ID = os.environ.get('BEDROCK_MODEL_ID', 'anthropic.claude-3-5-sonnet-20240620-v1:0')

def lambda_handler(event, context):
    bucket = event['Records'][0]['s3']['bucket']['name']
    key = urllib.parse.unquote_plus(event['Records'][0]['s3']['object']['key'])
    
    print(f"Processing: s3://{bucket}/{key}")
    
    # Download PDF
    response = s3.get_object(Bucket=bucket, Key=key)
    pdf_bytes = response['Body'].read()
    
    # Extract sections via Bedrock
    sections = extract_sections(pdf_bytes)
    
    # Store in DynamoDB
    table = dynamodb.Table(TABLE_NAME)
    table.put_item(Item={
        'policy_file': key,
        'sections': sections,
        'section_count': len(sections)
    })
    
    print(f"Indexed {len(sections)} sections for {key}")
    return {'statusCode': 200, 'sections': len(sections)}

def extract_sections(pdf_bytes):
    encoded = base64.b64encode(pdf_bytes).decode('utf-8')
    
    response = bedrock.invoke_model(
        modelId=MODEL_ID,
        body=json.dumps({
            "anthropic_version": "bedrock-2023-05-31",
            "max_tokens": 2000,
            "temperature": 0,
            "messages": [{
                "role": "user",
                "content": [
                    {"type": "document", "source": {"type": "base64", "media_type": "application/pdf", "data": encoded}},
                    {"type": "text", "text": "Extract all section numbers and titles containing auditable technical controls. Return ONLY a JSON array like [\"5.1 - Password Policy\", \"9.2 - Access Control\"]. No other text."}
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
