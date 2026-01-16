#!/bin/bash
# =============================================================================
# SOLAR Project - Complete Resource Cleanup Script
# =============================================================================
# This script deletes ALL SOLAR resources from AWS and clears Terraform state
# Run this ONCE before redeploying to get a clean slate
#
# Usage: bash cleanup_all_solar_resources.sh
# =============================================================================

set -e

REGION="ap-southeast-1"
PROJECT_NAME="compliance-reporting"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
STATE_BUCKET="solar-terraform-state-${ACCOUNT_ID}"

echo "=============================================="
echo "SOLAR Complete Resource Cleanup Script"
echo "=============================================="
echo "Region: $REGION"
echo "Account: $ACCOUNT_ID"
echo "State Bucket: $STATE_BUCKET"
echo ""
echo "WARNING: This will delete ALL SOLAR resources!"
echo "Press Ctrl+C within 10 seconds to cancel..."
sleep 10
echo ""

# -----------------------------------------------------------------------------
# 1. Delete Bedrock Agent Knowledge Base Association
# -----------------------------------------------------------------------------
echo "1. Deleting Bedrock Agent KB Association..."
AGENT_ID=$(aws bedrock-agent list-agents --region $REGION --query "agentSummaries[?agentName=='ComplianceAuditorAgent'].agentId" --output text 2>/dev/null || echo "")
if [ -n "$AGENT_ID" ] && [ "$AGENT_ID" != "None" ]; then
    echo "   Found Agent: $AGENT_ID"
    # List all KB associations for this agent
    KB_IDS=$(aws bedrock-agent list-agent-knowledge-bases --agent-id $AGENT_ID --agent-version DRAFT --region $REGION --query "agentKnowledgeBaseSummaries[*].knowledgeBaseId" --output text 2>/dev/null || echo "")
    for KB_ID in $KB_IDS; do
        if [ -n "$KB_ID" ] && [ "$KB_ID" != "None" ]; then
            echo "   Disassociating KB: $KB_ID"
            aws bedrock-agent disassociate-agent-knowledge-base --agent-id $AGENT_ID --agent-version DRAFT --knowledge-base-id $KB_ID --region $REGION 2>/dev/null || echo "   Already disassociated"
        fi
    done
else
    echo "   No agent found"
fi

# -----------------------------------------------------------------------------
# 2. Delete Bedrock Agent Alias
# -----------------------------------------------------------------------------
echo "2. Deleting Bedrock Agent Aliases..."
if [ -n "$AGENT_ID" ] && [ "$AGENT_ID" != "None" ]; then
    ALIAS_IDS=$(aws bedrock-agent list-agent-aliases --agent-id $AGENT_ID --region $REGION --query "agentAliasSummaries[*].agentAliasId" --output text 2>/dev/null || echo "")
    for ALIAS_ID in $ALIAS_IDS; do
        if [ -n "$ALIAS_ID" ] && [ "$ALIAS_ID" != "None" ] && [ "$ALIAS_ID" != "TSTALIASID" ]; then
            echo "   Deleting alias: $ALIAS_ID"
            aws bedrock-agent delete-agent-alias --agent-id $AGENT_ID --agent-alias-id $ALIAS_ID --region $REGION 2>/dev/null || echo "   Already deleted"
        fi
    done
fi

# -----------------------------------------------------------------------------
# 3. Delete Bedrock Agent Action Groups
# -----------------------------------------------------------------------------
echo "3. Deleting Bedrock Agent Action Groups..."
if [ -n "$AGENT_ID" ] && [ "$AGENT_ID" != "None" ]; then
    ACTION_GROUPS=$(aws bedrock-agent list-agent-action-groups --agent-id $AGENT_ID --agent-version DRAFT --region $REGION --query "actionGroupSummaries[*].actionGroupId" --output text 2>/dev/null || echo "")
    for AG_ID in $ACTION_GROUPS; do
        if [ -n "$AG_ID" ] && [ "$AG_ID" != "None" ]; then
            echo "   Deleting action group: $AG_ID"
            aws bedrock-agent delete-agent-action-group --agent-id $AGENT_ID --agent-version DRAFT --action-group-id $AG_ID --region $REGION 2>/dev/null || echo "   Already deleted"
        fi
    done
fi

# -----------------------------------------------------------------------------
# 4. Delete Bedrock Agent
# -----------------------------------------------------------------------------
echo "4. Deleting Bedrock Agent..."
if [ -n "$AGENT_ID" ] && [ "$AGENT_ID" != "None" ]; then
    echo "   Deleting agent: $AGENT_ID"
    aws bedrock-agent delete-agent --agent-id $AGENT_ID --region $REGION 2>/dev/null || echo "   Already deleted"
    echo "   Waiting for agent deletion..."
    sleep 10
else
    echo "   No agent to delete"
fi

# -----------------------------------------------------------------------------
# 5. Delete Bedrock Data Sources
# -----------------------------------------------------------------------------
echo "5. Deleting Bedrock Data Sources..."
KB_IDS=$(aws bedrock-agent list-knowledge-bases --region $REGION --query "knowledgeBaseSummaries[?contains(name, 'Compliance') || contains(name, 'compliance')].knowledgeBaseId" --output text 2>/dev/null || echo "")
for KB_ID in $KB_IDS; do
    if [ -n "$KB_ID" ] && [ "$KB_ID" != "None" ]; then
        echo "   Found KB: $KB_ID"
        DS_IDS=$(aws bedrock-agent list-data-sources --knowledge-base-id $KB_ID --region $REGION --query "dataSourceSummaries[*].dataSourceId" --output text 2>/dev/null || echo "")
        for DS_ID in $DS_IDS; do
            if [ -n "$DS_ID" ] && [ "$DS_ID" != "None" ]; then
                echo "   Deleting data source: $DS_ID"
                aws bedrock-agent delete-data-source --knowledge-base-id $KB_ID --data-source-id $DS_ID --region $REGION 2>/dev/null || echo "   Already deleted"
            fi
        done
    fi
done

# -----------------------------------------------------------------------------
# 6. Delete Bedrock Knowledge Bases
# -----------------------------------------------------------------------------
echo "6. Deleting Bedrock Knowledge Bases..."
for KB_ID in $KB_IDS; do
    if [ -n "$KB_ID" ] && [ "$KB_ID" != "None" ]; then
        echo "   Deleting knowledge base: $KB_ID"
        aws bedrock-agent delete-knowledge-base --knowledge-base-id $KB_ID --region $REGION 2>/dev/null || echo "   Already deleted"
    fi
done
echo "   Waiting for KB deletion..."
sleep 10

# -----------------------------------------------------------------------------
# 7. Delete OpenSearch Serverless Collections
# -----------------------------------------------------------------------------
echo "7. Deleting OpenSearch Serverless Collections..."
COLLECTION_IDS=$(aws opensearchserverless list-collections --region $REGION --query "collectionSummaries[?contains(name, 'compliance')].id" --output text 2>/dev/null || echo "")
for COLL_ID in $COLLECTION_IDS; do
    if [ -n "$COLL_ID" ] && [ "$COLL_ID" != "None" ]; then
        echo "   Deleting collection: $COLL_ID"
        aws opensearchserverless delete-collection --id $COLL_ID --region $REGION 2>/dev/null || echo "   Already deleted"
    fi
done

# -----------------------------------------------------------------------------
# 8. Delete OpenSearch Security Policies
# -----------------------------------------------------------------------------
echo "8. Deleting OpenSearch Security Policies..."
# Encryption policies
for POLICY_NAME in "${PROJECT_NAME}-enc-15jan" "${PROJECT_NAME}-encryption" "solar-enc-policy" "compliance-enc"; do
    aws opensearchserverless delete-security-policy --name "$POLICY_NAME" --type encryption --region $REGION 2>/dev/null && echo "   Deleted encryption policy: $POLICY_NAME" || true
done

# Network policies
for POLICY_NAME in "${PROJECT_NAME}-net-15jan" "${PROJECT_NAME}-network" "solar-net-policy" "compliance-net"; do
    aws opensearchserverless delete-security-policy --name "$POLICY_NAME" --type network --region $REGION 2>/dev/null && echo "   Deleted network policy: $POLICY_NAME" || true
done

# -----------------------------------------------------------------------------
# 9. Delete OpenSearch Access Policies
# -----------------------------------------------------------------------------
echo "9. Deleting OpenSearch Access Policies..."
for POLICY_NAME in "${PROJECT_NAME}-data-15jan" "${PROJECT_NAME}-data" "solar-data-policy" "compliance-data"; do
    aws opensearchserverless delete-access-policy --name "$POLICY_NAME" --type data --region $REGION 2>/dev/null && echo "   Deleted access policy: $POLICY_NAME" || true
done

# -----------------------------------------------------------------------------
# 10. Wait for OpenSearch collection deletion
# -----------------------------------------------------------------------------
echo "10. Waiting for OpenSearch collections to be deleted (up to 2 minutes)..."
for i in {1..24}; do
    REMAINING=$(aws opensearchserverless list-collections --region $REGION --query "collectionSummaries[?contains(name, 'compliance')].id" --output text 2>/dev/null || echo "")
    if [ -z "$REMAINING" ] || [ "$REMAINING" == "None" ]; then
        echo "    All collections deleted"
        break
    fi
    echo "    Still waiting... ($i/24)"
    sleep 5
done

# -----------------------------------------------------------------------------
# 11. Delete Step Functions State Machine
# -----------------------------------------------------------------------------
echo "11. Deleting Step Functions State Machine..."
SFN_ARN="arn:aws:states:${REGION}:${ACCOUNT_ID}:stateMachine:${PROJECT_NAME}-workflow"
aws stepfunctions delete-state-machine --state-machine-arn "$SFN_ARN" --region $REGION 2>/dev/null && echo "   Deleted state machine" || echo "   State machine not found"

# -----------------------------------------------------------------------------
# 12. Delete Lambda Functions
# -----------------------------------------------------------------------------
echo "12. Deleting Lambda Functions..."
LAMBDA_FUNCTIONS=(
    "${PROJECT_NAME}-log-ingestion-agent"
    "${PROJECT_NAME}-agent-athena-executor"
    "${PROJECT_NAME}-policy-section-fetcher"
    "${PROJECT_NAME}-report-generator"
    "${PROJECT_NAME}-agent-invoker"
)
for FUNC in "${LAMBDA_FUNCTIONS[@]}"; do
    aws lambda delete-function --function-name "$FUNC" --region $REGION 2>/dev/null && echo "   Deleted: $FUNC" || echo "   Not found: $FUNC"
done

# -----------------------------------------------------------------------------
# 13. Delete Lambda Layers
# -----------------------------------------------------------------------------
echo "13. Deleting Lambda Layers..."
LAYER_NAMES=("${PROJECT_NAME}-pandas-layer" "${PROJECT_NAME}-pypdf-layer")
for LAYER in "${LAYER_NAMES[@]}"; do
    VERSIONS=$(aws lambda list-layer-versions --layer-name "$LAYER" --region $REGION --query "LayerVersions[*].Version" --output text 2>/dev/null || echo "")
    for VERSION in $VERSIONS; do
        if [ -n "$VERSION" ] && [ "$VERSION" != "None" ]; then
            aws lambda delete-layer-version --layer-name "$LAYER" --version-number "$VERSION" --region $REGION 2>/dev/null && echo "   Deleted: $LAYER:$VERSION" || true
        fi
    done
done

# -----------------------------------------------------------------------------
# 14. Delete CloudWatch Log Groups
# -----------------------------------------------------------------------------
echo "14. Deleting CloudWatch Log Groups..."
LOG_GROUPS=$(aws logs describe-log-groups --log-group-name-prefix "/aws/lambda/${PROJECT_NAME}" --region $REGION --query "logGroups[*].logGroupName" --output text 2>/dev/null || echo "")
for LG in $LOG_GROUPS; do
    if [ -n "$LG" ] && [ "$LG" != "None" ]; then
        aws logs delete-log-group --log-group-name "$LG" --region $REGION 2>/dev/null && echo "   Deleted: $LG" || true
    fi
done
aws logs delete-log-group --log-group-name "/aws/vendedlogs/states/${PROJECT_NAME}-workflow" --region $REGION 2>/dev/null && echo "   Deleted step functions log group" || true

# -----------------------------------------------------------------------------
# 15. Delete Glue Resources
# -----------------------------------------------------------------------------
echo "15. Deleting Glue Resources..."
aws glue delete-crawler --name "${PROJECT_NAME}-log-crawler" --region $REGION 2>/dev/null && echo "   Deleted crawler" || echo "   Crawler not found"
# Delete tables in database
TABLES=$(aws glue get-tables --database-name "compliance_db" --region $REGION --query "TableList[*].Name" --output text 2>/dev/null || echo "")
for TABLE in $TABLES; do
    if [ -n "$TABLE" ] && [ "$TABLE" != "None" ]; then
        aws glue delete-table --database-name "compliance_db" --name "$TABLE" --region $REGION 2>/dev/null && echo "   Deleted table: $TABLE" || true
    fi
done
aws glue delete-database --name "compliance_db" --region $REGION 2>/dev/null && echo "   Deleted database" || echo "   Database not found"

# -----------------------------------------------------------------------------
# 16. Delete Athena Workgroup
# -----------------------------------------------------------------------------
echo "16. Deleting Athena Workgroup..."
aws athena delete-work-group --work-group "compliance_auditor" --recursive-delete-option --region $REGION 2>/dev/null && echo "   Deleted workgroup" || echo "   Workgroup not found"

# -----------------------------------------------------------------------------
# 17. Delete CloudFront Distribution
# -----------------------------------------------------------------------------
echo "17. Checking CloudFront Distribution..."
CF_DIST_ID=$(aws cloudfront list-distributions --query "DistributionList.Items[?Comment=='${PROJECT_NAME} Frontend Distribution'].Id" --output text 2>/dev/null || echo "")
if [ -n "$CF_DIST_ID" ] && [ "$CF_DIST_ID" != "None" ]; then
    echo "   Found distribution: $CF_DIST_ID"
    echo "   CloudFront distributions require manual deletion:"
    echo "   1. Go to AWS Console > CloudFront"
    echo "   2. Select distribution $CF_DIST_ID"
    echo "   3. Disable it, wait for deployment"
    echo "   4. Delete it"
else
    echo "   No distribution found"
fi

# -----------------------------------------------------------------------------
# 18. Empty and Delete S3 Buckets
# -----------------------------------------------------------------------------
echo "18. Emptying and Deleting S3 Buckets..."
S3_BUCKETS=(
    "${PROJECT_NAME}-bucket-sg-${ACCOUNT_ID}"
    "${PROJECT_NAME}-frontend-${ACCOUNT_ID}"
)
for BUCKET in "${S3_BUCKETS[@]}"; do
    if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
        echo "   Emptying bucket: $BUCKET"
        aws s3 rm "s3://${BUCKET}" --recursive 2>/dev/null || true
        # Delete all versions if versioning is enabled
        aws s3api list-object-versions --bucket "$BUCKET" --query "Versions[*].{Key:Key,VersionId:VersionId}" --output text 2>/dev/null | while read KEY VERSION; do
            if [ -n "$KEY" ] && [ -n "$VERSION" ]; then
                aws s3api delete-object --bucket "$BUCKET" --key "$KEY" --version-id "$VERSION" 2>/dev/null || true
            fi
        done
        aws s3api list-object-versions --bucket "$BUCKET" --query "DeleteMarkers[*].{Key:Key,VersionId:VersionId}" --output text 2>/dev/null | while read KEY VERSION; do
            if [ -n "$KEY" ] && [ -n "$VERSION" ]; then
                aws s3api delete-object --bucket "$BUCKET" --key "$KEY" --version-id "$VERSION" 2>/dev/null || true
            fi
        done
        aws s3 rb "s3://${BUCKET}" --force 2>/dev/null && echo "   Deleted bucket: $BUCKET" || echo "   Could not delete bucket: $BUCKET"
    else
        echo "   Bucket not found: $BUCKET"
    fi
done

# -----------------------------------------------------------------------------
# 19. Delete IAM Roles (created by Terraform)
# -----------------------------------------------------------------------------
echo "19. Deleting IAM Roles..."
IAM_ROLES=(
    "${PROJECT_NAME}-log-ingestion-agent-role"
    "${PROJECT_NAME}-bedrock-kb-role"
    "${PROJECT_NAME}-bedrock-agent-role"
    "${PROJECT_NAME}-agent-athena-executor-role"
    "${PROJECT_NAME}-policy-section-fetcher-role"
    "${PROJECT_NAME}-report-generator-role"
    "${PROJECT_NAME}-step-functions-role"
    "${PROJECT_NAME}-agent-invoker-role"
    "${PROJECT_NAME}-authenticated-user-role"
)
for ROLE in "${IAM_ROLES[@]}"; do
    # Delete inline policies first
    POLICIES=$(aws iam list-role-policies --role-name "$ROLE" --query "PolicyNames" --output text 2>/dev/null || echo "")
    for POLICY in $POLICIES; do
        if [ -n "$POLICY" ] && [ "$POLICY" != "None" ]; then
            aws iam delete-role-policy --role-name "$ROLE" --policy-name "$POLICY" 2>/dev/null || true
        fi
    done
    # Detach managed policies
    ATTACHED=$(aws iam list-attached-role-policies --role-name "$ROLE" --query "AttachedPolicies[*].PolicyArn" --output text 2>/dev/null || echo "")
    for POLICY_ARN in $ATTACHED; do
        if [ -n "$POLICY_ARN" ] && [ "$POLICY_ARN" != "None" ]; then
            aws iam detach-role-policy --role-name "$ROLE" --policy-arn "$POLICY_ARN" 2>/dev/null || true
        fi
    done
    # Delete the role
    aws iam delete-role --role-name "$ROLE" 2>/dev/null && echo "   Deleted: $ROLE" || echo "   Not found: $ROLE"
done

# -----------------------------------------------------------------------------
# 20. Delete Cognito Resources (in identity account - may need separate credentials)
# -----------------------------------------------------------------------------
echo "20. Cognito resources are in a different account (304838292196)"
echo "    You may need to delete these manually or with cross-account credentials:"
echo "    - User Pool: ${PROJECT_NAME}-user-pool"
echo "    - Identity Pool: ${PROJECT_NAME} identity pool"

# -----------------------------------------------------------------------------
# 21. Clear Terraform State in S3
# -----------------------------------------------------------------------------
echo "21. Clearing Terraform State..."
if aws s3api head-bucket --bucket "$STATE_BUCKET" 2>/dev/null; then
    echo "   Deleting terraform.tfstate from $STATE_BUCKET"
    aws s3 rm "s3://${STATE_BUCKET}/terraform.tfstate" 2>/dev/null || echo "   State file not found"
    # Delete all versions of the state file
    aws s3api list-object-versions --bucket "$STATE_BUCKET" --prefix "terraform.tfstate" --query "Versions[*].{Key:Key,VersionId:VersionId}" --output text 2>/dev/null | while read KEY VERSION; do
        if [ -n "$KEY" ] && [ -n "$VERSION" ]; then
            aws s3api delete-object --bucket "$STATE_BUCKET" --key "$KEY" --version-id "$VERSION" 2>/dev/null || true
        fi
    done
    aws s3api list-object-versions --bucket "$STATE_BUCKET" --prefix "terraform.tfstate" --query "DeleteMarkers[*].{Key:Key,VersionId:VersionId}" --output text 2>/dev/null | while read KEY VERSION; do
        if [ -n "$KEY" ] && [ -n "$VERSION" ]; then
            aws s3api delete-object --bucket "$STATE_BUCKET" --key "$KEY" --version-id "$VERSION" 2>/dev/null || true
        fi
    done
    echo "   Terraform state cleared"
else
    echo "   State bucket not found (will be created on next deploy)"
fi

# -----------------------------------------------------------------------------
# 22. Clear DynamoDB Lock Table
# -----------------------------------------------------------------------------
echo "22. Clearing DynamoDB Lock Table..."
aws dynamodb delete-item --table-name "solar-terraform-lock" --key '{"LockID": {"S": "solar-terraform-state-'${ACCOUNT_ID}'/terraform.tfstate"}}' --region $REGION 2>/dev/null && echo "   Lock cleared" || echo "   No lock to clear"

echo ""
echo "=============================================="
echo "CLEANUP COMPLETE!"
echo "=============================================="
echo ""
echo "Next steps:"
echo "1. Wait 2-3 minutes for all deletions to propagate"
echo "2. If CloudFront distribution was found, delete it manually from AWS Console"
echo "3. Trigger a new deployment from GitHub Actions"
echo ""
echo "The Terraform state has been cleared, so the next deployment"
echo "will create all resources fresh and track them properly."
echo "=============================================="
