#!/bin/bash

# This script automates the deployment of the Telemetry Hub CloudFormation stack.
#
# NON-INTERACTIVE USAGE:
# You can bypass the interactive prompts by setting the following environment
# variables before running the script:
#
#   export AWS_REGION="us-east-1"
#   export DB_PASSWORD="your-secure-password"
#   export USE_MY_IP="true" # Set to "true" to use your current IP, otherwise it defaults to 0.0.0.0/0
#   export GO_EXPORTER_URL="your-go-exporter-presigned-s3-url"
#   export CSHARP_PRODUCER_URL="your-csharp-producer-presigned-s3-url"
#
#   Example:
#   DB_PASSWORD="your-secure-password" USE_MY_IP="true" ./deploy-infra.sh
#

set -e # Exit immediately if a command exits with a non-zero status.

# --- Configuration ---
echo "--- Gathering Configuration ---"

# Set static names
STACK_NAME="TelemetryHubStack"
TEMPLATE_FILE="cloudformation.yml"

# Check for AWS CLI
if ! command -v aws &> /dev/null
then
    echo "Error: AWS CLI is not installed. Please install it to continue."
    exit 1
fi
echo "✅ AWS CLI found."

# Check for AWS Region
if [ -z "$AWS_REGION" ]; then
    AWS_REGION=$(aws configure get region 2>/dev/null)
fi
if [ -z "$AWS_REGION" ]; then
    echo "AWS Region not set or configured."
    read -p "Please enter your target AWS Region (e.g., us-east-1): " AWS_REGION
    if [ -z "$AWS_REGION" ]; then
        echo "Error: AWS Region is required."
        exit 1
    fi
fi
echo "Using AWS Region: ${AWS_REGION}"

# --- Step 1: Check for User-Provided Parameters ---
echo "--- Checking for User-Provided Parameters ---"

# Determine IP Address to use
MY_IP="0.0.0.0/0" # Default to all IPs

if [[ "$USE_MY_IP" == "true" ]]; then
    echo "USE_MY_IP is set. Fetching your current public IP address..."
    FETCHED_IP=$(curl -s http://checkip.amazonaws.com)/32
    if [ "$FETCHED_IP" != "/32" ]; then
        MY_IP=$FETCHED_IP
    else
        echo "⚠️  Could not determine public IP. Using default 0.0.0.0/0."
    fi
else
    read -p "Use your current IP for SSH/RDP access instead of 0.0.0.0/0? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Fetching your current public IP address..."
        FETCHED_IP=$(curl -s http://checkip.amazonaws.com)/32
        if [ "$FETCHED_IP" != "/32" ]; then
            MY_IP=$FETCHED_IP
        else
            echo "⚠️  Could not determine public IP. Using default 0.0.0.0/0."
        fi
    fi
fi
echo "Using IP Address for Security Groups: ${MY_IP}"

# Get the database password
if [ -z "$DB_PASSWORD" ]; then
  echo "DB_PASSWORD environment variable not set."
  read -sp "Please enter your desired database master password: " DB_PASSWORD
  echo
  if [ -z "$DB_PASSWORD" ]; then
    echo "Error: Database password is required."
    exit 1
  fi
fi
echo "✅ Database password is set."

# Get the Go Exporter URL
if [ -z "$GO_EXPORTER_URL" ]; then
  echo "GO_EXPORTER_URL environment variable not set."
  read -p "Please enter the pre-signed S3 URL for the Go Exporter package: " GO_EXPORTER_URL
  if [ -z "$GO_EXPORTER_URL" ]; then
    echo "Error: Go Exporter URL is required."
    exit 1
  fi
fi
echo "✅ Go Exporter URL is set."

# Get the C# Producer URL
if [ -z "$CSHARP_PRODUCER_URL" ]; then
  echo "CSHARP_PRODUCER_URL environment variable not set."
  read -p "Please enter the pre-signed S3 URL for the C# Producer package: " CSHARP_PRODUCER_URL
  if [ -z "$CSHARP_PRODUCER_URL" ]; then
    echo "Error: C# Producer URL is required."
    exit 1
  fi
fi
echo "✅ C# Producer URL is set."


# --- Step 2: Deploy CloudFormation Stack ---
echo "--- Deploying CloudFormation stack: ${STACK_NAME} ---"

aws cloudformation deploy \
  --template-file "${TEMPLATE_FILE}" \
  --stack-name "${STACK_NAME}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region "${AWS_REGION}" \
  --parameter-overrides \
    MyIP="${MY_IP}" \
    DbMasterPassword="${DB_PASSWORD}" \
    GoExporterPackageUrl="${GO_EXPORTER_URL}" \
    CSharpProducerPackageUrl="${CSHARP_PRODUCER_URL}"

echo "--- Waiting for stack deployment to complete. This can take 10-15 minutes... ---"
aws cloudformation wait stack-create-complete --stack-name "${STACK_NAME}" --region "${AWS_REGION}"

echo "--- Deployment Complete. Stack Outputs: ---"
aws cloudformation describe-stacks --stack-name "${STACK_NAME}" --query "Stacks[0].Outputs" --output table --region "${AWS_REGION}"
