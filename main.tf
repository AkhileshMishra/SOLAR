terraform {
  required_version = ">= 1.5.0"
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
    # ADDED: OpenSearch provider for index management
    opensearch = {
      source  = "opensearch-project/opensearch"
      version = ">= 2.2.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ADDED: Configure OpenSearch provider
provider "opensearch" {
  url         = aws_opensearchserverless_collection.compliance_vectors.collection_endpoint
  healthcheck = false
}

# Get current AWS account ID
data "aws_caller_identity" "current" {}

# Get current AWS region
data "aws_region" "current" {}

################################################################################
# Layer 1: Storage & Data Layer
################################################################################

# S3 Bucket for Compliance Data
resource "aws_s3_bucket" "compliance_data" {
  bucket = "${var.s3_bucket_name}-${data.aws_caller_identity.current.account_id}"
  
  tags = merge(var.tags, {
    Name = "Compliance Data Bucket"
  })
}

# Enable versioning for audit trail
resource "aws_s3_bucket_versioning" "compliance_data" {
  bucket = aws_s3_bucket.compliance_data.id
  
  versioning_configuration {
    status = "Enabled"
  }
}

# Block public access
resource "aws_s3_bucket_public_access_block" "compliance_data" {
  bucket = aws_s3_bucket.compliance_data.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Server-side encryption
resource "aws_s3_bucket_server_side_encryption_configuration" "compliance_data" {
  bucket = aws_s3_bucket.compliance_data.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Create folder structure using S3 objects
resource "aws_s3_object" "inputs_logs" {
  bucket  = aws_s3_bucket.compliance_data.id
  key     = "inputs/logs/"
  content = ""
}

resource "aws_s3_object" "inputs_policy" {
  bucket  = aws_s3_bucket.compliance_data.id
  key     = "inputs/policy/"
  content = ""
}

resource "aws_s3_object" "outputs_reports" {
  bucket  = aws_s3_bucket.compliance_data.id
  key     = "outputs/reports/"
  content = ""
}

resource "aws_s3_object" "athena_results" {
  bucket  = aws_s3_bucket.compliance_data.id
  key     = "athena-results/"
  content = ""
}

# AWS Glue Database for Data Catalog
resource "aws_glue_catalog_database" "compliance_db" {
  name        = var.glue_database_name
  description = "Database for compliance log views and tables"
  
  tags = var.tags
}

# Amazon Athena Workgroup
resource "aws_athena_workgroup" "compliance_auditor" {
  name        = var.athena_workgroup_name
  description = "Workgroup for compliance auditing queries"
  
  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true
    
    result_configuration {
      output_location = "s3://${aws_s3_bucket.compliance_data.bucket}/athena-results/"
      
      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
    
    engine_version {
      selected_engine_version = "Athena engine version 3"
    }
  }
  
  tags = var.tags
}

################################################################################
# Layer 2: Auto-DDL Ingestion Layer (IAM Roles)
################################################################################

# IAM Role for LogIngestionAgent Lambda
resource "aws_iam_role" "log_ingestion_agent" {
  name = "${var.project_name}-log-ingestion-agent-role"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
  
  tags = var.tags
}

# Policy for LogIngestionAgent Lambda
resource "aws_iam_role_policy" "log_ingestion_agent" {
  name = "${var.project_name}-log-ingestion-agent-policy"
  role = aws_iam_role.log_ingestion_agent.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.compliance_data.arn,
          "${aws_s3_bucket.compliance_data.arn}/inputs/logs/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel"
        ]
        Resource = "arn:aws:bedrock:${data.aws_region.current.name}::foundation-model/${var.bedrock_model_id}"
      },
      {
        Effect = "Allow"
        Action = [
          "athena:StartQueryExecution",
          "athena:GetQueryExecution",
          "athena:GetQueryResults"
        ]
        Resource = [
          aws_athena_workgroup.compliance_auditor.arn
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "glue:GetDatabase",
          "glue:GetTable",
          "glue:GetTables",
          "glue:CreateTable",
          "glue:UpdateTable"
        ]
        Resource = [
          "arn:aws:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:catalog",
          "arn:aws:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:database/${var.glue_database_name}",
          "arn:aws:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:table/${var.glue_database_name}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject"
        ]
        Resource = [
          "${aws_s3_bucket.compliance_data.arn}/athena-results/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/*"
      }
    ]
  })
}

################################################################################
# Layer 3: AI Reasoning Core - OpenSearch Serverless
################################################################################

# OpenSearch Serverless encryption policy
resource "aws_opensearchserverless_security_policy" "compliance_encryption" {
  name        = "compliance-enc-policy"
  type        = "encryption"
  description = "Encryption policy for compliance collection"

  policy = jsonencode({
    Rules = [
      {
        ResourceType = "collection"
        Resource     = ["collection/${var.opensearch_collection_name}"]
      }
    ],
    AWSOwnedKey = true
  })
}

# OpenSearch Serverless network policy
resource "aws_opensearchserverless_security_policy" "compliance_network" {
  name        = "compliance-net-policy"
  type        = "network"
  description = "Network policy for compliance collection"

  policy = jsonencode([
    {
      Description = "Public access for dashboard and API"
      Rules = [
        {
          ResourceType = "collection"
          Resource     = ["collection/${var.opensearch_collection_name}"]
        },
        {
          ResourceType = "dashboard"
          Resource     = ["collection/${var.opensearch_collection_name}"]
        }
      ]
      AllowFromPublic = true
    }
  ])
}

# OpenSearch Serverless collection
resource "aws_opensearchserverless_collection" "compliance_vectors" {
  name = var.opensearch_collection_name
  type = "VECTORSEARCH"
  
  depends_on = [
    aws_opensearchserverless_security_policy.compliance_encryption,
    aws_opensearchserverless_security_policy.compliance_network
  ]
  
  tags = var.tags
}

# Data access policy for OpenSearch
# Corrected OpenSearch Access Policy
resource "aws_opensearchserverless_access_policy" "compliance_data_access" {
  name = "${var.opensearch_collection_name}-access"
  type = "data"
  
  policy = jsonencode([
    {
      Rules = [
        {
          Resource = [
            "collection/${var.opensearch_collection_name}"
          ]
          Permission = [
            "aoss:CreateCollectionItems",
            "aoss:DeleteCollectionItems",
            "aoss:UpdateCollectionItems",
            "aoss:DescribeCollectionItems"
          ]
          ResourceType = "collection"
        },
        {
          Resource = [
            "index/${var.opensearch_collection_name}/*"
          ]
          Permission = [
            "aoss:CreateIndex",
            "aoss:DeleteIndex",
            "aoss:UpdateIndex",
            "aoss:DescribeIndex",
            "aoss:ReadDocument",
            "aoss:WriteDocument"
          ]
          ResourceType = "index"
        }
      ]
      Principal = [
        "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/bedrock.amazonaws.com/AWSServiceRoleForAmazonBedrock",
        data.aws_caller_identity.current.arn,
        aws_iam_role.bedrock_kb.arn  # <--- THIS IS THE CRITICAL FIX
      ]
    }
  ])
}

# ADDED: OpenSearch Index Resource (Fix for Bedrock KB error)
# Corrected Index Resource with FAISS Engine
resource "opensearch_index" "compliance_index" {
  name               = "compliance-policy-index"
  number_of_shards   = "2"
  number_of_replicas = "0"
  index_knn          = true
  index_knn_algo_param_ef_search = "512"
  
  mappings = <<-EOF
    {
      "properties": {
        "bedrock-knowledge-base-default-vector": {
          "type": "knn_vector",
          "dimension": 1536,
          "method": {
            "name": "hnsw",
            "engine": "faiss",        
            "space_type": "cosinesimil", 
            "parameters": {
              "ef_construction": 512,
              "m": 16
            }
          }
        },
        "AMAZON_BEDROCK_METADATA": {
          "type": "text",
          "index": false
        },
        "AMAZON_BEDROCK_TEXT_CHUNK": {
          "type": "text",
          "index": true
        }
      }
    }
  EOF
  
  force_destroy = true
  
  depends_on = [
    aws_opensearchserverless_collection.compliance_vectors,
    aws_opensearchserverless_access_policy.compliance_data_access,
    aws_opensearchserverless_security_policy.compliance_encryption,
    aws_opensearchserverless_security_policy.compliance_network
  ]
}

################################################################################
# Layer 3: AI Reasoning Core - Bedrock Knowledge Base
################################################################################

# IAM Role for Bedrock Knowledge Base
resource "aws_iam_role" "bedrock_kb" {
  name = "${var.project_name}-bedrock-kb-role"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "bedrock.amazonaws.com"
        }
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
          ArnLike = {
            "aws:SourceArn" = "arn:aws:bedrock:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:knowledge-base/*"
          }
        }
      }
    ]
  })
  
  tags = var.tags
}

# Policy for Bedrock Knowledge Base
resource "aws_iam_role_policy" "bedrock_kb" {
  name = "${var.project_name}-bedrock-kb-policy"
  role = aws_iam_role.bedrock_kb.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.compliance_data.arn,
          "${aws_s3_bucket.compliance_data.arn}/inputs/policy/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel"
        ]
        Resource = "arn:aws:bedrock:${data.aws_region.current.name}::foundation-model/${var.bedrock_embedding_model_id}"
      },
      {
        Effect = "Allow"
        Action = [
          "aoss:APIAccessAll"
        ]
        Resource = aws_opensearchserverless_collection.compliance_vectors.arn
      }
    ]
  })
}

# Bedrock Knowledge Base
resource "aws_bedrockagent_knowledge_base" "compliance_policy" {
  name     = var.knowledge_base_name
  role_arn = aws_iam_role.bedrock_kb.arn
  
  knowledge_base_configuration {
    vector_knowledge_base_configuration {
      embedding_model_arn = "arn:aws:bedrock:${data.aws_region.current.name}::foundation-model/${var.bedrock_embedding_model_id}"
    }
    type = "VECTOR"
  }
  
  storage_configuration {
    type = "OPENSEARCH_SERVERLESS"
    opensearch_serverless_configuration {
      collection_arn    = aws_opensearchserverless_collection.compliance_vectors.arn
      vector_index_name = "compliance-policy-index"
      
      # CORRECTED MAPPINGS to match opensearch_index resource
      field_mapping {
        vector_field   = "bedrock-knowledge-base-default-vector"
        text_field     = "AMAZON_BEDROCK_TEXT_CHUNK"
        metadata_field = "AMAZON_BEDROCK_METADATA"
      }
    }
  }
  
  depends_on = [
    opensearch_index.compliance_index,
    aws_iam_role_policy.bedrock_kb
  ]
  
  tags = var.tags
}

# Bedrock Knowledge Base Data Source
resource "aws_bedrockagent_data_source" "compliance_policy" {
  knowledge_base_id = aws_bedrockagent_knowledge_base.compliance_policy.id
  name              = "compliance-policy-documents"
  
  data_source_configuration {
    type = "S3"
    s3_configuration {
      bucket_arn = aws_s3_bucket.compliance_data.arn
      inclusion_prefixes = [
        "inputs/policy/"
      ]
    }
  }
  # Removed tags as requested
}

################################################################################
# Layer 2: Auto-DDL Ingestion Layer - Lambda Function
################################################################################

# Package Lambda function code
data "archive_file" "log_ingestion_agent" {
  type        = "zip"
  source_dir  = "${path.module}/src/ingestion_agent"
  output_path = "${path.module}/.terraform/lambda/log_ingestion_agent.zip"
}

# LogIngestionAgent Lambda Function
resource "aws_lambda_function" "log_ingestion_agent" {
  filename         = data.archive_file.log_ingestion_agent.output_path
  function_name    = "${var.project_name}-log-ingestion-agent"
  role            = aws_iam_role.log_ingestion_agent.arn
  handler         = "lambda_function.lambda_handler"
  source_code_hash = data.archive_file.log_ingestion_agent.output_base64sha256
  runtime         = "python3.11"
  timeout         = 300  # 5 minutes for processing and Bedrock invocation
  memory_size     = 512
  
  environment {
    variables = {
      GLUE_DATABASE           = var.glue_database_name
      ATHENA_WORKGROUP        = var.athena_workgroup_name
      BEDROCK_MODEL_ID        = var.bedrock_model_id
      ATHENA_OUTPUT_LOCATION  = "s3://${aws_s3_bucket.compliance_data.bucket}/athena-results/"
    }
  }
  
  tags = var.tags
}

# CloudWatch Log Group for LogIngestionAgent
resource "aws_cloudwatch_log_group" "log_ingestion_agent" {
  name              = "/aws/lambda/${aws_lambda_function.log_ingestion_agent.function_name}"
  retention_in_days = 7
  
  tags = var.tags
}

# S3 Event Notification Permission for Lambda
resource "aws_lambda_permission" "allow_s3_invocation" {
  statement_id  = "AllowExecutionFromS3"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.log_ingestion_agent.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.compliance_data.arn
}

# S3 Event Notification Configuration
resource "aws_s3_bucket_notification" "log_upload_trigger" {
  bucket = aws_s3_bucket.compliance_data.id
  
  lambda_function {
    lambda_function_arn = aws_lambda_function.log_ingestion_agent.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "inputs/logs/"
  }
  
  depends_on = [aws_lambda_permission.allow_s3_invocation]
}

################################################################################
# Layer 3: AI Reasoning Core - Bedrock Agent Action Group Lambda
################################################################################

# IAM Role for Agent Athena Executor Lambda
resource "aws_iam_role" "agent_athena_executor" {
  name = "${var.project_name}-agent-athena-executor-role"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
  
  tags = var.tags
}

# Policy for Agent Athena Executor Lambda
resource "aws_iam_role_policy" "agent_athena_executor" {
  name = "${var.project_name}-agent-athena-executor-policy"
  role = aws_iam_role.agent_athena_executor.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "athena:StartQueryExecution",
          "athena:GetQueryExecution",
          "athena:GetQueryResults"
        ]
        Resource = [
          aws_athena_workgroup.compliance_auditor.arn
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "glue:GetDatabase",
          "glue:GetTable",
          "glue:GetTables"
        ]
        Resource = [
          "arn:aws:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:catalog",
          "arn:aws:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:database/${var.glue_database_name}",
          "arn:aws:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:table/${var.glue_database_name}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket"
        ]
        Resource = [
          "${aws_s3_bucket.compliance_data.arn}/athena-results/*",
          "${aws_s3_bucket.compliance_data.arn}/inputs/logs/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/*"
      }
    ]
  })
}

# Package Agent Athena Executor Lambda
data "archive_file" "agent_athena_executor" {
  type        = "zip"
  source_dir  = "${path.module}/src/agent_athena_executor"
  output_path = "${path.module}/.terraform/lambda/agent_athena_executor.zip"
}

# Agent Athena Executor Lambda Function
resource "aws_lambda_function" "agent_athena_executor" {
  filename         = data.archive_file.agent_athena_executor.output_path
  function_name    = "${var.project_name}-agent-athena-executor"
  role            = aws_iam_role.agent_athena_executor.arn
  handler         = "lambda_function.lambda_handler"
  source_code_hash = data.archive_file.agent_athena_executor.output_base64sha256
  runtime         = "python3.11"
  timeout         = 120
  memory_size     = 512
  
  environment {
    variables = {
      GLUE_DATABASE          = var.glue_database_name
      ATHENA_WORKGROUP       = var.athena_workgroup_name
      ATHENA_OUTPUT_LOCATION = "s3://${aws_s3_bucket.compliance_data.bucket}/athena-results/"
    }
  }
  
  tags = var.tags
}

# CloudWatch Log Group for Agent Athena Executor
resource "aws_cloudwatch_log_group" "agent_athena_executor" {
  name              = "/aws/lambda/${aws_lambda_function.agent_athena_executor.function_name}"
  retention_in_days = 7
  
  tags = var.tags
}

# Lambda permission for Bedrock Agent to invoke
resource "aws_lambda_permission" "allow_bedrock_agent" {
  statement_id  = "AllowBedrockAgentInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.agent_athena_executor.function_name
  principal     = "bedrock.amazonaws.com"
  source_arn    = "arn:aws:bedrock:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:agent/*"
}

################################################################################
# Layer 3: AI Reasoning Core - Bedrock Agent
################################################################################

# IAM Role for Bedrock Agent
resource "aws_iam_role" "bedrock_agent" {
  name = "${var.project_name}-bedrock-agent-role"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "bedrock.amazonaws.com"
        }
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
          ArnLike = {
            "aws:SourceArn" = "arn:aws:bedrock:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:agent/*"
          }
        }
      }
    ]
  })
  
  tags = var.tags
}

# Policy for Bedrock Agent
resource "aws_iam_role_policy" "bedrock_agent" {
  name = "${var.project_name}-bedrock-agent-policy"
  role = aws_iam_role.bedrock_agent.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel"
        ]
        Resource = "arn:aws:bedrock:${data.aws_region.current.name}::foundation-model/${var.bedrock_model_id}"
      },
      {
        Effect = "Allow"
        Action = [
          "bedrock:Retrieve"
        ]
        Resource = aws_bedrockagent_knowledge_base.compliance_policy.arn
      },
      {
        Effect = "Allow"
        Action = [
          "lambda:InvokeFunction"
        ]
        Resource = aws_lambda_function.agent_athena_executor.arn
      }
    ]
  })
}

# Bedrock Agent
resource "aws_bedrockagent_agent" "compliance_auditor" {
  agent_name              = var.bedrock_agent_name
  agent_resource_role_arn = aws_iam_role.bedrock_agent.arn
  foundation_model        = var.bedrock_model_id
  
  instruction = <<-EOT
You are an expert IT Compliance Auditor specializing in analyzing system logs against the Keppel Technology Standards.

Your responsibilities:
1. Analyze log data from multiple sources (ServiceNow, Cato, Saviynt, Syslogs) to identify compliance violations
2. Cross-reference log findings with specific policy sections from the Knowledge Base
3. Provide evidence-based compliance assessments with specific log entry citations
4. Identify patterns of non-compliance and security risks

When analyzing a policy section:
1. First, use the list-views tool to see what log sources are available
2. Query the Knowledge Base to understand the specific requirements of the policy section
3. Use the query-athena tool to search for relevant log entries that demonstrate compliance or violations
4. For each finding, cite specific log entries with timestamps, user IDs, and relevant details
5. Categorize findings as: COMPLIANT, NON-COMPLIANT, or REQUIRES_ATTENTION
6. Provide a summary with risk level (HIGH, MEDIUM, LOW) for non-compliant findings

Always be thorough, accurate, and cite specific evidence from both logs and policy documents.
EOT
  
  tags = var.tags
}

# Bedrock Agent Action Group for Athena Queries
resource "aws_bedrockagent_agent_action_group" "query_logs" {
  action_group_name          = "QueryLogsActionGroup"
  agent_id                   = aws_bedrockagent_agent.compliance_auditor.agent_id
  agent_version              = "DRAFT"
  skip_resource_in_use_check = true
  
  action_group_executor {
    lambda = aws_lambda_function.agent_athena_executor.arn
  }
  
  api_schema {
    payload = file("${path.module}/agent_schema.json")
  }
  
  description = "Allows the agent to query Athena views and list available log sources"
}

# Bedrock Agent Knowledge Base Association
resource "aws_bedrockagent_agent_knowledge_base_association" "compliance_policy" {
  agent_id             = aws_bedrockagent_agent.compliance_auditor.agent_id
  agent_version        = "DRAFT"
  knowledge_base_id    = aws_bedrockagent_knowledge_base.compliance_policy.id
  description          = "Keppel Technology Standards policy documents"
  knowledge_base_state = "ENABLED"
}

# Prepare Bedrock Agent (creates alias and version)
resource "aws_bedrockagent_agent_alias" "compliance_auditor_prod" {
  agent_alias_name = "production"
  agent_id         = aws_bedrockagent_agent.compliance_auditor.agent_id
  description      = "Production alias for Compliance Auditor Agent"
  
  tags = var.tags
}

################################################################################
# Layer 4: Orchestration & Reporting - Lambda Functions
################################################################################

# IAM Role for Policy Section Fetcher Lambda
resource "aws_iam_role" "policy_section_fetcher" {
  name = "${var.project_name}-policy-section-fetcher-role"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
  
  tags = var.tags
}

# Policy for Policy Section Fetcher Lambda
resource "aws_iam_role_policy" "policy_section_fetcher" {
  name = "${var.project_name}-policy-section-fetcher-policy"
  role = aws_iam_role.policy_section_fetcher.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.compliance_data.arn,
          "${aws_s3_bucket.compliance_data.arn}/inputs/policy/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel"
        ]
        Resource = "arn:aws:bedrock:${data.aws_region.current.name}::foundation-model/${var.bedrock_model_id}"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/*"
      }
    ]
  })
}

# Package Policy Section Fetcher Lambda
data "archive_file" "policy_section_fetcher" {
  type        = "zip"
  source_dir  = "${path.module}/src/policy_section_fetcher"
  output_path = "${path.module}/.terraform/lambda/policy_section_fetcher.zip"
}

# Policy Section Fetcher Lambda Function
resource "aws_lambda_function" "policy_section_fetcher" {
  filename         = data.archive_file.policy_section_fetcher.output_path
  function_name    = "${var.project_name}-policy-section-fetcher"
  role            = aws_iam_role.policy_section_fetcher.arn
  handler         = "lambda_function.lambda_handler"
  source_code_hash = data.archive_file.policy_section_fetcher.output_base64sha256
  runtime         = "python3.11"
  timeout         = 120
  memory_size     = 512
  
  environment {
    variables = {
      BEDROCK_MODEL_ID = var.bedrock_model_id
      POLICY_BUCKET    = aws_s3_bucket.compliance_data.bucket
      POLICY_PREFIX    = "inputs/policy/"
    }
  }
  
  tags = var.tags
}

# CloudWatch Log Group for Policy Section Fetcher
resource "aws_cloudwatch_log_group" "policy_section_fetcher" {
  name              = "/aws/lambda/${aws_lambda_function.policy_section_fetcher.function_name}"
  retention_in_days = 7
  
  tags = var.tags
}

# IAM Role for Report Generator Lambda
resource "aws_iam_role" "report_generator" {
  name = "${var.project_name}-report-generator-role"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
  
  tags = var.tags
}

# Policy for Report Generator Lambda
resource "aws_iam_role_policy" "report_generator" {
  name = "${var.project_name}-report-generator-policy"
  role = aws_iam_role.report_generator.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:PutObjectAcl"
        ]
        Resource = [
          "${aws_s3_bucket.compliance_data.arn}/outputs/reports/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/*"
      }
    ]
  })
}

# Lambda Layer for python-docx
resource "aws_lambda_layer_version" "python_docx" {
  filename            = "${path.module}/.terraform/layers/python-docx.zip"
  layer_name          = "${var.project_name}-python-docx"
  compatible_runtimes = ["python3.11"]
  description         = "Python-docx library for generating Word documents"
  
  lifecycle {
    create_before_destroy = true
  }
}

# Package Report Generator Lambda
data "archive_file" "report_generator" {
  type        = "zip"
  source_dir  = "${path.module}/src/report_generator"
  output_path = "${path.module}/.terraform/lambda/report_generator.zip"
}

# Report Generator Lambda Function
resource "aws_lambda_function" "report_generator" {
  filename         = data.archive_file.report_generator.output_path
  function_name    = "${var.project_name}-report-generator"
  role            = aws_iam_role.report_generator.arn
  handler         = "lambda_function.lambda_handler"
  source_code_hash = data.archive_file.report_generator.output_base64sha256
  runtime         = "python3.11"
  timeout         = 300
  memory_size     = 1024
  
  layers = [aws_lambda_layer_version.python_docx.arn]
  
  environment {
    variables = {
      OUTPUT_BUCKET = aws_s3_bucket.compliance_data.bucket
      OUTPUT_PREFIX = "outputs/reports/"
    }
  }
  
  tags = var.tags
}

# CloudWatch Log Group for Report Generator
resource "aws_cloudwatch_log_group" "report_generator" {
  name              = "/aws/lambda/${aws_lambda_function.report_generator.function_name}"
  retention_in_days = 7
  
  tags = var.tags
}

################################################################################
# Layer 4: Orchestration & Reporting - Step Functions
################################################################################

# IAM Role for Step Functions
resource "aws_iam_role" "step_functions" {
  name = "${var.project_name}-step-functions-role"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "states.amazonaws.com"
        }
      }
    ]
  })
  
  tags = var.tags
}

# Policy for Step Functions
resource "aws_iam_role_policy" "step_functions" {
  name = "${var.project_name}-step-functions-policy"
  role = aws_iam_role.step_functions.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "lambda:InvokeFunction"
        ]
        Resource = [
          aws_lambda_function.policy_section_fetcher.arn,
          aws_lambda_function.report_generator.arn,
          # Added the Agent Invoker lambda if you added it in the previous step
          "arn:aws:lambda:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:function:${var.project_name}-agent-invoker"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeAgent"
        ]
        Resource = [
          aws_bedrockagent_agent.compliance_auditor.agent_arn,
          "${aws_bedrockagent_agent.compliance_auditor.agent_arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogDelivery",
          "logs:GetLogDelivery",
          "logs:UpdateLogDelivery",
          "logs:DeleteLogDelivery",
          "logs:ListLogDeliveries",
          "logs:PutResourcePolicy",
          "logs:DescribeResourcePolicies",
          "logs:DescribeLogGroups",
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        # Broadened resource to fix AccessDenied error
        Resource = "*"
      }
    ]
  })
}
# IAM Role for Agent Invoker Lambda
resource "aws_iam_role" "agent_invoker" {
  name = "${var.project_name}-agent-invoker-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" } }]
  })
}

# Policy to allow Lambda to invoke Bedrock Agent
resource "aws_iam_role_policy" "agent_invoker_policy" {
  name = "${var.project_name}-agent-invoker-policy"
  role = aws_iam_role.agent_invoker.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["bedrock:InvokeAgent"]
        Resource = [aws_bedrockagent_agent_alias.compliance_auditor_prod.agent_alias_arn]
      },
      {
        Effect = "Allow"
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# Simple Inline Lambda to Invoke Agent
resource "aws_lambda_function" "agent_invoker" {
  function_name = "${var.project_name}-agent-invoker"
  role          = aws_iam_role.agent_invoker.arn
  runtime       = "python3.11"
  handler       = "index.lambda_handler"
  timeout       = 60

  # Inline code to avoid needing another zip file
  filename      = data.archive_file.agent_invoker_zip.output_path
  source_code_hash = data.archive_file.agent_invoker_zip.output_base64sha256
}

# Create zip for inline lambda
data "archive_file" "agent_invoker_zip" {
  type        = "zip"
  output_path = "${path.module}/.terraform/lambda/agent_invoker.zip"
  source {
    content  = <<EOF
import boto3
import json
import uuid

client = boto3.client('bedrock-agent-runtime')

def lambda_handler(event, context):
    agent_id = event['agent_id']
    alias_id = event['agent_alias_id']
    input_text = event['input_text']
    session_id = event.get('session_id', str(uuid.uuid4()))

    response = client.invoke_agent(
        agentId=agent_id,
        agentAliasId=alias_id,
        sessionId=session_id,
        inputText=input_text
    )
    
    # Parse the event stream
    completion = ""
    for event in response.get('completion'):
        if 'chunk' in event:
            completion += event['chunk']['bytes'].decode('utf-8')
            
    return {'completion': completion}
EOF
    filename = "index.py"
  }
}
# Step Functions State Machine
resource "aws_sfn_state_machine" "compliance_workflow" {
  name     = "${var.project_name}-workflow"
  role_arn = aws_iam_role.step_functions.arn
  
  definition = jsonencode({
    Comment = "AI-Driven Compliance Reporting Workflow"
    StartAt = "FetchPolicySections"
    States = {
      FetchPolicySections = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.policy_section_fetcher.arn
          "Payload.$"  = "$"
        }
        ResultPath = "$.section_result"
        Next       = "ExtractSections"
      }
      ExtractSections = {
        Type = "Pass"
        Parameters = {
          "policy_file.$" = "$.section_result.Payload.policy_file"
          "sections.$"    = "$.section_result.Payload.sections"
        }
        Next = "AnalyzeSectionsInParallel"
      }
      AnalyzeSectionsInParallel = {
        Type     = "Map"
        ItemsPath = "$.sections"
        MaxConcurrency = 5
        ResultPath = "$.findings"
        Parameters = {
          "section.$"     = "$$.Map.Item.Value"
          "policy_file.$" = "$.policy_file"
          "agent_id"      = aws_bedrockagent_agent.compliance_auditor.agent_id
          "agent_alias_id" = aws_bedrockagent_agent_alias.compliance_auditor_prod.agent_alias_id
        }
        Iterator = {
          StartAt = "AnalyzeSection"
          States = {
            AnalyzeSection = {
              Type     = "Task"
              # FIX: Call the Shim Lambda instead of Bedrock directly
              Resource = "arn:aws:states:::lambda:invoke" 
              Parameters = {
                FunctionName = aws_lambda_function.agent_invoker.arn
                Payload = {
                  "agent_id.$"       = "$.agent_id"
                  "agent_alias_id.$" = "$.agent_alias_id"
                  "input_text.$"     = "States.Format('Analyze compliance for policy section: {}. Query the available log views to find evidence of compliance or violations. Cross-reference with the policy requirements from the Knowledge Base. Provide specific log entries as evidence.', $.section)"
                }
              }
              ResultPath = "$.agent_response"
              Next       = "FormatFinding"
            }
            FormatFinding = {
              Type = "Pass"
              Parameters = {
                "section.$"           = "$.section"
                # Output from Lambda comes in .Payload.completion
                "analysis.$"          = "$.agent_response.Payload.completion"
                "compliance_status"   = "REQUIRES_REVIEW"
                "risk_level"          = "MEDIUM"
                "evidence"            = []
                "recommendation"      = "Review agent analysis for detailed recommendations"
              }
              End = true
            }
          }
        }
        Next = "GenerateReport"
      }
      GenerateReport = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.report_generator.arn
          Payload = {
            "policy_file.$" = "$.policy_file"
            "findings.$"    = "$.findings"
          }
        }
        ResultPath = "$.report_result"
        Next       = "WorkflowComplete"
      }
      WorkflowComplete = {
        Type = "Pass"
        Parameters = {
          "status"           = "SUCCESS"
          "policy_file.$"    = "$.policy_file"
          "sections_count.$" = "States.ArrayLength($.sections)"
          "report_location.$" = "$.report_result.Payload.report_location"
        }
        End = true
      }
    }
  })
  
  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.step_functions.arn}:*"
    include_execution_data = true
    level                  = "ALL"
  }
  tags = var.tags
}

# CloudWatch Log Group for Step Functions
resource "aws_cloudwatch_log_group" "step_functions" {
  name              = "/aws/vendedlogs/states/${var.project_name}-workflow"
  retention_in_days = 7
  
  tags = var.tags
}
