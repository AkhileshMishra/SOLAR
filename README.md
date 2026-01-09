# AI-Driven Compliance Reporting System (SOLAR)

An end-to-end AI-powered compliance reporting solution built on AWS. The system ingests logs and policy documents, uses Generative AI to analyze compliance, and generates formatted Microsoft Word reports.

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Prerequisites](#prerequisites)
- [AWS Account Setup](#aws-account-setup)
- [Deployment](#deployment)
- [Usage](#usage)
- [Troubleshooting](#troubleshooting)

---

## Architecture Overview

The system consists of four layers:

1. **Storage & Data Layer** - S3 bucket, AWS Glue catalog, Amazon Athena
2. **Auto-DDL Ingestion Layer** - Lambda function that auto-generates Athena views using Bedrock
3. **AI Reasoning Core** - Bedrock Agent with Knowledge Base for RAG-based policy analysis
4. **Orchestration & Reporting** - Step Functions workflow with parallel processing and DOCX report generation

**Frontend**: React SPA hosted on CloudFront + S3, authenticated via Cognito

---

## Prerequisites

### Local Development Tools

| Tool | Version | Purpose |
|------|---------|---------|
| [Terraform](https://terraform.io/downloads) | >= 1.5.0 | Infrastructure as Code |
| [AWS CLI](https://aws.amazon.com/cli/) | v2 | AWS resource management |
| [Node.js](https://nodejs.org/) | 18.x | Frontend build |
| [Python](https://python.org/) | 3.11 | Lambda layers |
| Git | Latest | Version control |

### AWS Requirements

- **Two AWS Accounts** (or single account with modifications):
  - **Compliance Account** (`430118833069`): Main infrastructure
  - **Identity Account** (`304838292196`): Cognito User Pool (shared services)

- **Bedrock Model Access**: Enable access to `Claude Sonnet 4` in the `ap-southeast-1` region via AWS Console → Bedrock → Model access

- **Existing Knowledge Base**: The solution references Knowledge Base ID `BL63WWBBCS` - update this in `main.tf` if using a different one

---

## AWS Account Setup

### Step 1: Create GitHub OIDC Identity Provider

In the **Compliance Account** (`430118833069`), create the OIDC provider for GitHub Actions:

```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
```

### Step 2: Create GitHub Actions Deployment Role

Create the role that GitHub Actions will assume:

```bash
# Create trust policy
cat > github-trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::430118833069:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:KeppelLtd/SOLAR:*"
        }
      }
    }
  ]
}
EOF

# Create the role
aws iam create-role \
  --role-name GitHubActions-SOLAR-Deploy \
  --assume-role-policy-document file://github-trust-policy.json
```

### Step 3: Attach Permissions to GitHub Actions Role

The role needs permissions for Terraform state management and to assume the deployment role:

```bash
cat > github-permissions.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "TerraformStateBackend",
      "Effect": "Allow",
      "Action": [
        "s3:CreateBucket",
        "s3:ListBucket",
        "s3:GetBucketLocation",
        "s3:GetBucketVersioning",
        "s3:PutBucketVersioning",
        "s3:GetEncryptionConfiguration",
        "s3:PutEncryptionConfiguration",
        "s3:GetBucketPublicAccessBlock",
        "s3:PutBucketPublicAccessBlock",
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject"
      ],
      "Resource": [
        "arn:aws:s3:::solar-terraform-state-*",
        "arn:aws:s3:::solar-terraform-state-*/*"
      ]
    },
    {
      "Sid": "DynamoDBStateLocking",
      "Effect": "Allow",
      "Action": [
        "dynamodb:CreateTable",
        "dynamodb:DescribeTable",
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:DeleteItem",
        "dynamodb:DescribeContinuousBackups",
        "dynamodb:DescribeTimeToLive",
        "dynamodb:ListTagsOfResource"
      ],
      "Resource": "arn:aws:dynamodb:ap-southeast-1:430118833069:table/solar-terraform-lock"
    },
    {
      "Sid": "AssumeDeploymentRole",
      "Effect": "Allow",
      "Action": "sts:AssumeRole",
      "Resource": [
        "arn:aws:iam::430118833069:role/KAIZERODeploymentServer",
        "arn:aws:iam::304838292196:role/CrossAccountCognitoRole"
      ]
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name GitHubActions-SOLAR-Deploy \
  --policy-name GitHubActionsPermissions \
  --policy-document file://github-permissions.json
```

### Step 4: Create KAIZERODeploymentServer Role

This role is assumed by Terraform to deploy all infrastructure:

```bash
# Trust policy
cat > kaizero-trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::430118833069:role/GitHubActions-SOLAR-Deploy"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

aws iam create-role \
  --role-name KAIZERODeploymentServer \
  --assume-role-policy-document file://kaizero-trust-policy.json
```

Attach the full deployment policy (see `docs/github-actions-iam-policy.json` for complete policy):

```bash
aws iam put-role-policy \
  --role-name KAIZERODeploymentServer \
  --policy-name SOLARDeploymentPolicy \
  --policy-document file://docs/github-actions-iam-policy.json
```

**Important**: Add Bedrock permissions separately:

```bash
aws iam put-role-policy \
  --role-name KAIZERODeploymentServer \
  --policy-name BedrockDeploymentAccess \
  --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"bedrock:*","Resource":"*"}]}'
```

### Step 5: Create CrossAccountCognitoRole (Identity Account)

In the **Identity Account** (`304838292196`):

```bash
# Trust policy
cat > cognito-trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": [
          "arn:aws:iam::430118833069:role/GitHubActions-SOLAR-Deploy",
          "arn:aws:iam::430118833069:role/KAIZERODeploymentServer"
        ]
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

aws iam create-role \
  --role-name CrossAccountCognitoRole \
  --assume-role-policy-document file://cognito-trust-policy.json

# Permissions policy
cat > cognito-permissions.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "cognito-idp:CreateUserPool",
        "cognito-idp:DeleteUserPool",
        "cognito-idp:DescribeUserPool",
        "cognito-idp:UpdateUserPool",
        "cognito-idp:CreateUserPoolClient",
        "cognito-idp:DeleteUserPoolClient",
        "cognito-idp:DescribeUserPoolClient",
        "cognito-idp:UpdateUserPoolClient",
        "cognito-idp:ListUserPoolClients",
        "cognito-idp:AdminCreateUser",
        "cognito-idp:AdminDeleteUser",
        "cognito-idp:AdminGetUser",
        "cognito-idp:AdminSetUserPassword",
        "cognito-idp:ListUsers",
        "cognito-idp:TagResource",
        "cognito-idp:UntagResource",
        "cognito-idp:ListTagsForResource"
      ],
      "Resource": "*"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name CrossAccountCognitoRole \
  --policy-name CognitoManagementPolicy \
  --policy-document file://cognito-permissions.json
```

### Step 6: Configure GitHub Repository Secret

In your GitHub repository, add the secret:

| Secret Name | Value |
|-------------|-------|
| `AWS_ROLE_ARN` | `arn:aws:iam::430118833069:role/GitHubActions-SOLAR-Deploy` |

Go to: Repository → Settings → Secrets and variables → Actions → New repository secret

---

## Deployment

### Automatic Deployment (CI/CD)

Push to the `main` branch triggers automatic deployment via GitHub Actions:

```bash
git add .
git commit -m "Deploy changes"
git push origin main
```

Monitor the workflow: Repository → Actions tab

### Manual Deployment

```bash
# 1. Build Lambda layers
chmod +x scripts/build_layers.sh
./scripts/build_layers.sh

# 2. Build frontend
cd frontend
npm install
npm run build
cd ..

# 3. Initialize Terraform
terraform init \
  -backend-config="bucket=solar-terraform-state-430118833069" \
  -backend-config="dynamodb_table=solar-terraform-lock" \
  -backend-config="region=ap-southeast-1"

# 4. Deploy
terraform apply
```

---

## Usage

### 1. Upload Policy Document

```bash
BUCKET=$(terraform output -raw s3_bucket_name)
aws s3 cp your-policy.pdf s3://${BUCKET}/inputs/policy/
```

### 2. Sync Knowledge Base

```bash
aws bedrock-agent start-ingestion-job \
  --knowledge-base-id BL63WWBBCS \
  --data-source-id <your-data-source-id>
```

### 3. Upload Log Files

```bash
aws s3 cp logs.csv s3://${BUCKET}/inputs/logs/
```

This triggers automatic schema detection and Athena view creation.

### 4. Run Compliance Workflow

```bash
STATE_MACHINE=$(terraform output -raw step_functions_arn)
aws stepfunctions start-execution --state-machine-arn $STATE_MACHINE --input '{}'
```

### 5. Access Frontend

After deployment, access the frontend at:
```
https://<cloudfront-distribution-id>.cloudfront.net
```

Get the URL from Terraform output:
```bash
terraform output cloudfront_url
```

### 6. Create Users

Create users in Cognito User Pool (Identity Account):
```bash
aws cognito-idp admin-create-user \
  --user-pool-id <user-pool-id> \
  --username user@example.com \
  --user-attributes Name=email,Value=user@example.com \
  --temporary-password "TempPass123!"
```

---

## Troubleshooting

### Common Deployment Errors

| Error | Cause | Solution |
|-------|-------|----------|
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | OIDC trust policy misconfigured | Update trust policy with correct repo name |
| `AccessDenied on s3:PutEncryptionConfiguration` | Missing S3 permissions | Add S3 permissions to deployment role |
| `AccessDeniedException: Access denied while trying to create/update an agent using InferenceProfile` | Missing Bedrock permissions | Run: `aws iam put-role-policy --role-name KAIZERODeploymentServer --policy-name BedrockDeploymentAccess --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"bedrock:*","Resource":"*"}]}'` |
| `npm ci` lock file mismatch | Node.js version mismatch | Workflow uses `npm install` instead of `npm ci` |

### Verify Role Permissions

```bash
# Test GitHub Actions role can assume deployment role
aws sts assume-role \
  --role-arn arn:aws:iam::430118833069:role/KAIZERODeploymentServer \
  --role-session-name test
```

### Check Workflow Logs

1. Go to GitHub → Actions tab
2. Click on the failed workflow run
3. Expand the failed step to see detailed logs

---

## File Structure

```
.
├── .github/workflows/
│   └── deploy.yml              # CI/CD pipeline
├── docs/
│   ├── aws-oidc-setup.md       # OIDC setup guide
│   ├── cross-account-role-setup.md  # IAM role setup
│   └── github-actions-iam-policy.json  # Full IAM policy
├── frontend/
│   ├── src/                    # React application
│   └── package.json
├── layers/                     # Lambda layer requirements
├── scripts/
│   └── build_layers.sh         # Layer build script
├── src/
│   ├── agent_athena_executor/  # Bedrock Agent action group
│   ├── ingestion_agent/        # Auto-DDL Lambda
│   ├── policy_section_fetcher/ # Policy parser
│   └── report_generator/       # DOCX generator
├── main.tf                     # Main Terraform config
├── frontend_hosting.tf         # CloudFront + S3
├── variables.tf                # Input variables
├── outputs.tf                  # Output values
└── README.md
```

---

## Resources Created

| Service | Resource | Purpose |
|---------|----------|---------|
| S3 | `compliance-reporting-bucket-*` | Data lake |
| S3 | `compliance-reporting-frontend-*` | Frontend hosting |
| CloudFront | Distribution | CDN for frontend |
| Cognito | User Pool + Identity Pool | Authentication |
| Lambda | 5 functions | Business logic |
| Bedrock | Agent + Knowledge Base | AI reasoning |
| Step Functions | State machine | Workflow orchestration |
| Glue | Database + Crawler | Data catalog |
| Athena | Workgroup | SQL queries |

---

## License

Proprietary - Keppel Ltd.
