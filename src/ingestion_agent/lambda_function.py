import boto3
import json
import os
import logging
import io
import urllib.parse  # <--- YOU ARE MISSING THIS LINE
import pandas as pd

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Clients
s3 = boto3.client('s3')
bedrock = boto3.client('bedrock-runtime')
athena = boto3.client('athena')
glue = boto3.client('glue')

def lambda_handler(event, context):
    """
    Analyzes log files (CSV/Excel/JSON) uploaded to S3 and creates Athena Views.
    """
    try:
        # 1. Get file details from event
        bucket = event['Records'][0]['s3']['bucket']['name']
        raw_key = event['Records'][0]['s3']['object']['key']
        key = urllib.parse.unquote_plus(raw_key)
        
        logger.info(f"Processing file: s3://{bucket}/{key}")
        
        # 2. Read and sample the data (Handles CSV and Excel)
        sample_data, columns = read_file_sample(bucket, key)
        
        if not sample_data:
            logger.error("Could not read data sample. Aborting.")
            return {"status": "Failed", "reason": "Empty or unreadable file"}

        # 3. Generate Athena DDL using Bedrock
        ddl_sql = generate_ddl_with_bedrock(key, sample_data, columns)
        
        if not ddl_sql:
            logger.error("Failed to generate DDL.")
            return {"status": "Failed"}

        # 4. Execute DDL in Athena
        execution_id = execute_athena_query(ddl_sql)
        
        return {
            "status": "Success",
            "file": key,
            "athena_query_id": execution_id
        }
        
    except Exception as e:
        logger.error(f"Error processing file: {str(e)}")
        raise e

def read_file_sample(bucket, key):
    """
    Reads the file from S3.
    If .xlsx -> Uses Pandas to read and convert to string sample.
    If .csv/.json -> Reads as text.
    """
    try:
        response = s3.get_object(Bucket=bucket, Key=key)
        file_content = response['Body'].read()
        
        file_ext = key.lower().split('.')[-1]
        
        if file_ext in ['xlsx', 'xls']:
            logger.info("Detected Excel file. Converting to DataFrame...")
            # Read Excel bytes into Pandas
            df = pd.read_excel(io.BytesIO(file_content), nrows=10)
            
            # Convert to CSV string for the AI prompt
            csv_buffer = io.StringIO()
            df.to_csv(csv_buffer, index=False)
            sample_str = csv_buffer.getvalue()
            columns = list(df.columns)
            return sample_str, columns
            
        else:
            # Default path for CSV/JSON/Logs
            logger.info("Detected Text/CSV file.")
            text_content = file_content.decode('utf-8', errors='ignore')
            lines = text_content.splitlines()[:10] # First 10 lines
            sample_str = "\n".join(lines)
            return sample_str, []

    except Exception as e:
        logger.error(f"Error reading S3 object: {str(e)}")
        raise e

def generate_ddl_with_bedrock(key, sample_data, columns):
    """
    Asks Claude to write a CREATE OR REPLACE VIEW statement.
    """
    table_name = "view_" + key.split('/')[-1].replace('.', '_').replace('-', '_').lower()
    
    prompt = f"""
    You are a Data Engineer expert in AWS Athena and PrestoSQL.
    I have a log file located at: 's3://{os.environ.get('ATHENA_OUTPUT_LOCATION').split('/')[2]}/inputs/logs/' (Note: This is the root, but the file is at {key})
    
    The file content sample is:
    {sample_data}
    
    Task: Write a valid Amazon Athena 'CREATE OR REPLACE VIEW' statement.
    
    Rules:
    1. View Name: "{table_name}"
    2. Database: "{os.environ.get('GLUE_DATABASE', 'default')}"
    3. COLUMN TYPES: 
       - NEVER use VARCHAR(0). 
       - If casting strings, use just 'VARCHAR' (without length) or 'VARCHAR(255)'.
       - Do not guess specific lengths like VARCHAR(50). Use generic VARCHAR.
    4. If the source is Excel, treat it as if it were a generic external table or assume the user will convert it to CSV. 
       HOWEVER, since Athena cannot read Excel directly, write the View using the 'VALUES' clause for this sample data strictly for demonstration, 
       OR better yet, assume the underlying data is mapped to a table named 'raw_logs' and write a SELECT statement casting these columns.
       
       ACTUALLY, to make this robust for the demo:
       Write a DDL that creates a view based on a hypothetical table "compliance_logs_raw" but selects the specific columns found in this sample: {columns}.
       
       Wait, let's simplify. Just return a SQL query that would select this data. 
       NO, we need a View. 
       
       Revised Task: Generate a CREATE OR REPLACE VIEW statement that selects hardcoded values from the sample provided. 
       This ensures the view works immediately for the demo without needing complex Glue Crawlers for Excel.
       
       Example format:
       CREATE OR REPLACE VIEW "{os.environ.get('GLUE_DATABASE', 'default')}"."{table_name}" AS
       SELECT * FROM (VALUES
         ('val1', 'val2'),
         ('val3', 'val4')
       ) AS t ("col1", "col2")
    
    Return ONLY the SQL string. No markdown, no explanations.
    """
    
    # Note: Using the simplified prompt logic from the original script for stability
    # Ideally, you'd use a Glue Crawler for Excel, but this "Values" trick works for static demo reports.
    
    body = json.dumps({
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": 2000,
        "messages": [{"role": "user", "content": prompt}]
    })

    try:
        response = bedrock.invoke_model(
            modelId=os.environ.get('BEDROCK_MODEL_ID', "anthropic.claude-3-5-sonnet-20240620-v1:0"),
            body=body
        )
        response_body = json.loads(response.get("body").read())
        sql = response_body["content"][0]["text"].strip()
        # Clean markdown if present
        sql = sql.replace("```sql", "").replace("```", "")
        return sql
    except Exception as e:
        logger.error(f"Bedrock error: {str(e)}")
        return None

def execute_athena_query(query):
    try:
        response = athena.start_query_execution(
            QueryString=query,
            QueryExecutionContext={'Database': os.environ.get('GLUE_DATABASE', 'default')},
            ResultConfiguration={'OutputLocation': os.environ.get('ATHENA_OUTPUT_LOCATION')},
            # ADD THIS LINE to force the correct workgroup
            WorkGroup=os.environ.get('ATHENA_WORKGROUP', 'primary') 
        )
        return response['QueryExecutionId']
    except Exception as e:
        logger.error(f"Athena execution error: {str(e)}")
        raise e
