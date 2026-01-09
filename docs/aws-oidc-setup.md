# AWS OIDC Setup for GitHub Actions

This guide sets up GitHub Actions OIDC authentication for the SOLAR project.

## Account Information
- **KAIZERO (Application)**: `430118833069`
- **KEP_APP_SS (Shared Services)**: `304838292196`

---

## Step 1: Create Cross-Account Role in KEP_APP_SS (Shared Services)

Run these commands while authenticated to the **KEP_APP_SS account (304838292196)**:

```bash
# 1. Create trust policy allowing KAIZERO account to assume this role
cat > cross-account-trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::430118833069:root"
      },
      "Action": "sts:AssumeRole",
      "Condition": {}
    }
  ]
}
EOF

# 2. Create the cross-account role
aws iam create-role \
  --role-name CrossAccountCognitoRole \
  --assume-role-policy-document file://cross-account-trust-policy.json \
  --description "Allows KAIZERO account to manage Cognito resources"

# 3. Create permissions policy for Cognito management
cat > cognito-permissions.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "CognitoFullAccess",
      "Effect": "Allow",
      "Action": [
        "cognito-idp:*",
        "cognito-identity:*"
      ],
      "Resource": "*"
    }
  ]
}
EOF

# 4. Attach the permissions policy
aws iam put-role-policy \
  --role-name CrossAccountCognitoRole \
  --policy-name CognitoManagementPermissions \
  --policy-document file://cognito-permissions.json

# 5. Verify the role
aws iam get-role --role-name CrossAccountCognitoRole --query 'Role.Arn' --output text

# 6. Cleanup temp files
rm cross-account-trust-policy.json cognito-permissions.json
```

---

## Step 2: Create OIDC Provider and Role in KAIZERO (Application)

Run these commands while authenticated to the **KAIZERO account (430118833069)**:

```bash
# 1. Create the OIDC Identity Provider for GitHub (skip if already exists)
aws iam create-open-id-connect-provider \
  --url "https://token.actions.githubusercontent.com" \
  --client-id-list "sts.amazonaws.com" \
  --thumbprint-list "6938fd4d98bab03faadb97b34396831e3780aea1" "1c58a3a8518e8759bf075b76b750d4f2df264fcd"

# 2. Create the trust policy for GitHub Actions
cat > github-oidc-trust-policy.json << 'EOF'
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
          "token.actions.githubusercontent.com:sub": "repo:AkhileshMishra/SOLAR:*"
        }
      }
    }
  ]
}
EOF

# 3. Create the IAM Role for GitHub Actions
aws iam create-role \
  --role-name GitHubActions-SOLAR-Deploy \
  --assume-role-policy-document file://github-oidc-trust-policy.json \
  --description "Role for GitHub Actions to deploy SOLAR infrastructure"

# 4. Create the permissions policy
cat > github-actions-permissions.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "TerraformStateManagement",
      "Effect": "Allow",
      "Action": [
        "s3:CreateBucket",
        "s3:PutBucketVersioning",
        "s3:PutBucketEncryption",
        "s3:PutBucketPublicAccessBlock",
        "s3:GetBucketLocation",
        "s3:ListBucket",
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
        "dynamodb:DeleteItem"
      ],
      "Resource": "arn:aws:dynamodb:ap-southeast-1:430118833069:table/solar-terraform-lock"
    },
    {
      "Sid": "S3HeadBucket",
      "Effect": "Allow",
      "Action": "s3:ListAllMyBuckets",
      "Resource": "*"
    },
    {
      "Sid": "AssumeKAIZERODeploymentRole",
      "Effect": "Allow",
      "Action": "sts:AssumeRole",
      "Resource": "arn:aws:iam::430118833069:role/KAIZERODeploymentServer"
    },
    {
      "Sid": "AssumeCrossAccountCognitoRole",
      "Effect": "Allow",
      "Action": "sts:AssumeRole",
      "Resource": "arn:aws:iam::304838292196:role/CrossAccountCognitoRole"
    },
    {
      "Sid": "GetCallerIdentity",
      "Effect": "Allow",
      "Action": "sts:GetCallerIdentity",
      "Resource": "*"
    },
    {
      "Sid": "FrontendDeployment",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::compliance-reporting-frontend-*",
        "arn:aws:s3:::compliance-reporting-frontend-*/*"
      ]
    },
    {
      "Sid": "CloudFrontInvalidation",
      "Effect": "Allow",
      "Action": "cloudfront:CreateInvalidation",
      "Resource": "*"
    }
  ]
}
EOF

# 5. Attach the permissions policy to the role
aws iam put-role-policy \
  --role-name GitHubActions-SOLAR-Deploy \
  --policy-name GitHubActionsDeployPermissions \
  --policy-document file://github-actions-permissions.json

# 6. Get the Role ARN - ADD THIS TO GITHUB SECRETS
echo ""
echo "============================================"
echo "Add this ARN to GitHub Secrets as AWS_ROLE_ARN:"
echo "============================================"
aws iam get-role --role-name GitHubActions-SOLAR-Deploy --query 'Role.Arn' --output text

# 7. Cleanup temp files
rm github-oidc-trust-policy.json github-actions-permissions.json
```

---

## Step 3: Add Secret to GitHub

1. Go to: https://github.com/AkhileshMishra/SOLAR/settings/secrets/actions
2. Click "New repository secret"
3. Name: `AWS_ROLE_ARN`
4. Value: `arn:aws:iam::430118833069:role/GitHubActions-SOLAR-Deploy`
5. Click "Add secret"

---

## How It Works

```
GitHub Actions
     │
     ▼ (OIDC Token)
GitHubActions-SOLAR-Deploy (KAIZERO)
     │
     ├──► KAIZERODeploymentServer ──► Deploy main infrastructure
     │
     └──► CrossAccountCognitoRole (KEP_APP_SS) ──► Create Cognito resources
```

No credentials stored anywhere - all authentication uses short-lived tokens.
