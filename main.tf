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
    time = {
      source  = "hashicorp/time"
      version = "~> 0.9"
    }
  }
}

# Fetch the full ARN of the Inference Profile
data "aws_bedrock_inference_profile" "current" {
  inference_profile_id = var.bedrock_model_id
}
# 1. DEFINE PROVIDERS


# Second Provider for the Identity Account (Shared Services - KEP_APP_SS)
provider "aws" {
  alias  = "identity_account"
  region = var.aws_region

  assume_role {
    role_arn     = "arn:aws:iam::304838292196:role/CrossAccountCognitoRole"
    session_name = "TerraformCognitoSession"
  }
}
provider "aws" {
  region = var.aws_region
  assume_role {
    role_arn     = "arn:aws:iam::430118833069:role/KAIZERODeploymentServer"
    session_name = "TerraformDeploymentSession"
  }
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

# [NEW] Allow the React App to access S3
resource "aws_s3_bucket_cors_configuration" "compliance_cors" {
  bucket = aws_s3_bucket.compliance_data.id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "PUT", "POST", "HEAD", "DELETE"]
    allowed_origins = [
      "http://localhost:3000",
      "https://${aws_cloudfront_distribution.frontend.domain_name}"
    ]
    expose_headers  = ["ETag", "x-amz-meta-custom-header"]
    max_age_seconds = 3000
  }
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

resource "aws_s3_object" "inputs_vapt" {
  bucket  = aws_s3_bucket.compliance_data.id
  key     = "inputs/VAPT/"
  content = ""
}

resource "aws_s3_object" "inputs_qualys" {
  bucket  = aws_s3_bucket.compliance_data.id
  key     = "inputs/QUALYS/"
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

# IAM Role for LogIngestionAgent Lambda AND Glue Crawler
resource "aws_iam_role" "log_ingestion_agent" {
  name = "${var.project_name}-log-ingestion-agent-role"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = [
            "lambda.amazonaws.com",
            "glue.amazonaws.com"
          ]
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
          "s3:PutObject",
          "s3:GetBucketLocation",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.compliance_data.arn,
          "${aws_s3_bucket.compliance_data.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "glue:StartCrawler"
        ]
        Resource = "*" 
      },
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel"
        ]
        Resource = [
          data.aws_bedrock_inference_profile.current.inference_profile_arn
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "athena:StartQueryExecution",
          "athena:GetQueryExecution",
          "athena:GetQueryResults"
        ]
        Resource = "*" 
      },
      {
        Effect = "Allow"
        Action = [
          "glue:GetDatabase",
          "glue:GetTable",
          "glue:GetTables",
          "glue:CreateTable",
          "glue:UpdateTable",
		  "glue:BatchGetPartition",
          "glue:BatchCreatePartition",
          "glue:BatchUpdatePartition"
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
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = [
          "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/*",
          "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws-glue/*"
        ]
      }
    ]
  })
}

################################################################################
# Layer 3: AI Reasoning Core - OpenSearch Serverless
################################################################################





################################################################################
# Layer 3: AI Reasoning Core - Bedrock Knowledge Base
################################################################################

# OpenSearch Serverless Collection for Vector Store
resource "aws_opensearchserverless_security_policy" "encryption" {
  name        = "${var.project_name}-enc-15jan"
  type        = "encryption"
  description = "Encryption policy for compliance KB collection"
  policy = jsonencode({
    Rules = [
      {
        Resource     = ["collection/${var.opensearch_collection_name}"]
        ResourceType = "collection"
      }
    ]
    AWSOwnedKey = true
  })

  lifecycle {
    ignore_changes = [policy, description]
  }
}

resource "aws_opensearchserverless_security_policy" "network" {
  name        = "${var.project_name}-net-15jan"
  type        = "network"
  description = "Network policy for compliance KB collection"
  policy = jsonencode([
    {
      Rules = [
        {
          Resource     = ["collection/${var.opensearch_collection_name}"]
          ResourceType = "collection"
        }
      ]
      AllowFromPublic = true
    }
  ])
}

resource "aws_opensearchserverless_access_policy" "data" {
  name        = "${var.project_name}-data-15jan"
  type        = "data"
  description = "Data access policy for Bedrock Knowledge Base"
  policy = jsonencode([
    {
      Rules = [
        {
          Resource     = ["collection/${var.opensearch_collection_name}"]
          ResourceType = "collection"
          Permission   = [
            "aoss:CreateCollectionItems",
            "aoss:DeleteCollectionItems",
            "aoss:UpdateCollectionItems",
            "aoss:DescribeCollectionItems"
          ]
        },
        {
          Resource     = ["index/${var.opensearch_collection_name}/*"]
          ResourceType = "index"
          Permission   = [
            "aoss:CreateIndex",
            "aoss:DeleteIndex",
            "aoss:UpdateIndex",
            "aoss:DescribeIndex",
            "aoss:ReadDocument",
            "aoss:WriteDocument"
          ]
        }
      ]
      Principal = [
        aws_iam_role.bedrock_kb_role.arn,
        data.aws_caller_identity.current.arn,
        "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/KAIZERODeploymentServer",
        "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/GitHubActions-SOLAR-Deploy"
      ]
    }
  ])
}

resource "aws_opensearchserverless_collection" "kb_collection" {
  name        = var.opensearch_collection_name
  type        = "VECTORSEARCH"
  description = "Vector store for compliance policy Knowledge Base"

  depends_on = [
    aws_opensearchserverless_security_policy.encryption,
    aws_opensearchserverless_security_policy.network,
    aws_opensearchserverless_access_policy.data
  ]

  tags = var.tags
}

# Create the vector index for Bedrock Knowledge Base using null_resource
# This avoids the circular dependency issue with the opensearch provider
resource "null_resource" "create_opensearch_index" {
  triggers = {
    collection_endpoint = aws_opensearchserverless_collection.kb_collection.collection_endpoint
    caller_arn = data.aws_caller_identity.current.arn
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -ex
      pip3 install awscurl --quiet
      
      echo "Waiting for Policy KB collection to be active..."
      for i in 1 2 3 4 5 6 7 8 9 10; do
        STATUS=$(aws opensearchserverless batch-get-collection --names compliance-kb-vectors --query 'collectionDetails[0].status' --output text --region ${var.aws_region} 2>/dev/null || echo "CREATING")
        echo "Attempt $i: Collection status = $STATUS"
        if [ "$STATUS" = "ACTIVE" ]; then break; fi
        sleep 30
      done
      
      [ "$STATUS" != "ACTIVE" ] && echo "ERROR: Collection not active" && exit 1
      
      ENDPOINT="${aws_opensearchserverless_collection.kb_collection.collection_endpoint}"
      INDEX_NAME="bedrock-knowledge-base-default-index-v2"
      
      echo "Creating Policy KB index (will fail silently if exists)..."
      RESULT=$(awscurl --service aoss --region ${var.aws_region} -X PUT "$ENDPOINT/$INDEX_NAME" \
        -H "Content-Type: application/json" \
        -d '{"settings":{"index":{"knn":true}},"mappings":{"properties":{"bedrock-knowledge-base-default-vector":{"type":"knn_vector","dimension":1024,"method":{"engine":"faiss","name":"hnsw","space_type":"l2"}},"AMAZON_BEDROCK_TEXT_CHUNK":{"type":"text"},"AMAZON_BEDROCK_METADATA":{"type":"text","index":false}}}}' 2>&1) || true
      echo "PUT result: $RESULT"
      
      echo "Verifying index exists..."
      VERIFY=$(awscurl --service aoss --region ${var.aws_region} -X GET "$ENDPOINT/_cat/indices" 2>&1) || true
      echo "Indices: $VERIFY"
      
      if echo "$VERIFY" | grep -q "$INDEX_NAME"; then
        echo "Index verified"
        exit 0
      else
        echo "ERROR: Index not found after creation"
        exit 1
      fi
    EOT
  }

  depends_on = [
    aws_opensearchserverless_collection.kb_collection,
    aws_opensearchserverless_access_policy.data
  ]
}

# IAM Role for Bedrock Knowledge Base
resource "aws_iam_role" "bedrock_kb_role" {
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
            "aws:SourceArn" = "arn:aws:bedrock:${var.aws_region}:${data.aws_caller_identity.current.account_id}:knowledge-base/*"
          }
        }
      }
    ]
  })

  tags = var.tags

  lifecycle {
    ignore_changes = [assume_role_policy, tags]
  }
}

resource "aws_iam_role_policy" "bedrock_kb_policy" {
  name = "${var.project_name}-bedrock-kb-policy"
  role = aws_iam_role.bedrock_kb_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel"
        ]
        Resource = [
          "arn:aws:bedrock:${var.aws_region}::foundation-model/${var.bedrock_embedding_model_id}",
          "arn:aws:bedrock:*::foundation-model/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.compliance_data.arn,
          "${aws_s3_bucket.compliance_data.arn}/inputs/policy/*",
          "${aws_s3_bucket.compliance_data.arn}/inputs/SOCreports/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "aoss:APIAccessAll"
        ]
        Resource = [
          "arn:aws:aoss:${var.aws_region}:${data.aws_caller_identity.current.account_id}:collection/*"
        ]
      }
    ]
  })
}

# Bedrock Knowledge Base
resource "aws_bedrockagent_knowledge_base" "compliance_kb" {
  name        = var.knowledge_base_name
  description = "Knowledge Base for Keppel Technology and Cybersecurity Standards compliance policies"
  role_arn    = aws_iam_role.bedrock_kb_role.arn

  knowledge_base_configuration {
    type = "VECTOR"
    vector_knowledge_base_configuration {
      embedding_model_arn = "arn:aws:bedrock:${var.aws_region}::foundation-model/${var.bedrock_embedding_model_id}"
    }
  }

  storage_configuration {
    type = "OPENSEARCH_SERVERLESS"
    opensearch_serverless_configuration {
      collection_arn    = aws_opensearchserverless_collection.kb_collection.arn
      vector_index_name = "bedrock-knowledge-base-default-index-v2"
      field_mapping {
        vector_field   = "bedrock-knowledge-base-default-vector"
        text_field     = "AMAZON_BEDROCK_TEXT_CHUNK"
        metadata_field = "AMAZON_BEDROCK_METADATA"
      }
    }
  }

  tags = var.tags

  depends_on = [
    aws_iam_role_policy.bedrock_kb_policy,
    aws_opensearchserverless_collection.kb_collection,
    null_resource.create_opensearch_index
  ]
}

# Knowledge Base Data Source (S3)
resource "aws_bedrockagent_data_source" "policy_documents" {
  name                 = "${var.project_name}-policy-docs"
  knowledge_base_id    = aws_bedrockagent_knowledge_base.compliance_kb.id
  description          = "Policy documents from S3 bucket"
  data_deletion_policy = "RETAIN"

  data_source_configuration {
    type = "S3"
    s3_configuration {
      bucket_arn = aws_s3_bucket.compliance_data.arn
      inclusion_prefixes = ["inputs/policy/"]
    }
  }
}

################################################################################
# SOC2 Reports Knowledge Base (Separate from Policy KB)
################################################################################

# OpenSearch Collection for SOC2 KB
resource "aws_opensearchserverless_security_policy" "soc2_encryption" {
  name        = "soc2-kb-enc"
  type        = "encryption"
  description = "Encryption policy for SOC2 KB collection"
  policy = jsonencode({
    Rules = [
      {
        Resource     = ["collection/soc2-reports-vectors"]
        ResourceType = "collection"
      }
    ]
    AWSOwnedKey = true
  })
}

resource "aws_opensearchserverless_security_policy" "soc2_network" {
  name        = "soc2-kb-net"
  type        = "network"
  description = "Network policy for SOC2 KB collection"
  policy = jsonencode([
    {
      Rules = [
        {
          Resource     = ["collection/soc2-reports-vectors"]
          ResourceType = "collection"
        }
      ]
      AllowFromPublic = true
    }
  ])
}

resource "aws_opensearchserverless_access_policy" "soc2_data" {
  name        = "soc2-kb-data"
  type        = "data"
  description = "Data access policy for SOC2 Knowledge Base"
  policy = jsonencode([
    {
      Rules = [
        {
          Resource     = ["collection/soc2-reports-vectors"]
          ResourceType = "collection"
          Permission   = [
            "aoss:CreateCollectionItems",
            "aoss:DeleteCollectionItems",
            "aoss:UpdateCollectionItems",
            "aoss:DescribeCollectionItems"
          ]
        },
        {
          Resource     = ["index/soc2-reports-vectors/*"]
          ResourceType = "index"
          Permission   = [
            "aoss:CreateIndex",
            "aoss:DeleteIndex",
            "aoss:UpdateIndex",
            "aoss:DescribeIndex",
            "aoss:ReadDocument",
            "aoss:WriteDocument"
          ]
        }
      ]
      Principal = [
        aws_iam_role.bedrock_kb_role.arn,
        data.aws_caller_identity.current.arn,
        "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/KAIZERODeploymentServer",
        "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/GitHubActions-SOLAR-Deploy"
      ]
    }
  ])
}

resource "aws_opensearchserverless_collection" "soc2_collection" {
  name        = "soc2-reports-vectors"
  type        = "VECTORSEARCH"
  description = "Vector store for SOC2 Reports Knowledge Base"

  depends_on = [
    aws_opensearchserverless_security_policy.soc2_encryption,
    aws_opensearchserverless_security_policy.soc2_network,
    aws_opensearchserverless_access_policy.soc2_data
  ]

  tags = var.tags
}

# Create vector index for SOC2 KB
resource "null_resource" "create_soc2_opensearch_index" {
  triggers = {
    collection_endpoint = aws_opensearchserverless_collection.soc2_collection.collection_endpoint
    caller_arn = data.aws_caller_identity.current.arn
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -ex
      pip3 install awscurl --quiet
      
      echo "Waiting for SOC2 collection to be active..."
      for i in 1 2 3 4 5 6 7 8 9 10; do
        STATUS=$(aws opensearchserverless batch-get-collection --names soc2-reports-vectors --query 'collectionDetails[0].status' --output text --region ${var.aws_region} 2>/dev/null || echo "CREATING")
        echo "Attempt $i: Collection status = $STATUS"
        if [ "$STATUS" = "ACTIVE" ]; then break; fi
        sleep 30
      done
      
      [ "$STATUS" != "ACTIVE" ] && echo "ERROR: Collection not active" && exit 1
      
      ENDPOINT="${aws_opensearchserverless_collection.soc2_collection.collection_endpoint}"
      INDEX_NAME="bedrock-soc2-index"
      
      echo "Creating SOC2 index (will fail silently if exists)..."
      RESULT=$(awscurl --service aoss --region ${var.aws_region} -X PUT "$ENDPOINT/$INDEX_NAME" \
        -H "Content-Type: application/json" \
        -d '{"settings":{"index":{"knn":true}},"mappings":{"properties":{"bedrock-knowledge-base-default-vector":{"type":"knn_vector","dimension":1024,"method":{"engine":"faiss","name":"hnsw","space_type":"l2"}},"AMAZON_BEDROCK_TEXT_CHUNK":{"type":"text"},"AMAZON_BEDROCK_METADATA":{"type":"text","index":false}}}}' 2>&1) || true
      echo "PUT result: $RESULT"
      
      echo "Verifying index exists..."
      VERIFY=$(awscurl --service aoss --region ${var.aws_region} -X GET "$ENDPOINT/_cat/indices" 2>&1) || true
      echo "Indices: $VERIFY"
      
      if echo "$VERIFY" | grep -q "$INDEX_NAME"; then
        echo "Index verified"
        exit 0
      else
        echo "ERROR: Index not found after creation"
        exit 1
      fi
    EOT
  }

  depends_on = [
    aws_opensearchserverless_collection.soc2_collection,
    aws_opensearchserverless_access_policy.soc2_data
  ]
}

# SOC2 Knowledge Base
resource "aws_bedrockagent_knowledge_base" "soc2_kb" {
  name        = "SOC2-Reports-KB"
  description = "Knowledge Base for vendor SOC2 compliance reports"
  role_arn    = aws_iam_role.bedrock_kb_role.arn

  knowledge_base_configuration {
    type = "VECTOR"
    vector_knowledge_base_configuration {
      embedding_model_arn = "arn:aws:bedrock:${var.aws_region}::foundation-model/${var.bedrock_embedding_model_id}"
    }
  }

  storage_configuration {
    type = "OPENSEARCH_SERVERLESS"
    opensearch_serverless_configuration {
      collection_arn    = aws_opensearchserverless_collection.soc2_collection.arn
      vector_index_name = "bedrock-soc2-index"
      field_mapping {
        vector_field   = "bedrock-knowledge-base-default-vector"
        text_field     = "AMAZON_BEDROCK_TEXT_CHUNK"
        metadata_field = "AMAZON_BEDROCK_METADATA"
      }
    }
  }

  tags = var.tags

  depends_on = [
    aws_iam_role_policy.bedrock_kb_policy,
    aws_opensearchserverless_collection.soc2_collection,
    null_resource.create_soc2_opensearch_index
  ]
}

# SOC2 KB Data Source (S3 - SOCreports folder)
resource "aws_bedrockagent_data_source" "soc2_documents" {
  name                 = "${var.project_name}-soc2-docs"
  knowledge_base_id    = aws_bedrockagent_knowledge_base.soc2_kb.id
  description          = "SOC2 reports from S3 bucket"
  data_deletion_policy = "RETAIN"

  data_source_configuration {
    type = "S3"
    s3_configuration {
      bucket_arn = aws_s3_bucket.compliance_data.arn
      inclusion_prefixes = ["inputs/SOCreports/"]
    }
  }
}

# Associate SOC2 KB with the Bedrock Agent
resource "aws_bedrockagent_agent_knowledge_base_association" "soc2_reports" {
  agent_id             = aws_bedrockagent_agent.compliance_auditor.agent_id
  agent_version        = "DRAFT"
  knowledge_base_id    = aws_bedrockagent_knowledge_base.soc2_kb.id
  description          = "Vendor SOC2 compliance reports for control validation"
  knowledge_base_state = "ENABLED"
  
  depends_on = [
    aws_bedrockagent_agent_knowledge_base_association.compliance_policy,
    aws_bedrockagent_knowledge_base.soc2_kb
  ]
}

################################################################################
# VAPT/Qualys Knowledge Base
################################################################################

resource "aws_opensearchserverless_security_policy" "vapt_encryption" {
  name        = "vapt-kb-enc"
  type        = "encryption"
  policy = jsonencode({
    Rules = [{ Resource = ["collection/vapt-reports-vectors"], ResourceType = "collection" }]
    AWSOwnedKey = true
  })
}

resource "aws_opensearchserverless_security_policy" "vapt_network" {
  name        = "vapt-kb-net"
  type        = "network"
  policy = jsonencode([{
    Rules = [{ Resource = ["collection/vapt-reports-vectors"], ResourceType = "collection" }]
    AllowFromPublic = true
  }])
}

resource "aws_opensearchserverless_access_policy" "vapt_data" {
  name   = "vapt-kb-data"
  type   = "data"
  policy = jsonencode([{
    Rules = [
      { Resource = ["collection/vapt-reports-vectors"], ResourceType = "collection",
        Permission = ["aoss:CreateCollectionItems", "aoss:DeleteCollectionItems", "aoss:UpdateCollectionItems", "aoss:DescribeCollectionItems"] },
      { Resource = ["index/vapt-reports-vectors/*"], ResourceType = "index",
        Permission = ["aoss:CreateIndex", "aoss:DeleteIndex", "aoss:UpdateIndex", "aoss:DescribeIndex", "aoss:ReadDocument", "aoss:WriteDocument"] }
    ]
    Principal = [
      aws_iam_role.bedrock_kb_role.arn,
      data.aws_caller_identity.current.arn,
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/KAIZERODeploymentServer",
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/GitHubActions-SOLAR-Deploy"
    ]
  }])
}

resource "aws_opensearchserverless_collection" "vapt_collection" {
  name = "vapt-reports-vectors"
  type = "VECTORSEARCH"
  depends_on = [aws_opensearchserverless_security_policy.vapt_encryption, aws_opensearchserverless_security_policy.vapt_network, aws_opensearchserverless_access_policy.vapt_data]
}

resource "null_resource" "create_vapt_opensearch_index" {
  triggers = { collection_endpoint = aws_opensearchserverless_collection.vapt_collection.collection_endpoint }
  
  provisioner "local-exec" {
    command = <<-EOT
      set -ex
      pip3 install awscurl --quiet
      
      echo "Waiting for VAPT collection to be active..."
      for i in 1 2 3 4 5 6 7 8 9 10; do
        STATUS=$(aws opensearchserverless batch-get-collection --names vapt-reports-vectors --query 'collectionDetails[0].status' --output text --region ${var.aws_region} 2>/dev/null || echo "CREATING")
        echo "Attempt $i: Collection status = $STATUS"
        if [ "$STATUS" = "ACTIVE" ]; then break; fi
        sleep 30
      done
      
      [ "$STATUS" != "ACTIVE" ] && echo "ERROR: Collection not active" && exit 1
      
      ENDPOINT="${aws_opensearchserverless_collection.vapt_collection.collection_endpoint}"
      INDEX_NAME="bedrock-vapt-index"
      
      echo "Creating VAPT index (will fail silently if exists)..."
      RESULT=$(awscurl --service aoss --region ${var.aws_region} -X PUT "$ENDPOINT/$INDEX_NAME" \
        -H "Content-Type: application/json" \
        -d '{"settings":{"index":{"knn":true}},"mappings":{"properties":{"bedrock-knowledge-base-default-vector":{"type":"knn_vector","dimension":1024,"method":{"engine":"faiss","name":"hnsw","space_type":"l2"}},"AMAZON_BEDROCK_TEXT_CHUNK":{"type":"text"},"AMAZON_BEDROCK_METADATA":{"type":"text","index":false}}}}' 2>&1) || true
      echo "PUT result: $RESULT"
      
      echo "Verifying index exists..."
      VERIFY=$(awscurl --service aoss --region ${var.aws_region} -X GET "$ENDPOINT/_cat/indices" 2>&1) || true
      echo "Indices: $VERIFY"
      
      if echo "$VERIFY" | grep -q "$INDEX_NAME"; then
        echo "Index verified"
        exit 0
      else
        echo "ERROR: Index not found after creation"
        exit 1
      fi
    EOT
  }
  depends_on = [aws_opensearchserverless_collection.vapt_collection, aws_opensearchserverless_access_policy.vapt_data]
}

resource "aws_bedrockagent_knowledge_base" "vapt_kb" {
  name        = "VAPT-Reports-KB"
  description = "Knowledge Base for VAPT and Qualys vulnerability reports"
  role_arn    = aws_iam_role.bedrock_kb_role.arn

  knowledge_base_configuration {
    type = "VECTOR"
    vector_knowledge_base_configuration {
      embedding_model_arn = "arn:aws:bedrock:${var.aws_region}::foundation-model/${var.bedrock_embedding_model_id}"
    }
  }

  storage_configuration {
    type = "OPENSEARCH_SERVERLESS"
    opensearch_serverless_configuration {
      collection_arn    = aws_opensearchserverless_collection.vapt_collection.arn
      vector_index_name = "bedrock-vapt-index"
      field_mapping {
        vector_field   = "bedrock-knowledge-base-default-vector"
        text_field     = "AMAZON_BEDROCK_TEXT_CHUNK"
        metadata_field = "AMAZON_BEDROCK_METADATA"
      }
    }
  }

  depends_on = [aws_iam_role_policy.bedrock_kb_policy, aws_opensearchserverless_collection.vapt_collection, null_resource.create_vapt_opensearch_index]
}

resource "aws_bedrockagent_data_source" "vapt_documents" {
  name              = "${var.project_name}-vapt-docs"
  knowledge_base_id = aws_bedrockagent_knowledge_base.vapt_kb.id
  description       = "VAPT reports from S3"

  data_source_configuration {
    type = "S3"
    s3_configuration {
      bucket_arn         = aws_s3_bucket.compliance_data.arn
      inclusion_prefixes = ["inputs/VAPT/"]
    }
  }
}

resource "aws_bedrockagent_agent_knowledge_base_association" "vapt_reports" {
  agent_id             = aws_bedrockagent_agent.compliance_auditor.agent_id
  agent_version        = "DRAFT"
  knowledge_base_id    = aws_bedrockagent_knowledge_base.vapt_kb.id
  description          = "VAPT and Qualys vulnerability reports"
  knowledge_base_state = "ENABLED"
  
  depends_on = [aws_bedrockagent_agent_knowledge_base_association.soc2_reports, aws_bedrockagent_knowledge_base.vapt_kb]
}

################################################################################
# Layer 2: Auto-DDL Ingestion Layer - Lambda Function
################################################################################

data "archive_file" "log_ingestion_agent" {
  type        = "zip"
  source_dir  = "${path.module}/src/ingestion_agent"
  output_path = "${path.module}/.terraform/lambda/log_ingestion_agent.zip"
}

resource "aws_lambda_function" "log_ingestion_agent" {
  filename         = data.archive_file.log_ingestion_agent.output_path
  function_name    = "${var.project_name}-log-ingestion-agent"
  role             = aws_iam_role.log_ingestion_agent.arn
  handler          = "lambda_function.lambda_handler"
  source_code_hash = data.archive_file.log_ingestion_agent.output_base64sha256
  runtime          = "python3.11"
  timeout          = 600  
  memory_size      = 1024 
  
  layers           = [aws_lambda_layer_version.pandas_layer.arn]
  
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
resource "aws_lambda_layer_version" "pypdf_layer" {
  filename            = "${path.module}/.terraform/layers/pypdf-layer.zip"
  layer_name          = "${var.project_name}-pypdf-layer"
  compatible_runtimes = ["python3.11"]
  description         = "pypdf library for parsing SOC reports"
  
  source_code_hash    = filebase64sha256("${path.module}/.terraform/layers/pypdf-layer.zip")
}
resource "aws_cloudwatch_log_group" "log_ingestion_agent" {
  name              = "/aws/lambda/${aws_lambda_function.log_ingestion_agent.function_name}"
  retention_in_days = 7
  
  tags = var.tags
}

resource "aws_lambda_permission" "allow_s3_invocation" {
  statement_id  = "AllowExecutionFromS3"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.log_ingestion_agent.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.compliance_data.arn
}

resource "aws_lambda_permission" "allow_s3_policy_trigger" {
  statement_id  = "AllowExecutionFromS3Policy"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.policy_section_fetcher.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.compliance_data.arn
}

resource "aws_s3_bucket_notification" "log_upload_trigger" {
  bucket = aws_s3_bucket.compliance_data.id
  
  lambda_function {
    lambda_function_arn = aws_lambda_function.log_ingestion_agent.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "inputs/logs/"
  }

  lambda_function {
    lambda_function_arn = aws_lambda_function.log_ingestion_agent.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "inputs/QUALYS/"
  }
  
  lambda_function {
    lambda_function_arn = aws_lambda_function.policy_section_fetcher.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "inputs/policy/"
    filter_suffix       = ".pdf"
  }
  
  depends_on = [
    aws_lambda_permission.allow_s3_invocation,
    aws_lambda_permission.allow_s3_policy_trigger
  ]
}

################################################################################
# Policy Sections DynamoDB Cache
################################################################################

resource "aws_dynamodb_table" "policy_sections" {
  name         = "${var.project_name}-policy-sections"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "policy_file"

  attribute {
    name = "policy_file"
    type = "S"
  }

  tags = var.tags
}

resource "aws_dynamodb_table" "audit_history" {
  name         = "${var.project_name}-audit-history"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "user_id"
  range_key    = "timestamp"

  attribute {
    name = "user_id"
    type = "S"
  }

  attribute {
    name = "timestamp"
    type = "S"
  }

  tags = var.tags
}

################################################################################
# Layer 3: AI Reasoning Core - Bedrock Agent Action Group Lambda
################################################################################

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
          "glue:GetTables",
          # NEW: Required permissions for partitioned tables
          "glue:GetPartition",
          "glue:GetPartitions",
          "glue:BatchGetPartition"
        ]
        Resource = [
          "arn:aws:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:catalog",
          "arn:aws:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:database/${var.glue_database_name}",
          "arn:aws:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:table/${var.glue_database_name}/*",
		  
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = [
          "${aws_s3_bucket.compliance_data.arn}",
          "${aws_s3_bucket.compliance_data.arn}/*",
          "${aws_s3_bucket.compliance_data.arn}/athena-results/*",
          "${aws_s3_bucket.compliance_data.arn}/inputs/logs/*",
		  # ADD THIS LINE:
          "${aws_s3_bucket.compliance_data.arn}/inputs/SOCreports/*"
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
data "archive_file" "agent_athena_executor" {
  type        = "zip"
  source_dir  = "${path.module}/src/agent_athena_executor"
  output_path = "${path.module}/.terraform/lambda/agent_athena_executor.zip"
}

resource "aws_lambda_function" "agent_athena_executor" {
  filename         = data.archive_file.agent_athena_executor.output_path
  function_name    = "${var.project_name}-agent-athena-executor"
  role             = aws_iam_role.agent_athena_executor.arn
  handler          = "lambda_function.lambda_handler"
  source_code_hash = data.archive_file.agent_athena_executor.output_base64sha256
  runtime          = "python3.11"
  timeout          = 120
  memory_size      = 512
  layers = [aws_lambda_layer_version.pypdf_layer.arn]
  environment {
    variables = {
      GLUE_DATABASE          = var.glue_database_name
      ATHENA_WORKGROUP       = var.athena_workgroup_name
      ATHENA_OUTPUT_LOCATION = "s3://${aws_s3_bucket.compliance_data.bucket}/athena-results/"
    }
  }
  
  tags = var.tags
}

resource "aws_cloudwatch_log_group" "agent_athena_executor" {
  name              = "/aws/lambda/${aws_lambda_function.agent_athena_executor.function_name}"
  retention_in_days = 7
  
  tags = var.tags
}

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
      }
    ]
  })
  
  tags = var.tags
}

resource "aws_iam_role_policy" "bedrock_agent" {
  name = "${var.project_name}-bedrock-agent-policy"
  role = aws_iam_role.bedrock_agent.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
          "bedrock:GetInferenceProfile",
          "bedrock:ListInferenceProfiles",
          "bedrock:GetFoundationModel",
          "bedrock:ListFoundationModels"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream"
        ]
        Resource = [
          "arn:aws:bedrock:${var.aws_region}:${data.aws_caller_identity.current.account_id}:inference-profile/*",
          "arn:aws:bedrock:*::foundation-model/*",
          "arn:aws:bedrock:*:*:inference-profile/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "bedrock:Retrieve",
          "bedrock:RetrieveAndGenerate"
        ]
        Resource = "*"
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

# Workaround for IAM propagation delay when using inference profiles
# See: https://github.com/hashicorp/terraform-provider-aws/issues/42847
resource "time_sleep" "bedrock_agent_iam_propagation" {
  depends_on      = [aws_iam_role_policy.bedrock_agent]
  create_duration = "30s"
}

resource "aws_bedrockagent_agent" "compliance_auditor" {
  agent_name              = var.bedrock_agent_name
  agent_resource_role_arn = aws_iam_role.bedrock_agent.arn
  foundation_model        = data.aws_bedrock_inference_profile.current.inference_profile_arn
  
  instruction = <<-EOT
You are an IT Compliance Auditor for Keppel validating against 'Keppel Technology and Cybersecurity Standards (TECH-S01-01)'.

You have access to:
- **Policy KB**: Keppel's internal policy requirements
- **SOC2 KB**: Vendor SOC2 reports (PDF) in inputs/SOCreports/{SystemName}/
- **VAPT KB**: VAPT vulnerability reports (PDF) in inputs/VAPT/{SystemName}/
- **Athena**: System logs and Qualys data (CSV/XLSX) - query tables in compliance_db

STRICT RULES:

1. SOC2 EVIDENCE RULE:
   - Each system has its OWN SOC2 report
   - If no SOC2 report exists for the exact system name, write: "SOC2 report not present for [SystemName]"
   - NEVER use SOC2 evidence from one system to validate another

2. PATCHING/VULNERABILITY SECTIONS (8.5, 8.6 or any section mentioning patches, vulnerabilities, VAPT):
   When auditing patching compliance:
   a) FIRST search Policy KB to extract the EXACT remediation timeframes for each severity level
   b) Search VAPT KB for vulnerability findings specific to the system
   c) Query Athena table 'qualys_{system_name}' for Qualys vulnerability data
   d) Query system logs for patch application evidence
   e) Apply the timeframes FROM THE POLICY to determine compliance

3. GAPS RULE:
   - If SOC2/VAPT report is missing → that IS a gap
   - If logs/Qualys data not available → that IS a gap  
   - ALWAYS list gaps in the GAPS IDENTIFIED section

4. FORMAT RULE - Use EXACTLY these headings:

POLICY REQUIREMENTS IDENTIFIED:
[Extract from Policy KB - for patching, include EXACT timeframes for each severity]

SOC2:
[Evidence from this system's SOC2, or "SOC2 report not present for [SystemName]"]

VAPT/QUALYS:
[VAPT KB findings + Qualys Athena query results, or "No VAPT/Qualys data found for [SystemName]"]

LOGS:
[Query results, or "No logs available"]

COMPLIANCE ASSESSMENT:
[COMPLIANT/PARTIALLY COMPLIANT/NON-COMPLIANT/CANNOT ASSESS]

GAPS IDENTIFIED:
[List ALL gaps with policy reference]

RECOMMENDATION:
[Actions to address gaps]
EOT
  
  tags = var.tags
  
  depends_on = [
    aws_iam_role_policy.bedrock_agent,
    time_sleep.bedrock_agent_iam_propagation
  ]
}

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

resource "aws_bedrockagent_agent_knowledge_base_association" "compliance_policy" {
  agent_id             = aws_bedrockagent_agent.compliance_auditor.agent_id
  agent_version        = "DRAFT"
  knowledge_base_id    = aws_bedrockagent_knowledge_base.compliance_kb.id
  description          = "Keppel Technology Standards policy documents"
  knowledge_base_state = "ENABLED"
  
  depends_on = [
    aws_bedrockagent_agent_action_group.query_logs,
    aws_bedrockagent_knowledge_base.compliance_kb
  ]
}

resource "aws_bedrockagent_agent_alias" "compliance_auditor_prod" {
  agent_alias_name = "production"
  agent_id         = aws_bedrockagent_agent.compliance_auditor.agent_id
  description      = "Production alias for Compliance Auditor Agent"
  
  tags = var.tags

  depends_on = [
    aws_bedrockagent_agent_knowledge_base_association.compliance_policy,
    aws_bedrockagent_agent_action_group.query_logs,
    aws_bedrockagent_agent_knowledge_base_association.soc2_reports
  ]
}

################################################################################
# Layer 4: Orchestration & Reporting - Lambda Functions
################################################################################

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
        Resource = [
          "arn:aws:bedrock:*::foundation-model/anthropic.claude-sonnet-4-20250514-v1:0",
          "arn:aws:bedrock:${var.aws_region}::foundation-model/*",
          "arn:aws:bedrock:${var.aws_region}:${data.aws_caller_identity.current.account_id}:inference-profile/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem"
        ]
        Resource = aws_dynamodb_table.policy_sections.arn
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

data "archive_file" "policy_section_fetcher" {
  type        = "zip"
  source_dir  = "${path.module}/src/policy_section_fetcher"
  output_path = "${path.module}/.terraform/lambda/policy_section_fetcher.zip"
}

resource "aws_lambda_function" "policy_section_fetcher" {
  filename         = data.archive_file.policy_section_fetcher.output_path
  function_name    = "${var.project_name}-policy-section-fetcher"
  role             = aws_iam_role.policy_section_fetcher.arn
  handler          = "lambda_function.lambda_handler"
  source_code_hash = data.archive_file.policy_section_fetcher.output_base64sha256
  runtime          = "python3.11"
  timeout          = 120
  memory_size      = 512
  
  environment {
    variables = {
      BEDROCK_MODEL_ID = var.bedrock_model_id
      POLICY_BUCKET    = aws_s3_bucket.compliance_data.bucket
      POLICY_PREFIX    = "inputs/policy/"
      DYNAMODB_TABLE   = aws_dynamodb_table.policy_sections.name
    }
  }
  
  tags = var.tags
}

resource "aws_cloudwatch_log_group" "policy_section_fetcher" {
  name              = "/aws/lambda/${aws_lambda_function.policy_section_fetcher.function_name}"
  retention_in_days = 7
  
  tags = var.tags
}

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

resource "aws_lambda_layer_version" "python_docx" {
  filename            = "${path.module}/.terraform/layers/python-docx.zip"
  layer_name          = "${var.project_name}-python-docx"
  compatible_runtimes = ["python3.11"]
  description         = "Python-docx library for generating Word documents"
  
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lambda_layer_version" "pandas_layer" {
  filename            = "${path.module}/.terraform/layers/pandas-layer.zip"
  layer_name          = "${var.project_name}-pandas-layer"
  compatible_runtimes = ["python3.11"]
  description         = "Pandas and OpenPyXL for Excel processing"
  
  source_code_hash    = filebase64sha256("${path.module}/.terraform/layers/pandas-layer.zip")
}

data "archive_file" "report_generator" {
  type        = "zip"
  source_dir  = "${path.module}/src/report_generator"
  output_path = "${path.module}/.terraform/lambda/report_generator.zip"
}

resource "aws_lambda_function" "report_generator" {
  filename         = data.archive_file.report_generator.output_path
  function_name    = "${var.project_name}-report-generator"
  role             = aws_iam_role.report_generator.arn
  handler          = "lambda_function.lambda_handler"
  source_code_hash = data.archive_file.report_generator.output_base64sha256
  runtime          = "python3.11"
  timeout          = 300
  memory_size      = 1024
  
  layers = [aws_lambda_layer_version.python_docx.arn]
  
  environment {
    variables = {
      OUTPUT_BUCKET = aws_s3_bucket.compliance_data.bucket
      OUTPUT_PREFIX = "outputs/reports/"
    }
  }
  
  tags = var.tags
}

resource "aws_cloudwatch_log_group" "report_generator" {
  name              = "/aws/lambda/${aws_lambda_function.report_generator.function_name}"
  retention_in_days = 7
  
  tags = var.tags
}

resource "aws_glue_crawler" "compliance_crawler" {
  database_name = aws_glue_catalog_database.compliance_db.name
  name          = "${var.project_name}-log-crawler"
  role          = aws_iam_role.log_ingestion_agent.arn

  s3_target {
    path = "s3://${aws_s3_bucket.compliance_data.bucket}/processed/logs/"
  }

  s3_target {
    path = "s3://${aws_s3_bucket.compliance_data.bucket}/processed/qualys/"
  }
  
  schema_change_policy {
    delete_behavior = "DEPRECATE_IN_DATABASE"
    update_behavior = "UPDATE_IN_DATABASE"
  }
  
  tags = var.tags
}

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
          aws_lambda_function.pair_builder.arn,
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
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role" "agent_invoker" {
  name = "${var.project_name}-agent-invoker-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy" "agent_invoker_policy" {
  name = "${var.project_name}-agent-invoker-policy"
  role = aws_iam_role.agent_invoker.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["bedrock:InvokeAgent"]
        Resource = [
					"arn:aws:bedrock:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:agent-alias/${aws_bedrockagent_agent.compliance_auditor.agent_id}/*"
					]
      },
      {
        Effect = "Allow"
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

resource "aws_lambda_function" "agent_invoker" {
  function_name = "${var.project_name}-agent-invoker"
  role          = aws_iam_role.agent_invoker.arn
  runtime       = "python3.11"
  handler       = "index.lambda_handler"
  timeout       = 60

  filename      = data.archive_file.agent_invoker_zip.output_path
  source_code_hash = data.archive_file.agent_invoker_zip.output_base64sha256
}

resource "aws_lambda_function" "pair_builder" {
  function_name = "${var.project_name}-pair-builder"
  role          = aws_iam_role.agent_invoker.arn
  runtime       = "python3.11"
  handler       = "index.lambda_handler"
  timeout       = 10

  filename      = data.archive_file.pair_builder_zip.output_path
  source_code_hash = data.archive_file.pair_builder_zip.output_base64sha256
}

data "archive_file" "pair_builder_zip" {
  type        = "zip"
  output_path = "${path.module}/.terraform/lambda/pair_builder.zip"
  source {
    content  = <<EOF
def lambda_handler(event, context):
    sections = event.get('sections', [])
    systems = event.get('systems', [])
    
    # Build all section+system pairs
    pairs = []
    for section in sections:
        for system in systems:
            pairs.append({'section': section, 'system': system})
    
    return {'pairs': pairs, 'count': len(pairs)}
EOF
    filename = "index.py"
  }
}

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
    section = event.get('section', '')
    system_name = event.get('system_name', '')
    custom_prompts = event.get('custom_prompts', [])
    session_id = event.get('session_id', str(uuid.uuid4()))
    
    # Find custom prompt for this section
    user_prompt = ''
    for p in custom_prompts:
        if p.get('section') == section:
            user_prompt = p.get('prompt', '')
            break
    
    # Convert system name to table name (lowercase, no spaces)
    table_name = system_name.lower().replace(' ', '_').replace('-', '_') if system_name else ''
    
    # Base prompt always used
    input_text = f"Analyze compliance for Policy Section: {section}. System to validate: {system_name}. 1) Search the Policy Knowledge Base for requirements. 2) Search the SOC2 Knowledge Base for {system_name} vendor controls and evidence. 3) Query logs from table '{table_name}' in database 'compliance_db' using Athena. 4) Compare requirements against evidence and cite specific sources."
    
    # Append user's specific focus if provided
    if user_prompt:
        input_text += f" ADDITIONAL USER FOCUS: {user_prompt}. Prioritize this specific aspect in your analysis."

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
            
    return {'completion': completion, 'user_prompt': user_prompt}
EOF
    filename = "index.py"
  }
}

# Step Functions State Machine
resource "aws_sfn_state_machine" "compliance_workflow" {
  name     = "${var.project_name}-workflow"
  role_arn = aws_iam_role.step_functions.arn

  definition = <<EOF
{
  "Comment": "AI-Driven Compliance Reporting Workflow",
  "StartAt": "CheckUserSections",
  "States": {
    "CheckUserSections": {
      "Type": "Choice",
      "Choices": [
        {
          "Variable": "$.sections",
          "IsPresent": true,
          "Next": "UseUserSelectedSections"
        }
      ],
      "Default": "FetchPolicySections"
    },
    "UseUserSelectedSections": {
      "Type": "Pass",
      "Parameters": {
        "policy_file.$": "$.policy_file",
        "sections.$": "$.sections",
        "system_name.$": "$.system_name",
        "systems.$": "$.systems",
        "custom_prompts.$": "$.custom_prompts"
      },
      "Next": "CheckMultipleSystems"
    },
    "CheckMultipleSystems": {
      "Type": "Choice",
      "Choices": [
        {
          "Variable": "$.systems",
          "IsPresent": true,
          "Next": "BuildSectionSystemPairs"
        }
      ],
      "Default": "AnalyzeSectionsInParallel"
    },
    "BuildSectionSystemPairs": {
      "Type": "Task",
      "Resource": "arn:aws:states:::lambda:invoke",
      "Parameters": {
        "FunctionName": "${aws_lambda_function.pair_builder.arn}",
        "Payload": {
          "sections.$": "$.sections",
          "systems.$": "$.systems"
        }
      },
      "ResultPath": "$.pairs_result",
      "Next": "AnalyzePairsInParallel"
    },
    "AnalyzePairsInParallel": {
      "Type": "Map",
      "ItemsPath": "$.pairs_result.Payload.pairs",
      "MaxConcurrency": 5,
      "ResultPath": "$.findings",
      "Parameters": {
        "section.$": "$$.Map.Item.Value.section",
        "system_name.$": "$$.Map.Item.Value.system",
        "policy_file.$": "$.policy_file",
        "custom_prompts.$": "$.custom_prompts",
        "agent_id": "${aws_bedrockagent_agent.compliance_auditor.agent_id}",
        "agent_alias_id": "${aws_bedrockagent_agent_alias.compliance_auditor_prod.agent_alias_id}"
      },
      "Iterator": {
        "StartAt": "GetSectionPromptPair",
        "States": {
          "GetSectionPromptPair": {
            "Type": "Pass",
            "Parameters": {
              "section.$": "$.section",
              "system_name.$": "$.system_name",
              "agent_id.$": "$.agent_id",
              "agent_alias_id.$": "$.agent_alias_id",
              "custom_prompts.$": "$.custom_prompts"
            },
            "Next": "AnalyzeSectionPair"
          },
          "AnalyzeSectionPair": {
            "Type": "Task",
            "Resource": "arn:aws:states:::lambda:invoke",
            "Parameters": {
              "FunctionName": "${aws_lambda_function.agent_invoker.arn}",
              "Payload": {
                "agent_id.$": "$.agent_id",
                "agent_alias_id.$": "$.agent_alias_id",
                "section.$": "$.section",
                "system_name.$": "$.system_name",
                "custom_prompts.$": "$.custom_prompts"
              }
            },
            "ResultPath": "$.agent_response",
            "Next": "FormatFindingPair"
          },
          "FormatFindingPair": {
            "Type": "Pass",
            "Parameters": {
              "section.$": "$.section",
              "system_name.$": "$.system_name",
              "user_query.$": "$.agent_response.Payload.user_prompt",
              "analysis.$": "$.agent_response.Payload.completion",
              "compliance_status": "REQUIRES_REVIEW"
            },
            "End": true
          }
        }
      },
      "Next": "GenerateReport"
    },
    "FetchPolicySections": {
      "Type": "Task",
      "Resource": "arn:aws:states:::lambda:invoke",
      "Parameters": {
        "FunctionName": "${aws_lambda_function.policy_section_fetcher.arn}",
        "Payload.$": "$"
      },
      "ResultPath": "$.section_result",
      "Next": "ExtractSections"
    },
    "ExtractSections": {
      "Type": "Pass",
      "Parameters": {
        "policy_file.$": "$.section_result.Payload.policy_file",
        "sections.$": "$.section_result.Payload.sections",
        "system_name.$": "$.section_result.Payload.system_name",
        "custom_prompts.$": "$.custom_prompts"
      },
      "Next": "AnalyzeSectionsInParallel"
    },
    "AnalyzeSectionsInParallel": {
      "Type": "Map",
      "ItemsPath": "$.sections",
      "MaxConcurrency": 5,
      "ResultPath": "$.findings",
      "Parameters": {
        "section.$": "$$.Map.Item.Value",
        "policy_file.$": "$.policy_file",
        "system_name.$": "$.system_name",
        "custom_prompts.$": "$.custom_prompts",
        "agent_id": "${aws_bedrockagent_agent.compliance_auditor.agent_id}",
        "agent_alias_id": "${aws_bedrockagent_agent_alias.compliance_auditor_prod.agent_alias_id}"
      },
      "Iterator": {
        "StartAt": "GetSectionPrompt",
        "States": {
          "GetSectionPrompt": {
            "Type": "Pass",
            "Parameters": {
              "section.$": "$.section",
              "system_name.$": "$.system_name",
              "agent_id.$": "$.agent_id",
              "agent_alias_id.$": "$.agent_alias_id",
              "custom_prompts.$": "$.custom_prompts"
            },
            "Next": "AnalyzeSection"
          },
          "AnalyzeSection": {
            "Type": "Task",
            "Resource": "arn:aws:states:::lambda:invoke",
            "Parameters": {
              "FunctionName": "${aws_lambda_function.agent_invoker.arn}",
              "Payload": {
                "agent_id.$": "$.agent_id",
                "agent_alias_id.$": "$.agent_alias_id",
                "section.$": "$.section",
                "system_name.$": "$.system_name",
                "custom_prompts.$": "$.custom_prompts"
              }
            },
            "ResultPath": "$.agent_response",
            "Next": "FormatFinding"
          },
          "FormatFinding": {
            "Type": "Pass",
            "Parameters": {
              "section.$": "$.section",
              "user_query.$": "$.agent_response.Payload.user_prompt",
              "analysis.$": "$.agent_response.Payload.completion",
              "compliance_status": "REQUIRES_REVIEW"
            },
            "End": true
          }
        }
      },
      "Next": "GenerateReport"
    },
    "GenerateReport": {
      "Type": "Task",
      "Resource": "arn:aws:states:::lambda:invoke",
      "Parameters": {
        "FunctionName": "${aws_lambda_function.report_generator.arn}",
        "Payload": {
          "policy_file.$": "$.policy_file",
          "system_name.$": "$.system_name",
          "findings.$": "$.findings"
        }
      },
      "ResultPath": "$.report_result",
      "Next": "WorkflowComplete"
    },
    "WorkflowComplete": {
      "Type": "Pass",
      "Parameters": {
        "status": "SUCCESS",
        "policy_file.$": "$.policy_file",
        "report_location.$": "$.report_result.Payload.report_location",
		"html_key.$": "$.report_result.Payload.html_key"
      },
      "End": true
    }
  }
}
EOF

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.step_functions.arn}:*"
    include_execution_data = true
    level                  = "ALL"
  }
  tags = var.tags
}


resource "aws_cloudwatch_log_group" "step_functions" {
  name              = "/aws/vendedlogs/states/${var.project_name}-workflow"
  retention_in_days = 7
  
  tags = var.tags
}
################################################################################
# Layer 5: Frontend Authentication & Access Control (Cognito)
################################################################################

# 1. The User Database (Username & Password) - Created in External Account
resource "aws_cognito_user_pool" "app_users" {
  provider = aws.identity_account  # <--- Uses the KEP_APP_SS profile
  
  name = "${var.project_name}-user-pool"

  password_policy {
    minimum_length    = 8
    require_lowercase = true
    require_numbers   = true
    require_symbols   = false
    require_uppercase = true
  }

  auto_verified_attributes = ["email"]
  tags = var.tags
}

# 2. The App Client (Connects React to Cognito) - Created in External Account
resource "aws_cognito_user_pool_client" "web_client" {
  provider = aws.identity_account  # <--- Uses the KEP_APP_SS profile
  
  name = "${var.project_name}-web-client"
  user_pool_id = aws_cognito_user_pool.app_users.id
  
  generate_secret = false # Web apps cannot keep secrets safe
  explicit_auth_flows = [
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH"
  ]
}

# 3. Identity Pool (Exchanges Login for AWS Permissions) - Created in Compliance Account
resource "aws_cognito_identity_pool" "main" {
  identity_pool_name               = replace("${var.project_name} identity pool", "-", " ")
  allow_unauthenticated_identities = false

  cognito_identity_providers {
    client_id               = aws_cognito_user_pool_client.web_client.id
    provider_name           = aws_cognito_user_pool.app_users.endpoint
    server_side_token_check = false
  }
}

# 4. IAM Role for Authenticated Users (Permissions for React App)
resource "aws_iam_role" "authenticated_user" {
  name = "${var.project_name}-authenticated-user-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Federated = "cognito-identity.amazonaws.com" }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        "StringEquals" = {
          "cognito-identity.amazonaws.com:aud" = aws_cognito_identity_pool.main.id
        }
        "ForAnyValue:StringLike" = {
          "cognito-identity.amazonaws.com:amr" = "authenticated"
        }
      }
    }]
  })
}

# 5. Attach Permissions to the Role
resource "aws_iam_role_policy" "frontend_permissions" {
  name = "${var.project_name}-frontend-policy"
  role = aws_iam_role.authenticated_user.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Allow listing/reading policy files
      {
        Effect = "Allow"
        Action = ["s3:ListBucket", "s3:GetObject"]
        Resource = [
          aws_s3_bucket.compliance_data.arn,
          "${aws_s3_bucket.compliance_data.arn}/*"
        ]
      },
      # Allow analyzing the policy (Calling the Fetcher Lambda)
      {
        Effect = "Allow"
        Action = ["lambda:InvokeFunction"]
        Resource = [aws_lambda_function.policy_section_fetcher.arn]
      },
      # Allow starting the Audit Workflow
      {
        Effect = "Allow"
        Action = ["states:StartExecution", "states:DescribeExecution", "states:GetExecutionHistory"]
        Resource = [
          aws_sfn_state_machine.compliance_workflow.arn,
          "arn:aws:states:${var.aws_region}:${data.aws_caller_identity.current.account_id}:execution:${aws_sfn_state_machine.compliance_workflow.name}:*"
        ]
      },
      # Allow reading/writing audit history (scoped to user's own records)
      {
        Effect = "Allow"
        Action = ["dynamodb:PutItem", "dynamodb:Query"]
        Resource = aws_dynamodb_table.audit_history.arn
      }
    ]
  })
}

resource "aws_cognito_identity_pool_roles_attachment" "main" {
  identity_pool_id = aws_cognito_identity_pool.main.id
  roles = {
    authenticated = aws_iam_role.authenticated_user.arn
  }
}
