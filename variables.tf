variable "aws_region" {
  description = "AWS region for resource deployment"
  type        = string
  default     = "ap-southeast-1"
}

variable "project_name" {
  description = "Project name prefix for resource naming"
  type        = string
  default     = "compliance-reporting"
}

variable "bedrock_model_id" {
  description = "Bedrock model ID for Claude 3.5 Sonnet"
  type        = string
  default     = "anthropic.claude-3-5-sonnet-20240620-v1:0"
}

variable "bedrock_embedding_model_id" {
  description = "Bedrock embedding model ID for Knowledge Base"
  type        = string
  default     = "amazon.titan-embed-text-v1"
}

variable "s3_bucket_name" {
  description = "S3 bucket name for compliance data (will append account ID)"
  type        = string
  default     = "compliance-reporting-bucket"
}

variable "glue_database_name" {
  description = "AWS Glue database name for log catalog"
  type        = string
  default     = "compliance_db"
}

variable "athena_workgroup_name" {
  description = "Amazon Athena workgroup name"
  type        = string
  default     = "compliance_auditor"
}

variable "opensearch_collection_name" {
  description = "OpenSearch Serverless collection name for vector store"
  type        = string
  default     = "compliance-policy-vectors"
}

variable "knowledge_base_name" {
  description = "Bedrock Knowledge Base name"
  type        = string
  default     = "CompliancePolicyKB"
}

variable "bedrock_agent_name" {
  description = "Bedrock Agent name"
  type        = string
  default     = "ComplianceAuditorAgent"
}

variable "tags" {
  description = "Common tags for all resources"
  type        = map(string)
  default = {
    Project     = "AI-Compliance-Reporting"
    ManagedBy   = "Terraform"
    Environment = "Production"
  }
}
