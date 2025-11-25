"""
LogIngestionAgent Lambda Function

This function automatically generates Athena views for uploaded log files using
Generative AI (Amazon Bedrock Claude 3.5 Sonnet).

Workflow:
1. Triggered by S3 event when log file is uploaded to /inputs/logs/
2. Reads first 50 lines of the log file
3. Invokes Bedrock to generate CREATE OR REPLACE VIEW SQL statement
4. Applies source-specific transformation rules
5. Executes the DDL statement via Amazon Athena
"""

import json
import boto3
import os
import time
from urllib.parse import unquote_plus

# Initialize AWS clients
s3_client = boto3.client('s3')
bedrock_runtime = boto3.client('bedrock-runtime')
athena_client = boto3.client('athena')

# Environment variables
GLUE_DATABASE = os.environ.get('GLUE_DATABASE', 'compliance_db')
ATHENA_WORKGROUP = os.environ.get('ATHENA_WORKGROUP', 'compliance_auditor')
BEDROCK_MODEL_ID = os.environ.get('BEDROCK_MODEL_ID', 'anthropic.claude-3-5-sonnet-20240620-v1:0')
ATHENA_OUTPUT_LOCATION = os.environ.get('ATHENA_OUTPUT_LOCATION')


def lambda_handler(event, context):
    """
    Main Lambda handler for S3 event notifications
    """
    try:
        # Parse S3 event
        for record in event['Records']:
            bucket = record['s3']['bucket']['name']
            key = unquote_plus(record['s3']['object']['key'])
            
            print(f"Processing file: s3://{bucket}/{key}")
            
            # Extract filename without path and extension
            filename = key.split('/')[-1]
            base_name = filename.rsplit('.', 1)[0]
            
            # Determine source type from filename
            source_type = detect_source_type(filename)
            print(f"Detected source type: {source_type}")
            
            # Read first 50 lines of the file
            log_sample = read_log_sample(bucket, key, lines=50)
            
            # Generate Athena view DDL using Bedrock
            ddl_statement = generate_ddl_with_bedrock(
                log_sample=log_sample,
                filename=filename,
                source_type=source_type,
                s3_location=f"s3://{bucket}/{key}"
            )
            
            print(f"Generated DDL:\n{ddl_statement}")
            
            # Execute DDL via Athena
            execution_id = execute_athena_query(ddl_statement)
            
            print(f"Athena query execution ID: {execution_id}")
            
            # Wait for query completion
            wait_for_query_completion(execution_id)
            
            print(f"Successfully created view for {filename}")
        
        return {
            'statusCode': 200,
            'body': json.dumps('Log ingestion completed successfully')
        }
        
    except Exception as e:
        print(f"Error processing log file: {str(e)}")
        raise


def detect_source_type(filename):
    """
    Detect log source type from filename
    """
    filename_lower = filename.lower()
    
    if 'servicenow' in filename_lower or 'snow' in filename_lower:
        return 'servicenow'
    elif 'saviynt' in filename_lower:
        return 'saviynt'
    elif 'cato' in filename_lower:
        return 'cato'
    elif 'syslog' in filename_lower:
        return 'syslog'
    else:
        return 'generic'


def read_log_sample(bucket, key, lines=50):
    """
    Read first N lines from S3 object
    """
    try:
        response = s3_client.get_object(Bucket=bucket, Key=key)
        content = response['Body'].read().decode('utf-8')
        
        # Split into lines and take first N
        all_lines = content.split('\n')
        sample_lines = all_lines[:lines]
        
        return '\n'.join(sample_lines)
        
    except Exception as e:
        print(f"Error reading S3 object: {str(e)}")
        raise


def generate_ddl_with_bedrock(log_sample, filename, source_type, s3_location):
    """
    Generate Athena CREATE OR REPLACE VIEW statement using Bedrock Claude 3.5 Sonnet
    
    The prompt instructs the LLM to:
    1. Analyze the log structure
    2. Generate appropriate column definitions
    3. Apply source-specific transformation rules
    4. Return valid Athena SQL DDL
    """
    
    # Construct source-specific rules
    source_rules = get_source_specific_rules(source_type)
    
    # Build the prompt for Bedrock
    prompt = f"""You are an expert AWS Athena SQL developer. Your task is to generate a CREATE OR REPLACE VIEW statement for Amazon Athena based on the provided log file sample.

**Log File Information:**
- Filename: {filename}
- Source Type: {source_type}
- S3 Location: {s3_location}

**Log Sample (first 50 lines):**
```
{log_sample}
```

**Requirements:**

1. Analyze the log structure and determine the appropriate columns and data types
2. Generate a CREATE OR REPLACE VIEW statement that creates a view named `view_{source_type}_{filename.split('.')[0].replace('-', '_').replace(' ', '_')}`
3. The view should reference the S3 location using an external table or direct S3 query
4. Apply the following source-specific transformation rules:

{source_rules}

5. Ensure the SQL is valid for Amazon Athena (Presto/Trino syntax)
6. Use appropriate data type casting (VARCHAR, BIGINT, TIMESTAMP, BOOLEAN, etc.)
7. Handle NULL values appropriately
8. Include comments for complex transformations

**Output Format:**
Return ONLY the SQL DDL statement, without any explanation or markdown formatting. The statement should be ready to execute directly in Athena.

**Example Output Structure:**
CREATE OR REPLACE VIEW compliance_db.view_servicenow_failed_logins AS
SELECT 
  column1,
  column2,
  CAST(column3 AS TIMESTAMP) as event_time
FROM external_table
WHERE condition;
"""

    # Invoke Bedrock
    try:
        request_body = {
            "anthropic_version": "bedrock-2023-05-31",
            "max_tokens": 4000,
            "temperature": 0.1,  # Low temperature for deterministic output
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
        ddl_statement = response_body['content'][0]['text'].strip()
        
        # Clean up any markdown code blocks if present
        ddl_statement = ddl_statement.replace('```sql', '').replace('```', '').strip()
        
        return ddl_statement
        
    except Exception as e:
        print(f"Error invoking Bedrock: {str(e)}")
        raise


def get_source_specific_rules(source_type):
    """
    Return source-specific transformation rules for the LLM prompt
    """
    rules = {
        'servicenow': """
**ServiceNow Rules:**
- Filter for events where event_type IN ('failed_login', 'admin_role_change')
- Extract user_id, event_type, timestamp, source_ip, and result columns
- Create a boolean column `is_security_event` that is TRUE for these filtered events
- Parse timestamp to proper TIMESTAMP format
        """,
        
        'saviynt': """
**Saviynt Rules:**
- Locate the "Patch Status" column (may have variations in naming)
- Use REGEXP_EXTRACT to parse date patterns from the Patch Status text
- Create a new column `patch_status_date` with format YYYY-MM-DD
- Example regex pattern: '(\\d{4}-\\d{2}-\\d{2})' or '(\\d{2}/\\d{2}/\\d{4})'
- Handle cases where patch status is NULL or 'Not Applicable'
        """,
        
        'cato': """
**Cato Rules:**
- Filter for records where event_type = 'remote_access'
- Create a boolean column `mfa_compliant` based on:
  - TRUE if authentication_method contains 'MFA' or 'multi-factor' or mfa_status = 'enabled'
  - FALSE otherwise
- Extract user_id, timestamp, source_ip, destination, and session_duration
- Include device_type and location if available
        """,
        
        'syslog': """
**Syslog Rules:**
- Parse standard syslog format: timestamp, hostname, process, pid, message
- Extract severity level and facility
- Create structured columns from the message field using regex
- Handle multi-line log entries appropriately
        """,
        
        'generic': """
**Generic Rules:**
- Auto-detect column structure from the first few rows
- Infer data types based on content patterns
- Create appropriate column names (lowercase, underscore-separated)
- Handle common formats: CSV, JSON, TSV
        """
    }
    
    return rules.get(source_type, rules['generic'])


def execute_athena_query(query):
    """
    Execute SQL query via Amazon Athena
    """
    try:
        response = athena_client.start_query_execution(
            QueryString=query,
            QueryExecutionContext={
                'Database': GLUE_DATABASE
            },
            WorkGroup=ATHENA_WORKGROUP
        )
        
        return response['QueryExecutionId']
        
    except Exception as e:
        print(f"Error executing Athena query: {str(e)}")
        raise


def wait_for_query_completion(execution_id, max_wait_seconds=60):
    """
    Wait for Athena query to complete
    """
    start_time = time.time()
    
    while True:
        if time.time() - start_time > max_wait_seconds:
            raise Exception(f"Query execution timeout after {max_wait_seconds} seconds")
        
        response = athena_client.get_query_execution(
            QueryExecutionId=execution_id
        )
        
        status = response['QueryExecution']['Status']['State']
        
        if status == 'SUCCEEDED':
            print(f"Query succeeded: {execution_id}")
            return True
        elif status in ['FAILED', 'CANCELLED']:
            reason = response['QueryExecution']['Status'].get('StateChangeReason', 'Unknown')
            raise Exception(f"Query {status}: {reason}")
        
        # Wait before checking again
        time.sleep(2)
