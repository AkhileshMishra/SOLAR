'''
# AI-Driven Compliance Reporting System

This repository contains a complete, end-to-end solution for an AI-Driven Compliance Reporting System built on AWS. The system ingests raw logs and policy documents, uses Generative AI to structure and analyze the data, and generates formatted Microsoft Word (.docx) compliance reports.

This solution was designed and implemented by a Principal AWS Solutions Architect and Senior DevOps Engineer, leveraging Infrastructure as Code (IaC) with Terraform and serverless application logic with Python and Boto3.

## Table of Contents

- [System Architecture](#system-architecture)
- [Features](#features)
- [File Structure](#file-structure)
- [Prerequisites](#prerequisites)
- [Deployment Instructions](#deployment-instructions)
- [Usage Workflow](#usage-workflow)
- [Terraform Resources](#terraform-resources)

## System Architecture

The system is composed of four main layers, orchestrated to provide a seamless data ingestion, analysis, and reporting pipeline.

![System Architecture Diagram](https://user-images.githubusercontent.com/12345/placeholder.png)  *(Note: A proper architecture diagram should be generated and linked here)*

1.  **Storage & Data Layer**: An S3 bucket serves as the central data lake, with prefixes for raw logs, policy documents, and generated reports. AWS Glue and Amazon Athena provide the data catalog and serverless query engine.

2.  **Auto-DDL Ingestion Layer**: A Python Lambda function, `LogIngestionAgent`, is triggered when new logs are uploaded. It uses Amazon Bedrock (Claude 3.5 Sonnet) to analyze a sample of the log file and automatically generate and execute an `CREATE OR REPLACE VIEW` statement in Athena. This "Auto-DDL" capability allows the system to adapt to varying log schemas without manual intervention.

3.  **AI Reasoning Core**: This layer forms the analytical heart of the system.
    *   **Amazon OpenSearch Serverless**: Acts as a vector store for the policy document.
    *   **Amazon Bedrock Knowledge Base**: Provides Retrieval-Augmented Generation (RAG) capabilities by indexing the policy PDF from S3 into the OpenSearch collection.
    *   **Amazon Bedrock Agent**: An AI agent named `ComplianceAuditorAgent` orchestrates the analysis. It has access to two tools: an action group to query the Athena views and the Knowledge Base to consult the compliance policy.

4.  **Orchestration & Reporting Layer**: An AWS Step Functions state machine (`ComplianceWorkflow`) orchestrates the end-to-end process.
    *   It begins by fetching the main sections of the policy document.
    *   Using a **Map State**, it invokes the Bedrock Agent in parallel for each policy section, enabling concurrent analysis.
    *   Finally, it aggregates the findings and passes them to the `ReportGenerator` Lambda, which uses the `python-docx` library to create a formatted Microsoft Word report and saves it to S3.

## Features

- **Infrastructure as Code**: All AWS resources are defined in Terraform for repeatable, automated deployments.
- **Serverless & Managed**: The architecture heavily relies on serverless and managed services (Lambda, S3, Bedrock, Step Functions, OpenSearch Serverless) to minimize operational overhead.
- **AI-Powered Auto-DDL**: Automatically creates database schemas (views) for new log sources using an LLM, eliminating a common data engineering bottleneck.
- **RAG-Based Policy Analysis**: Leverages a Bedrock Knowledge Base for accurate, context-aware analysis of logs against policy documents.
- **Orchestrated Reasoning**: A Bedrock Agent combines tools (log querying, policy lookup) to perform complex compliance checks.
- **Parallel Processing**: Step Functions Map State processes multiple policy sections concurrently for faster analysis.
- **Automated Report Generation**: Produces professional, formatted `.docx` reports ready for auditors and stakeholders.

## File Structure

```
.
├── main.tf                           # Main Terraform file with all AWS resources
├── variables.tf                      # Terraform input variables
├── outputs.tf                        # Terraform output values
├── agent_schema.json                 # OpenAPI schema for the Bedrock Agent's Athena tool
├── README.md                         # This documentation file
├── layers/
│   └── python-docx-requirements.txt  # Requirements for the python-docx Lambda layer
└── src/
    ├── ingestion_agent/
    │   └── lambda_function.py       # Python code for the Auto-DDL LogIngestionAgent
    ├── report_generator/
    │   └── lambda_function.py       # Python code for the DOCX ReportGenerator
    ├── policy_section_fetcher/
    │   └── lambda_function.py       # Python code to extract policy sections for the Map state
    └── agent_athena_executor/
        └── lambda_function.py       # Python code for the Bedrock Agent's action group
```

## Prerequisites

- [Terraform](https://learn.hashicorp.com/tutorials/terraform/install-cli) (v1.5.0+)
- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) configured with appropriate credentials
- Python 3.9+ and `pip`
- `zip` command-line utility

## Deployment Instructions

1.  **Clone the Repository**

    ```bash
    git clone https://github.com/AkhileshMishra/SOLAR.git
    cd SOLAR
    ```

2.  **Build the `python-docx` Lambda Layer**

    The `ReportGenerator` Lambda requires the `python-docx` library, which must be packaged as a Lambda layer. A helper script can automate this, or you can run the commands manually.

    ```bash
    # Create the directory structure
    mkdir -p layers/python-docx/python

    # Install dependencies into the target directory
    pip install -r layers/python-docx-requirements.txt -t layers/python-docx/python/

    # Create the zip archive for the layer
    # Note: The .terraform directory is created during `terraform init`
    mkdir -p .terraform/layers
    (cd layers/python-docx && zip -r ../../.terraform/layers/python-docx.zip .)
    ```

3.  **Initialize and Apply Terraform**

    Initialize the Terraform workspace and deploy the resources. This will take several minutes, as creating the OpenSearch collection and Bedrock resources can be time-consuming.

    ```bash
    terraform init
    terraform apply -auto-approve
    ```

    Upon completion, Terraform will output the names and ARNs of the key resources created.

## Usage Workflow

Follow these steps to run your first compliance report.

1.  **Upload a Policy Document**

    Upload your organization's policy document (in PDF format) to the designated S3 prefix. Use the `s3_bucket_name` from the Terraform output.

    ```bash
    BUCKET_NAME=$(terraform output -raw s3_bucket_name)
    aws s3 cp /path/to/your/TECH-S01-01.pdf s3://${BUCKET_NAME}/inputs/policy/
    ```

2.  **Synchronize the Knowledge Base**

    After uploading the policy, you must trigger an ingestion job to have the Bedrock Knowledge Base index it.

    ```bash
    KB_ID=$(terraform output -raw knowledge_base_id)
    DATA_SOURCE_ID=$(aws bedrock-agent list-data-sources --knowledge-base-id $KB_ID --query 'dataSourceSummaries[0].dataSourceId' --output text)

    aws bedrock-agent start-ingestion-job \
      --knowledge-base-id $KB_ID \
      --data-source-id $DATA_SOURCE_ID
    ```

    You can monitor the status of the ingestion job in the AWS Bedrock console.

3.  **Upload Log Files**

    Upload one or more raw log files (CSV or JSON) to the `/inputs/logs/` prefix. This will automatically trigger the `LogIngestionAgent` Lambda, which will create the corresponding Athena views.

    ```bash
    aws s3 cp /path/to/your/servicenow.csv s3://${BUCKET_NAME}/inputs/logs/
    aws s3 cp /path/to/your/cato-logs.json s3://${BUCKET_NAME}/inputs/logs/
    ```

4.  **Execute the Step Functions Workflow**

    Start the main compliance workflow. This can be done via the AWS console or the AWS CLI.

    ```bash
    STATE_MACHINE_ARN=$(terraform output -raw step_functions_arn)

    aws stepfunctions start-execution \
      --state-machine-arn $STATE_MACHINE_ARN \
      --input '{}'
    ```

5.  **Retrieve the Report**

    The workflow will run for several minutes. Once complete, the final `.docx` report will be available in the `/outputs/reports/` S3 prefix.

    ```bash
    echo "Report will be available in: s3://${BUCKET_NAME}/outputs/reports/"
    aws s3 ls s3://${BUCKET_NAME}/outputs/reports/
    ```

## Terraform Resources

This solution deploys the following key AWS resources:

| Resource Type                      | Name / Purpose                                       |
| ---------------------------------- | ---------------------------------------------------- |
| **S3 Bucket**                      | `compliance-reporting-bucket-{id}` for all data      |
| **Glue Catalog Database**          | `compliance_db` for Athena schemas                   |
| **Athena Workgroup**               | `compliance_auditor` for running queries             |
| **OpenSearch Serverless**          | `compliance-policy-vectors` as the vector store      |
| **Bedrock Knowledge Base**         | `CompliancePolicyKB` for RAG on the policy PDF        |
| **Bedrock Agent**                  | `ComplianceAuditorAgent` to orchestrate analysis     |
| **Lambda Function**                | `LogIngestionAgent` for Auto-DDL                     |
| **Lambda Function**                | `AgentAthenaExecutor` for the agent's action group   |
| **Lambda Function**                | `PolicySectionFetcher` to get sections for the Map state |
| **Lambda Function**                | `ReportGenerator` to create the final DOCX report    |
| **Lambda Layer**                   | `python-docx` layer for the report generator         |
| **Step Functions State Machine**   | `ComplianceWorkflow` to orchestrate the entire process |
| **IAM Roles & Policies**           | Least-privilege roles for all services               |
'''
