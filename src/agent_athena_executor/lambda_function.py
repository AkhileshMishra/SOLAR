import json
import boto3
import time
import os
import io
import sys

# --- SAFE IMPORT LOGIC ---
# Keeps the app from crashing if imports fail, helping debugging
IMPORT_ERROR = None
try:
    import pypdf
    from pypdf import PdfReader
except ImportError as e:
    IMPORT_ERROR = f"Failed to import pypdf: {str(e)}"
except Exception as e:
    IMPORT_ERROR = f"Unexpected error importing libraries: {str(e)}"
# -------------------------

athena_client = boto3.client('athena')
s3_client = boto3.client('s3')
glue_client = boto3.client('glue')

# Environment Variables
GLUE_DATABASE = os.environ.get('GLUE_DATABASE')
ATHENA_WORKGROUP = os.environ.get('ATHENA_WORKGROUP')
ATHENA_OUTPUT_LOCATION = os.environ.get('ATHENA_OUTPUT_LOCATION')

def lambda_handler(event, context):
    print(f"Received Event: {json.dumps(event)}")
    
    agent = event.get('agent')
    actionGroup = event.get('actionGroup')
    apiPath = event.get('apiPath')
    httpMethod = event.get('httpMethod')
    
    # Check for layer issues immediately
    if IMPORT_ERROR:
        print(f"CRITICAL LAYER ERROR: {IMPORT_ERROR}")
        return format_response(actionGroup, apiPath, httpMethod, 500, {"error": "Layer Failure", "details": IMPORT_ERROR})

    response_body = {}
    
    try:
        # ---------------------------------------------------------
        # ROUTE 1: Query Athena
        # ---------------------------------------------------------
        if apiPath == '/query-athena':
            properties = event.get('requestBody', {}).get('content', {}).get('application/json', {}).get('properties', [])
            query_string = next((p['value'] for p in properties if p['name'] == 'query'), "")
            
            if not query_string: raise ValueError("Missing 'query' parameter")

            execution_id = start_query_execution(query_string)
            response_body = wait_for_query_results(execution_id)

        # ---------------------------------------------------------
        # ROUTE 2: List Views
        # ---------------------------------------------------------
        elif apiPath == '/list-views':
            response_body = handle_list_views()

        # ---------------------------------------------------------
        # ROUTE 3: Read SOC Report
        # ---------------------------------------------------------
        elif apiPath == '/read-soc-report':
            properties = event.get('requestBody', {}).get('content', {}).get('application/json', {}).get('properties', [])
            system_name = next((p['value'] for p in properties if p['name'] == 'system_name'), "")
            
            if not system_name: raise ValueError("Missing 'system_name' parameter")

            bucket_name = ATHENA_OUTPUT_LOCATION.split('//')[1].split('/')[0] 
            prefix = f"inputs/SOCreports/{system_name}/"
            
            # Helper function determines text content
            text_content = extract_text_from_latest_pdf(bucket_name, prefix)
            
            response_body = {
                "system": system_name,
                "report_date": "Latest", # Added back to satisfy schema
                "content_text": text_content[:25000] # Truncate to safe size
            }

        else:
            raise ValueError(f"Unrecognized apiPath: {apiPath}")

        # Return Success
        return format_response(actionGroup, apiPath, httpMethod, 200, response_body)

    except Exception as e:
        print(f"Error: {str(e)}")
        # Return Error safely so Bedrock sees it
        return format_response(actionGroup, apiPath, httpMethod, 500, {"error": str(e)})

# --- Helper: Format Response for Bedrock ---
def format_response(action_group, api_path, http_method, status_code, body_content):
    return {
        'messageVersion': '1.0', 
        'response': {
            'actionGroup': action_group,
            'apiPath': api_path,
            'httpMethod': http_method,
            'httpStatusCode': status_code,
            'responseBody': {
                'application/json': {
                    'body': json.dumps(body_content)
                }
            }
        }
    }

# --- Logic Helpers ---

def start_query_execution(query_string):
    response = athena_client.start_query_execution(
        QueryString=query_string,
        QueryExecutionContext={'Database': GLUE_DATABASE},
        ResultConfiguration={'OutputLocation': ATHENA_OUTPUT_LOCATION},
        WorkGroup=ATHENA_WORKGROUP
    )
    return response['QueryExecutionId']

def wait_for_query_results(execution_id):
    for i in range(20): # Max 20 seconds wait
        status = athena_client.get_query_execution(QueryExecutionId=execution_id)
        state = status['QueryExecution']['Status']['State']
        if state == 'SUCCEEDED': break
        if state in ['FAILED', 'CANCELLED']: raise Exception(f"Query Failed: {state}")
        time.sleep(1)
        
    results = athena_client.get_query_results(QueryExecutionId=execution_id)
    rows = []
    for row in results['ResultSet']['Rows']:
        rows.append([d.get('VarCharValue', '') for d in row['Data']])
    return {"columns": rows[0], "rows": rows[1:], "row_count": len(rows)-1}

def handle_list_views():
    tables = glue_client.get_tables(DatabaseName=GLUE_DATABASE)['TableList']
    views = []
    for t in tables:
        views.append({
            "view_name": t['Name'],
            "type": t.get('TableType', 'UNKNOWN'),
            "columns": [c['Name'] for c in t['StorageDescriptor']['Columns']]
        })
    return {"views": views}

def extract_text_from_latest_pdf(bucket, prefix):
    print(f"Looking for PDFs in {bucket}/{prefix}")
    response = s3_client.list_objects_v2(Bucket=bucket, Prefix=prefix)
    
    if 'Contents' not in response: return "No SOC reports found. Please check S3 path."
        
    pdfs = [obj for obj in response['Contents'] if obj['Key'].lower().endswith('.pdf')]
    if not pdfs: return "No PDF files found in folder."
        
    latest = sorted(pdfs, key=lambda x: x['LastModified'], reverse=True)[0]
    print(f"Processing: {latest['Key']}")
    
    obj = s3_client.get_object(Bucket=bucket, Key=latest['Key'])
    file_content = obj['Body'].read()
    
    pdf_file = io.BytesIO(file_content)
    reader = PdfReader(pdf_file)
    
    full_text = []
    # Limit to first 30 pages to keep it fast and light
    for page in reader.pages[:30]:
        full_text.append(page.extract_text())
        
    return "\n".join(full_text)