#!/bin/bash

# This script builds the python-processor Docker image and pushes it to a new
# Amazon ECR repository. It should be run from within the src/python-processor directory.
#
# NON-INTERACTIVE USAGE:
# You can bypass the interactive prompts by setting the following environment
# variables before running the script:
#
#   export AWS_REGION="us-east-1"
#   export AWS_ACCOUNT_ID="123456789012"
#
#   Example:
#   AWS_REGION="us-east-1" ./build-and-push.sh
#

set -e # Exit immediately if a command exits with a non-zero status.

# --- Configuration ---
echo "--- Gathering Configuration ---"

# Set static names
ECR_REPO_NAME="telemetry-hub-python-processor"
IMAGE_TAG="latest"

# Check for required CLIs
if ! command -v aws &> /dev/null || ! command -v docker &> /dev/null; then
    echo "Error: AWS CLI and Docker are required. Please install them to continue."
    exit 1
fi
echo "✅ Required CLIs (aws, docker) found."

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

# Check for AWS Account ID
if [ -z "$AWS_ACCOUNT_ID" ]; then
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
fi
if [ -z "$AWS_ACCOUNT_ID" ]; then
    echo "Could not determine AWS Account ID."
    read -p "Please enter your AWS Account ID: " AWS_ACCOUNT_ID
    if [ -z "$AWS_ACCOUNT_ID" ]; then
        echo "Error: AWS Account ID is required."
        exit 1
    fi
fi
echo "Using AWS Account ID: ${AWS_ACCOUNT_ID}"

# Derive ECR URI
ECR_REPO_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO_NAME}"


# --- Step 1: Ensure ECR Repository Exists ---
echo "--- Ensuring ECR repository exists: ${ECR_REPO_NAME} ---"
aws ecr create-repository \
    --repository-name "${ECR_REPO_NAME}" \
    --region "${AWS_REGION}" \
    --image-scanning-configuration scanOnPush=true > /dev/null 2>&1 || true
echo "✅ ECR repository check complete."


# --- Step 2: Build and Push Docker Image to ECR ---
echo "--- Building Docker image ---"
docker build -t "${ECR_REPO_NAME}:${IMAGE_TAG}" .

echo "--- Pushing Docker image to ECR ---"
aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
docker tag "${ECR_REPO_NAME}:${IMAGE_TAG}" "${ECR_REPO_URI}:${IMAGE_TAG}"
docker push "${ECR_REPO_URI}:${IMAGE_TAG}"

echo "✅ Docker image pushed successfully to ${ECR_REPO_URI}:${IMAGE_TAG}"
echo "You will use this URI when deploying the application to Kubernetes."
