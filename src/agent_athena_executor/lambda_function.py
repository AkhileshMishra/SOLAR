"""
Agent Athena Executor Lambda Function

This function serves as the action group executor for the Bedrock Agent.
It handles two operations:
1. query-athena: Execute SQL queries against Athena views
2. list-views: List available views in the Glue catalog
"""

import json
import boto3
import os
import time

# Initialize AWS clients
athena_client = boto3.client('athena')
glue_client = boto3.client('glue')

# Environment variables
GLUE_DATABASE = os.environ.get('GLUE_DATABASE', 'compliance_db')
ATHENA_WORKGROUP = os.environ.get('ATHENA_WORKGROUP', 'compliance_auditor')
ATHENA_OUTPUT_LOCATION = os.environ.get('ATHENA_OUTPUT_LOCATION')


def lambda_handler(event, context):
    """
    Main Lambda handler for Bedrock Agent action group invocations
    """
    print(f"Received event: {json.dumps(event)}")
    
    # Parse the Bedrock Agent event
    agent = event.get('agent', {})
    action_group = event.get('actionGroup', '')
    api_path = event.get('apiPath', '')
    http_method = event.get('httpMethod', '')
    parameters = event.get('parameters', [])
    request_body = event.get('requestBody', {})
    
    # Route to appropriate handler
    try:
        if api_path == '/query-athena' and http_method == 'POST':
            response_body = handle_query_athena(request_body)
        elif api_path == '/list-views' and http_method == 'GET':
            response_body = handle_list_views()
        else:
            response_body = {
                'error': f'Unknown API path: {api_path}'
            }
        
        # Format response for Bedrock Agent
        return {
            'messageVersion': '1.0',
            'response': {
                'actionGroup': action_group,
                'apiPath': api_path,
                'httpMethod': http_method,
                'httpStatusCode': 200,
                'responseBody': {
                    'application/json': {
                        'body': json.dumps(response_body)
                    }
                }
            }
        }
        
    except Exception as e:
        print(f"Error handling request: {str(e)}")
        return {
            'messageVersion': '1.0',
            'response': {
                'actionGroup': action_group,
                'apiPath': api_path,
                'httpMethod': http_method,
                'httpStatusCode': 500,
                'responseBody': {
                    'application/json': {
                        'body': json.dumps({
                            'error': str(e)
                        })
                    }
                }
            }
        }


def handle_query_athena(request_body):
    """
    Execute Athena query and return results
    """
    # Parse request body
    content = request_body.get('content', {})
    app_json = content.get('application/json', {})
    
    query = ''
    max_results = 100
    
    # Case 1: Bedrock Agent format (List of properties)
    if 'properties' in app_json:
        for prop in app_json['properties']:
            if prop['name'] == 'query':
                query = prop['value']
            elif prop['name'] == 'max_results':
                max_results = int(prop['value'])
                
    # Case 2: API Gateway/Raw JSON format (Fallback)
    elif 'body' in app_json:
        try:
            body_data = json.loads(app_json['body'])
            query = body_data.get('query', '')
            max_results = body_data.get('max_results', 100)
        except:
            pass
            
    if not query:
        # Debugging: Print structure if parsing fails
        print(f"Failed to extract query. Content structure: {json.dumps(content)}")
        raise ValueError("Query parameter is required")
    
    # Validate query (basic security check)
    query_upper = query.upper().strip()
    if not query_upper.startswith('SELECT'):
        raise ValueError("Only SELECT queries are allowed")
    
    # Prevent destructive operations
    #forbidden_keywords = ['DROP', 'DELETE', 'INSERT', 'UPDATE', 'CREATE', 'ALTER', 'TRUNCATE']
    #for keyword in forbidden_keywords:
    #    if keyword in query_upper:
    #        raise ValueError(f"Query contains forbidden keyword: {keyword}")
    
    # Execute query
    start_time = time.time()
    
    response = athena_client.start_query_execution(
        QueryString=query,
        QueryExecutionContext={
            'Database': GLUE_DATABASE
        },
        WorkGroup=ATHENA_WORKGROUP
    )
    
    execution_id = response['QueryExecutionId']
    
    # Wait for query completion
    wait_for_query_completion(execution_id)
    
    # Get query results
    results = athena_client.get_query_results(
        QueryExecutionId=execution_id,
        MaxResults=max_results
    )
    
    execution_time_ms = int((time.time() - start_time) * 1000)
    
    # Parse results
    result_set = results['ResultSet']
    rows = result_set['Rows']
    
    if len(rows) == 0:
        return {
            'columns': [],
            'rows': [],
            'row_count': 0,
            'execution_time_ms': execution_time_ms
        }
    
    # Extract column names from first row
    columns = [col['VarCharValue'] for col in rows[0]['Data']]
    
    # Extract data rows (skip header)
    data_rows = []
    for row in rows[1:]:
        # Handle cases where a column might be null/missing in the response
        row_data = []
        for col in row['Data']:
            row_data.append(col.get('VarCharValue', ''))
        data_rows.append(row_data)
    
    return {
        'columns': columns,
        'rows': data_rows,
        'row_count': len(data_rows),
        'execution_time_ms': execution_time_ms
    }


def handle_list_views():
    """
    List all views in the Glue database
    """
    views = []
    
    try:
        # Get all tables (views are stored as tables in Glue)
        paginator = glue_client.get_paginator('get_tables')
        
        for page in paginator.paginate(DatabaseName=GLUE_DATABASE):
            for table in page['TableList']:
                table_name = table['Name']
                
                # Only include views (check if it's a view by table type or naming convention)
                # [NEW CODE] Allow Views AND Standard Tables (Crawler results)
                # UPDATE: Allow 'logs' table and standard Crawler tables
                if table_name == 'logs' or table_name.startswith('view_') or table.get('TableType') in ['VIRTUAL_VIEW', 'EXTERNAL_TABLE']:
                    # Determine source type from view name
                    source_type = 'unknown'
                    if 'servicenow' in table_name:
                        source_type = 'servicenow'
                    elif 'saviynt' in table_name:
                        source_type = 'saviynt'
                    elif 'cato' in table_name:
                        source_type = 'cato'
                    elif 'syslog' in table_name:
                        source_type = 'syslog'
                    
                    # Extract column information
                    columns = []
                    for col in table.get('StorageDescriptor', {}).get('Columns', []):
                        columns.append({
                            'name': col['Name'],
                            'type': col['Type']
                        })
                    
                    views.append({
                        'view_name': table_name,
                        'source_type': source_type,
                        'columns': columns,
                        'row_count': -1  # Athena doesn't provide row counts without querying
                    })
        
        return {
            'views': views
        }
        
    except Exception as e:
        print(f"Error listing views: {str(e)}")
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
            return True
        elif status in ['FAILED', 'CANCELLED']:
            reason = response['QueryExecution']['Status'].get('StateChangeReason', 'Unknown')
            raise Exception(f"Query {status}: {reason}")
        
        time.sleep(1)
