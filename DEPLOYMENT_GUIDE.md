# Deployment Guide: AI-Driven Compliance Reporting System

This guide provides step-by-step instructions for deploying and operating the AI-Driven Compliance Reporting System on AWS.

## Prerequisites

Before deploying this solution, ensure you have the following:

1. **AWS Account** with appropriate permissions to create:
   - S3 buckets
   - Lambda functions
   - Bedrock resources (Knowledge Bases and Agents)
   - OpenSearch Serverless collections
   - Step Functions state machines
   - Glue databases and Athena workgroups
   - IAM roles and policies

2. **AWS Bedrock Access**: Ensure your AWS account has access to Amazon Bedrock and the following models:
   - `anthropic.claude-3-5-sonnet-20240620-v1:0`
   - `amazon.titan-embed-text-v1`

3. **Tools Installed**:
   - Terraform v1.5.0 or later
   - AWS CLI v2 configured with credentials
   - Python 3.11+
   - Git

## Step 1: Clone the Repository

```bash
git clone https://github.com/AkhileshMishra/SOLAR.git
cd SOLAR
```

## Step 2: Build the Lambda Layer

The `ReportGenerator` Lambda function requires the `python-docx` library, which must be packaged as a Lambda layer.

```bash
./build_layer.sh
```

This script will:
- Create the necessary directory structure
- Install `python-docx` and its dependencies
- Package everything into a zip file at `.terraform/layers/python-docx.zip`

## Step 3: Configure Terraform Variables (Optional)

The default variable values in `variables.tf` should work for most deployments. However, you can customize them by creating a `terraform.tfvars` file:

```hcl
aws_region = "us-east-1"
project_name = "my-compliance-system"
s3_bucket_name = "my-compliance-bucket"
```

## Step 4: Initialize Terraform

Initialize the Terraform working directory:

```bash
terraform init
```

## Step 5: Review the Deployment Plan

Review what Terraform will create:

```bash
terraform plan
```

This will show you all the resources that will be created, including:
- 1 S3 bucket with folder structure
- 1 Glue database
- 1 Athena workgroup
- 1 OpenSearch Serverless collection
- 1 Bedrock Knowledge Base with data source
- 1 Bedrock Agent with action groups
- 4 Lambda functions
- 1 Lambda layer
- 1 Step Functions state machine
- Multiple IAM roles and policies

## Step 6: Deploy the Infrastructure

Apply the Terraform configuration:

```bash
terraform apply
```

Type `yes` when prompted to confirm the deployment.

**Note**: The deployment will take approximately 10-15 minutes, as creating the OpenSearch Serverless collection and Bedrock resources can be time-consuming.

## Step 7: Verify the Deployment

After successful deployment, Terraform will output important resource identifiers:

```bash
terraform output
```

Save these values for later use.

## Step 8: Upload Policy Documents

Upload your organization's compliance policy PDF to S3:

```bash
BUCKET_NAME=$(terraform output -raw s3_bucket_name)
aws s3 cp /path/to/your/policy.pdf s3://${BUCKET_NAME}/inputs/policy/
```

## Step 9: Sync the Knowledge Base

After uploading the policy document, trigger a Knowledge Base ingestion job:

```bash
KB_ID=$(terraform output -raw knowledge_base_id)
DATA_SOURCE_ID=$(aws bedrock-agent list-data-sources \
  --knowledge-base-id $KB_ID \
  --query 'dataSourceSummaries[0].dataSourceId' \
  --output text)

aws bedrock-agent start-ingestion-job \
  --knowledge-base-id $KB_ID \
  --data-source-id $DATA_SOURCE_ID
```

Monitor the ingestion job status:

```bash
aws bedrock-agent list-ingestion-jobs \
  --knowledge-base-id $KB_ID \
  --data-source-id $DATA_SOURCE_ID
```

Wait until the status is `COMPLETE` before proceeding.

## Step 10: Upload Log Files

Upload sample log files to trigger the Auto-DDL ingestion:

```bash
# ServiceNow logs
aws s3 cp /path/to/servicenow-logs.csv s3://${BUCKET_NAME}/inputs/logs/

# Cato logs
aws s3 cp /path/to/cato-logs.json s3://${BUCKET_NAME}/inputs/logs/

# Saviynt logs
aws s3 cp /path/to/saviynt-logs.csv s3://${BUCKET_NAME}/inputs/logs/
```

The `LogIngestionAgent` Lambda will automatically:
1. Detect the upload via S3 event notification
2. Analyze the log structure using Bedrock
3. Generate and execute an Athena CREATE VIEW statement

You can monitor the Lambda execution in CloudWatch Logs:

```bash
aws logs tail /aws/lambda/compliance-reporting-log-ingestion-agent --follow
```

## Step 11: Verify Athena Views

Check that the views were created successfully:

```bash
aws glue get-tables --database-name compliance_db
```

You should see views with names like `view_servicenow_*`, `view_cato_*`, etc.

## Step 12: Execute the Compliance Workflow

Start the Step Functions workflow to generate a compliance report:

```bash
STATE_MACHINE_ARN=$(terraform output -raw step_functions_arn)

EXECUTION_ARN=$(aws stepfunctions start-execution \
  --state-machine-arn $STATE_MACHINE_ARN \
  --input '{}' \
  --query 'executionArn' \
  --output text)

echo "Execution started: $EXECUTION_ARN"
```

## Step 13: Monitor the Workflow

Monitor the execution status:

```bash
aws stepfunctions describe-execution --execution-arn $EXECUTION_ARN
```

You can also view the execution in the AWS Step Functions console for a visual representation.

## Step 14: Retrieve the Report

Once the workflow completes (status: `SUCCEEDED`), download the generated report:

```bash
# List available reports
aws s3 ls s3://${BUCKET_NAME}/outputs/reports/

# Download the latest report
aws s3 cp s3://${BUCKET_NAME}/outputs/reports/ . --recursive
```

The report will be a Microsoft Word (.docx) file with a timestamped filename.

## Troubleshooting

### Lambda Function Errors

Check CloudWatch Logs for detailed error messages:

```bash
# Log Ingestion Agent
aws logs tail /aws/lambda/compliance-reporting-log-ingestion-agent --since 1h

# Report Generator
aws logs tail /aws/lambda/compliance-reporting-report-generator --since 1h

# Policy Section Fetcher
aws logs tail /aws/lambda/compliance-reporting-policy-section-fetcher --since 1h
```

### Bedrock Access Issues

If you encounter "Access Denied" errors for Bedrock:

1. Ensure your AWS account has Bedrock enabled in the deployment region
2. Request access to the Claude 3.5 Sonnet model in the Bedrock console
3. Verify IAM permissions include `bedrock:InvokeModel` and `bedrock:Retrieve`

### Athena Query Failures

If Athena queries fail:

1. Check the query execution details in the Athena console
2. Verify the S3 bucket permissions allow Athena to read log files
3. Ensure the Glue database exists and is accessible

### Step Functions Execution Failures

If the Step Functions workflow fails:

1. View the execution graph in the console to identify which step failed
2. Check the input/output of each step for error messages
3. Verify the Bedrock Agent is in `PREPARED` state
4. Ensure the Knowledge Base ingestion job completed successfully

## Cleanup

To destroy all resources and avoid ongoing charges:

```bash
# Empty the S3 bucket first (Terraform cannot delete non-empty buckets)
aws s3 rm s3://${BUCKET_NAME} --recursive

# Destroy all Terraform-managed resources
terraform destroy
```

Type `yes` when prompted to confirm the destruction.

## Cost Considerations

This solution uses several AWS services with different pricing models:

- **S3**: Storage costs based on data volume
- **Lambda**: Charged per invocation and execution duration
- **Bedrock**: Charged per token (input and output)
- **OpenSearch Serverless**: Charged per OCU-hour
- **Athena**: Charged per TB of data scanned
- **Step Functions**: Charged per state transition

For cost optimization:
- Use S3 lifecycle policies to archive old reports
- Set appropriate Lambda timeouts and memory allocations
- Limit the number of parallel Map state executions
- Use Athena partition projection for large log datasets

## Security Best Practices

1. **Enable S3 Bucket Encryption**: Already configured in the Terraform code
2. **Use VPC Endpoints**: Consider adding VPC endpoints for S3, Bedrock, and other services
3. **Implement Least Privilege**: Review and tighten IAM policies as needed
4. **Enable CloudTrail**: Track all API calls for audit purposes
5. **Rotate Credentials**: Regularly rotate any API keys or credentials
6. **Monitor with CloudWatch**: Set up alarms for unusual activity

## Support

For issues, questions, or contributions, please open an issue on the GitHub repository:
https://github.com/AkhileshMishra/SOLAR/issues
