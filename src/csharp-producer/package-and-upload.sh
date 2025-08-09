#!/bin/bash

# This script packages the csharp-producer application into a zip file,
# uploads it to S3, and generates a pre-signed URL for downloading.
#
# NON-INTERACTIVE USAGE:
# You can bypass the interactive prompts by setting the following environment
# variables before running the script:
#
#   export AWS_REGION="us-east-1"
#   export S3_BUCKET="your-s3-bucket-name"
#
#   Example:
#   AWS_REGION="us-east-1" S3_BUCKET="my-bucket" ./package-and-upload.sh
#

set -e # Exit immediately if a command exits with a non-zero status.

# --- Configuration ---
echo "--- Gathering Configuration ---"

# Set static names
PACKAGE_NAME="csharp-producer.zip"

# Check for required CLIs
if ! command -v aws &> /dev/null || ! command -v zip &> /dev/null; then
    echo "Error: AWS CLI and zip are required. Please install them to continue."
    exit 1
fi
echo "✅ Required CLIs (aws, zip) found."

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

# Check for S3 Bucket
if [ -z "$S3_BUCKET" ]; then
    # Default to the standard CloudFormation bucket name format
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
    S3_BUCKET="cf-templates-${AWS_ACCOUNT_ID}-${AWS_REGION}"
    echo "Using default S3 bucket: ${S3_BUCKET}"
fi
echo "Using S3 Bucket: ${S3_BUCKET}"


# --- Step 1: Create Zip Archive ---
echo "--- Creating application zip archive: ${PACKAGE_NAME} ---"
# Exclude the package itself and any previous build artifacts
zip -r "${PACKAGE_NAME}" . -x "publish/*" "${PACKAGE_NAME}"
echo "✅ Zip archive created successfully."


# --- Step 2: Upload to S3 ---
echo "--- Uploading to S3 ---"
aws s3 cp "${PACKAGE_NAME}" "s3://${S3_BUCKET}/${PACKAGE_NAME}" --region "${AWS_REGION}"
echo "✅ Package uploaded to s3://${S3_BUCKET}/${PACKAGE_NAME}"


# --- Step 3: Generate Pre-signed URL ---
echo "--- Generating pre-signed URL ---"
PRESIGNED_URL=$(aws s3 presign "s3://${S3_BUCKET}/${PACKAGE_NAME}" --expires-in 3600 --region "${AWS_REGION}")
echo "✅ Pre-signed URL generated successfully."
echo "-----------------------------------------------------"
echo "You will need this URL for the CloudFormation deployment:"
echo "${PRESIGNED_URL}"
echo "-----------------------------------------------------"
