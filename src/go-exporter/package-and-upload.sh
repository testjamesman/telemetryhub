#!/bin/bash

# This script packages the go-exporter application into a tarball,
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
PACKAGE_NAME="go-exporter.tar.gz"
SOURCE_FILES="exporter.go go.mod go.sum"

# Check for required CLIs
if ! command -v aws &> /dev/null || ! command -v tar &> /dev/null; then
    echo "Error: AWS CLI and tar are required. Please install them to continue."
    exit 1
fi
echo "✅ Required CLIs (aws, tar) found."

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


# --- Step 1: Create Tarball ---
echo "--- Creating application tarball: ${PACKAGE_NAME} ---"
# Only include the specific source files needed to build the application
tar -czvf "${PACKAGE_NAME}" ${SOURCE_FILES}
echo "✅ Tarball created successfully."


# --- Step 2: Ensure S3 Bucket Exists ---
echo "--- Ensuring S3 bucket exists: ${S3_BUCKET} ---"
if ! aws s3api head-bucket --bucket "${S3_BUCKET}" > /dev/null 2>&1; then
    echo "Bucket does not exist. Creating bucket..."
    if [ "${AWS_REGION}" == "us-east-1" ]; then
        aws s3api create-bucket --bucket "${S3_BUCKET}" --region "${AWS_REGION}" > /dev/null
    else
        aws s3api create-bucket --bucket "${S3_BUCKET}" --region "${AWS_REGION}" --create-bucket-configuration LocationConstraint="${AWS_REGION}" > /dev/null
    fi
    echo "✅ Bucket created successfully."
else
    echo "✅ Bucket already exists."
fi


# --- Step 3: Upload to S3 ---
echo "--- Uploading to S3 ---"
aws s3 cp "${PACKAGE_NAME}" "s3://${S3_BUCKET}/${PACKAGE_NAME}" --region "${AWS_REGION}"
echo "✅ Package uploaded to s3://${S3_BUCKET}/${PACKAGE_NAME}"


# --- Step 4: Generate Pre-signed URL ---
echo "--- Generating pre-signed URL ---"
PRESIGNED_URL=$(aws s3 presign "s3://${S3_BUCKET}/${PACKAGE_NAME}" --expires-in 3600 --region "${AWS_REGION}")
echo "✅ Pre-signed URL generated successfully."


# --- Step 5: Cleanup ---
echo "--- Cleaning up local artifact ---"
rm "${PACKAGE_NAME}"
echo "✅ Local tarball removed."


echo "-----------------------------------------------------"
echo "You will need this URL for the CloudFormation deployment:"
echo "${PRESIGNED_URL}"
echo "-----------------------------------------------------"
