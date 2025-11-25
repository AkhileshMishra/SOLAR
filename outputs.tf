output "s3_bucket_name" {
  description = "Name of the S3 bucket for compliance data"
  value       = aws_s3_bucket.compliance_data.bucket
}

output "s3_bucket_arn" {
  description = "ARN of the S3 bucket"
  value       = aws_s3_bucket.compliance_data.arn
}

output "glue_database_name" {
  description = "Name of the Glue database"
  value       = aws_glue_catalog_database.compliance_db.name
}

output "athena_workgroup_name" {
  description = "Name of the Athena workgroup"
  value       = aws_athena_workgroup.compliance_auditor.name
}

output "opensearch_collection_endpoint" {
  description = "Endpoint for OpenSearch Serverless collection"
  value       = aws_opensearchserverless_collection.compliance_vectors.collection_endpoint
}

output "knowledge_base_id" {
  description = "ID of the Bedrock Knowledge Base"
  value       = aws_bedrockagent_knowledge_base.compliance_policy.id
}

output "bedrock_agent_id" {
  description = "ID of the Bedrock Agent"
  value       = aws_bedrockagent_agent.compliance_auditor.agent_id
}

output "bedrock_agent_alias_id" {
  description = "ID of the Bedrock Agent production alias"
  value       = aws_bedrockagent_agent_alias.compliance_auditor_prod.agent_alias_id
}

output "step_functions_arn" {
  description = "ARN of the Step Functions state machine"
  value       = aws_sfn_state_machine.compliance_workflow.arn
}

output "log_ingestion_lambda_name" {
  description = "Name of the Log Ingestion Agent Lambda function"
  value       = aws_lambda_function.log_ingestion_agent.function_name
}

output "report_generator_lambda_name" {
  description = "Name of the Report Generator Lambda function"
  value       = aws_lambda_function.report_generator.function_name
}

output "deployment_instructions" {
  description = "Next steps after Terraform deployment"
  value = <<-EOT
  
  Deployment Complete! Next Steps:
  
  1. Build and deploy the python-docx Lambda layer:
     cd layers
     mkdir -p python-docx/python
     pip install -r python-docx-requirements.txt -t python-docx/python/
     cd python-docx && zip -r ../../.terraform/layers/python-docx.zip . && cd ../..
     
  2. Upload a policy PDF to S3:
     aws s3 cp your-policy.pdf s3://${aws_s3_bucket.compliance_data.bucket}/inputs/policy/
     
  3. Sync the Knowledge Base:
     aws bedrock-agent start-ingestion-job \
       --knowledge-base-id ${aws_bedrockagent_knowledge_base.compliance_policy.id} \
       --data-source-id <data-source-id>
     
  4. Upload log files to trigger ingestion:
     aws s3 cp servicenow-logs.csv s3://${aws_s3_bucket.compliance_data.bucket}/inputs/logs/
     
  5. Start the compliance workflow:
     aws stepfunctions start-execution \
       --state-machine-arn ${aws_sfn_state_machine.compliance_workflow.arn} \
       --input '{}'
     
  6. Monitor execution in Step Functions console or retrieve results from:
     s3://${aws_s3_bucket.compliance_data.bucket}/outputs/reports/
  
  EOT
}
