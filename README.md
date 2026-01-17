# SOLAR - AI-Driven Compliance Reporting System

## About

SOLAR (System for Operational Log Analysis and Reporting) is an AI-powered compliance reporting solution built on AWS. It automates the process of validating system logs against policy documents (e.g., SOC2, ISO 27001) and generates detailed compliance reports.

### What It Does

- **Ingests** system logs (Excel/CSV) from various IT systems (CyberArk, ServiceNow, etc.)
- **Analyzes** logs against policy requirements using Amazon Bedrock's Claude model
- **Queries** structured data via Amazon Athena with AI-generated SQL
- **Generates** compliance reports in DOCX and HTML formats

### Key Capabilities

| Feature | Description |
|---------|-------------|
| Auto-DDL Ingestion | Automatically creates Athena views when logs are uploaded |
| Policy Section Extraction | Uses AI to parse policy PDFs into auditable sections |
| RAG-Based Analysis | Bedrock Agent with Knowledge Base for context-aware compliance checks |
| Parallel Processing | Step Functions workflow processes multiple sections concurrently |
| Audit History | Tracks all audit sessions per user with DynamoDB |

---

## How-To Guide

### Backend Workflows

#### 1. Uploading System Logs

Upload Excel/CSV files to trigger automatic processing:

```
S3 Path: inputs/logs/{SystemName}/
Example: inputs/logs/CyberArk/march_report.xlsx
```

**What happens:**
1. S3 trigger invokes `ingestion_agent` Lambda
2. Lambda converts Excel to CSV, saves to `processed/logs/{SystemName}/`
3. Glue Crawler updates the Athena table schema
4. Data becomes queryable via Athena

#### 2. Uploading Policy Documents

Upload PDF policy documents for AI extraction:

```
S3 Path: inputs/policy/
Example: inputs/policy/SOC2_Type2_Policy.pdf
```

**What happens:**
1. S3 trigger invokes `policy_section_fetcher` Lambda
2. Lambda sends PDF to Bedrock Claude for section extraction
3. Extracted sections are cached in DynamoDB (`policy-sections` table)
4. Subsequent requests fetch from cache (faster)

#### 3. Running Compliance Analysis

The Step Functions workflow orchestrates the full analysis:

```
Input:
{
  "policy_file": "inputs/policy/SOC2.pdf",
  "system_name": "CyberArk",
  "selected_sections": ["CC6.1", "CC6.2", "CC7.1"]
}
```

**Workflow stages:**
1. **Fetch Sections** - Retrieves policy sections from cache/Bedrock
2. **Parallel Analysis** - For each section, invokes Bedrock Agent to:
   - Query Athena for relevant log data
   - Compare against policy requirements
   - Generate compliance findings
3. **Generate Report** - Creates DOCX and HTML reports
4. **Store Results** - Saves to `outputs/reports/`

#### 4. Bedrock Agent Action Groups

The agent has two action groups:

| Action | Purpose |
|--------|---------|
| `query_athena` | Executes SQL queries against log data |
| `fetch_policy_section` | Retrieves specific policy section text |

**Athena SQL Notes:**
- Uses Presto SQL syntax (not PostgreSQL)
- Case-insensitive search: `LOWER(column) LIKE LOWER('%value%')`
- ILIKE is NOT supported

#### 5. Knowledge Base (RAG)

The Bedrock Knowledge Base stores policy documents for retrieval-augmented generation:
- Indexed from S3 policy folder
- Agent queries KB for policy context during analysis
- Improves accuracy of compliance assessments

---

### Frontend Workflows

#### 1. Starting a New Audit

1. Open the dashboard (CloudFront URL)
2. Sign in with Cognito credentials
3. Select **New Audit** tab
4. Choose a policy document from dropdown
5. Click **Analyze Policy** to extract sections
6. Select target system (e.g., CyberArk)
7. Check the sections to audit
8. Click **Generate Report**

#### 2. Monitoring Progress

During report generation:
- Progress modal shows current workflow stage
- Stages: Starting → Analyzing Sections → Generating Report → Complete
- On failure, error message is displayed

#### 3. Viewing Reports

After generation:
- HTML report displays inline with full findings
- **Download Report** button saves DOCX version
- **Go Back** returns to audit configuration
- **Close** returns to dashboard

#### 4. Audit History

1. Select **History** tab
2. View past audit sessions with:
   - Timestamp
   - Policy file used
   - System audited
   - Status (Completed/Failed)
3. Click **Download** to retrieve previous reports

---

## Technical Architecture

### Infrastructure Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              FRONTEND                                        │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────────────────────────┐  │
│  │  CloudFront │───▶│  S3 Static  │    │  Cognito (Identity Account)     │  │
│  │     CDN     │    │   Website   │    │  - User Pool                    │  │
│  └─────────────┘    └─────────────┘    │  - Identity Pool                │  │
│                                         └─────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         STORAGE & DATA LAYER                                 │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                         S3 Bucket                                    │    │
│  │  inputs/logs/         - Raw system logs (Excel/CSV)                 │    │
│  │  inputs/policy/       - Policy PDFs                                 │    │
│  │  processed/logs/      - Converted CSVs for Athena                   │    │
│  │  outputs/reports/     - Generated DOCX/HTML reports                 │    │
│  │  athena-results/      - Query results                               │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────────────┐  │
│  │  Glue Database  │    │ Athena Workgroup│    │  DynamoDB Tables        │  │
│  │  - Log tables   │    │ - Query engine  │    │  - policy-sections      │  │
│  │  - Auto-schema  │    │ - Presto SQL    │    │  - audit-history        │  │
│  └─────────────────┘    └─────────────────┘    └─────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         PROCESSING LAYER                                     │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                    Step Functions Workflow                           │    │
│  │                                                                      │    │
│  │  ┌──────────┐    ┌──────────────────┐    ┌───────────────────────┐  │    │
│  │  │  Fetch   │───▶│ Parallel Section │───▶│  Generate Report      │  │    │
│  │  │ Sections │    │    Analysis      │    │  (DOCX + HTML)        │  │    │
│  │  └──────────┘    └──────────────────┘    └───────────────────────┘  │    │
│  │                          │                                           │    │
│  │                          ▼                                           │    │
│  │                  ┌──────────────────┐                               │    │
│  │                  │  Bedrock Agent   │                               │    │
│  │                  │  - Claude Sonnet │                               │    │
│  │                  │  - Knowledge Base│                               │    │
│  │                  └──────────────────┘                               │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
│  Lambda Functions:                                                           │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────────────────┐  │
│  │ ingestion_agent │  │ policy_section  │  │ agent_athena_executor       │  │
│  │ - Excel→CSV     │  │ _fetcher        │  │ - Executes Athena queries   │  │
│  │ - Trigger Glue  │  │ - PDF parsing   │  │ - Returns results to agent  │  │
│  └─────────────────┘  │ - DynamoDB cache│  └─────────────────────────────┘  │
│                       └─────────────────┘                                    │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ report_generator                                                     │    │
│  │ - Creates DOCX with python-docx                                     │    │
│  │ - Creates HTML for inline viewing                                   │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────────────┘
```

### AWS Services Used

| Service | Purpose |
|---------|---------|
| S3 | Storage for logs, policies, and reports |
| CloudFront | CDN for React frontend |
| Cognito | User authentication (cross-account) |
| Lambda | Serverless compute for all processing |
| Step Functions | Workflow orchestration |
| Athena | SQL queries on log data |
| Glue | Data catalog and crawlers |
| Bedrock | AI model (Claude) and Knowledge Base |
| DynamoDB | Caching and audit history |

### Deployment

Infrastructure is managed with Terraform and deployed via GitHub Actions:

```
GitHub Push → GitHub Actions → Terraform Apply → AWS Resources
```

**Key files:**
- `main.tf` - All infrastructure definitions
- `variables.tf` - Configurable parameters
- `outputs.tf` - Exported values (URLs, ARNs)
- `.github/workflows/deploy.yml` - CI/CD pipeline

### Cross-Account Setup

| Account | Purpose | Resources |
|---------|---------|-----------|
| Compliance (430118833069) | Main infrastructure | S3, Lambda, Bedrock, Step Functions |
| Identity (304838292196) | Shared services | Cognito User Pool, Identity Pool |

### Security

- S3 bucket blocks all public access
- Server-side encryption (AES-256) on all objects
- Cognito handles authentication with JWT tokens
- IAM roles follow least-privilege principle
- CloudFront uses HTTPS only
