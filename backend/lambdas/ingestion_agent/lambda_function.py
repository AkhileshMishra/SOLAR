import boto3
import os
import logging
import io
import urllib.parse
import pandas as pd

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3 = boto3.client('s3')
glue = boto3.client('glue')

def lambda_handler(event, context):
    try:
        # 1. Get file details
        bucket = event['Records'][0]['s3']['bucket']['name']
        raw_key = event['Records'][0]['s3']['object']['key']
        key = urllib.parse.unquote_plus(raw_key)
        
        logger.info(f"Processing file: s3://{bucket}/{key}")
        
        # 2. Identify source type and system name
        path_parts = key.split('/')
        source_type = path_parts[1] if len(path_parts) > 1 else 'logs'  # logs or QUALYS
        system_name = path_parts[2] if len(path_parts) > 2 else 'generic'

        # 3. Read File (Excel or CSV)
        df = read_file_to_dataframe(bucket, key)
        
        if df is None:
            logger.error("Could not read file.")
            return {"status": "Failed"}

        # 4. Save as CSV to 'processed/' folder
        file_name = path_parts[-1].replace('.xlsx', '.csv').replace('.xls', '.csv')
        
        if source_type.upper() == 'QUALYS':
            output_key = f"processed/qualys/{system_name}/{file_name}"
        elif source_type.upper() == 'VAPT':
            output_key = f"processed/vapt/{system_name}/{file_name}"
        else:
            output_key = f"processed/logs/{system_name}/{file_name}"
        
        save_dataframe_to_s3(df, bucket, output_key)
        
        # 5. Trigger Glue Crawler to update the table definition
        start_crawler()
        
        return {"status": "Success", "processed_key": output_key}
        
    except Exception as e:
        logger.error(f"Error: {str(e)}")
        raise e

def read_file_to_dataframe(bucket, key):
    response = s3.get_object(Bucket=bucket, Key=key)
    file_content = response['Body'].read()
    file_ext = key.lower().split('.')[-1]
    
    if file_ext in ['xlsx', 'xls']:
        return pd.read_excel(io.BytesIO(file_content))
    elif file_ext == 'csv':
        return pd.read_csv(io.BytesIO(file_content))
    return None

def save_dataframe_to_s3(df, bucket, key):
    csv_buffer = io.StringIO()
    df.to_csv(csv_buffer, index=False)
    
    s3.put_object(
        Bucket=bucket, 
        Key=key, 
        Body=csv_buffer.getvalue()
    )
    logger.info(f"Saved processed CSV to {key}")

def start_crawler():
    crawler_name = f"{os.environ.get('PROJECT_NAME', 'compliance-reporting')}-log-crawler"
    try:
        glue.start_crawler(Name=crawler_name)
        logger.info(f"Triggered crawler: {crawler_name}")
    except glue.exceptions.CrawlerRunningException:
        logger.info("Crawler is already running.")
    except Exception as e:
        # Fallback if name is slightly different in Terraform
        logger.error(f"Failed to start crawler: {str(e)}")