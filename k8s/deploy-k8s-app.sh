#!/bin/bash

# This script deploys both the python-processor and load-generator applications
# to the EKS cluster.
#
# NON-INTERACTIVE USAGE:
# You can bypass the interactive prompts by setting the following environment
# variables before running the script:
#
#   export AWS_REGION="us-east-1"
#   export PROCESSOR_ECR_IMAGE_URI="..."
#   export LOADGEN_ECR_IMAGE_URI="..."
#   export DB_PASSWORD="your-secure-password"
#

set -e # Exit immediately if a command exits with a non-zero status.

# --- Configuration ---
echo "--- Gathering Configuration ---"

STACK_NAME="TelemetryHubStack"
CLUSTER_NAME="telemetry-hub-cluster"
PROCESSOR_SERVICE_ACCOUNT="python-processor-sa"
PROCESSOR_ECR_REPO="telemetry-hub-python-processor"
LOADGEN_ECR_REPO="telemetry-hub-load-generator"
K8S_NAMESPACE="default"

# ... (CLI checks and Region gathering remain the same) ...
if ! command -v aws &> /dev/null || ! command -v eksctl &> /dev/null || ! command -v kubectl &> /dev/null; then
    echo "Error: AWS CLI, eksctl, and kubectl are required."
    exit 1
fi
if [ -z "$AWS_REGION" ]; then AWS_REGION=$(aws configure get region 2>/dev/null); fi
if [ -z "$AWS_REGION" ]; then read -p "Enter AWS Region: " AWS_REGION; fi


# --- Step 1: Get Configuration from AWS ---
echo "--- Retrieving Configuration from AWS ---"
SQS_QUEUE_URL=$(aws cloudformation describe-stacks --stack-name "${STACK_NAME}" --query "Stacks[0].Outputs[?OutputKey=='SqsQueueUrl'].OutputValue" --output text --region "${AWS_REGION}")
RDS_ENDPOINT=$(aws cloudformation describe-stacks --stack-name "${STACK_NAME}" --query "Stacks[0].Outputs[?OutputKey=='RdsEndpoint'].OutputValue" --output text --region "${AWS_REGION}")
SQS_IAM_ROLE_ARN=$(aws cloudformation describe-stacks --stack-name "${STACK_NAME}" --query "Stacks[0].Outputs[?OutputKey=='SqsReaderRoleArn'].OutputValue" --output text --region "${AWS_REGION}")

# Get Processor ECR Image URI
if [ -z "$PROCESSOR_ECR_IMAGE_URI" ]; then
    echo "Attempting to find ECR Image URI for repo '${PROCESSOR_ECR_REPO}'..."
    PROCESSOR_ECR_IMAGE_URI=$(aws ecr describe-repositories --repository-names "${PROCESSOR_ECR_REPO}" --query "repositories[0].repositoryUri" --output text --region "${AWS_REGION}"):latest
fi
if [ -z "$PROCESSOR_ECR_IMAGE_URI" ]; then
    read -p "Please enter the full ECR Image URI for the Python Processor: " PROCESSOR_ECR_IMAGE_URI
fi
echo "✅ Using Processor Image URI: ${PROCESSOR_ECR_IMAGE_URI}"

# Get LoadGen ECR Image URI
if [ -z "$LOADGEN_ECR_IMAGE_URI" ]; then
    echo "Attempting to find ECR Image URI for repo '${LOADGEN_ECR_REPO}'..."
    LOADGEN_ECR_IMAGE_URI=$(aws ecr describe-repositories --repository-names "${LOADGEN_ECR_REPO}" --query "repositories[0].repositoryUri" --output text --region "${AWS_REGION}"):latest
fi
if [ -z "$LOADGEN_ECR_IMAGE_URI" ]; then
    read -p "Please enter the full ECR Image URI for the Load Generator: " LOADGEN_ECR_IMAGE_URI
fi
echo "✅ Using Load Generator Image URI: ${LOADGEN_ECR_IMAGE_URI}"


# --- Step 2: Create Kubernetes Secret for DB Password ---
echo "--- Creating Kubernetes Secret for DB Password ---"
if [ -z "$DB_PASSWORD" ]; then
  read -sp "Please enter the database master password to create the K8s secret: " DB_PASSWORD
  echo
fi
kubectl delete secret rds-credentials --ignore-not-found=true
kubectl create secret generic rds-credentials --from-literal=password="${DB_PASSWORD}"
echo "✅ Kubernetes secret 'rds-credentials' created."


# --- Step 3: Associate IAM Role with Kubernetes Service Account ---
echo "--- Setting up IAM Role for Service Account (IRSA) ---"
eksctl create iamserviceaccount \
    --name "${PROCESSOR_SERVICE_ACCOUNT}" \
    --namespace "${K8S_NAMESPACE}" \
    --cluster "${CLUSTER_NAME}" \
    --attach-role-arn "${SQS_IAM_ROLE_ARN}" \
    --approve \
    --override-existing-serviceaccounts
echo "✅ Service account '${PROCESSOR_SERVICE_ACCOUNT}' configured."


# --- Step 4: Deploy Processor Application to Kubernetes ---
echo "--- Deploying Python Processor application to EKS ---"
TMP_PROC_DEPLOY_FILE=$(mktemp)
cp python-processor/deployment.yaml "$TMP_PROC_DEPLOY_FILE"
sed -i.bak "s|image:.*|image: ${PROCESSOR_ECR_IMAGE_URI}|g" "$TMP_PROC_DEPLOY_FILE"
sed -i.bak "s|value: \"YOUR_SQS_QUEUE_URL\"|value: \"${SQS_QUEUE_URL}\"|g" "$TMP_PROC_DEPLOY_FILE"
sed -i.bak "s|value: \"YOUR_RDS_ENDPOINT\"|value: \"${RDS_ENDPOINT}\"|g" "$TMP_PROC_DEPLOY_FILE"
kubectl apply -f "$TMP_PROC_DEPLOY_FILE"
kubectl apply -f python-processor/service.yaml
rm -f "$TMP_PROC_DEPLOY_FILE" "$TMP_PROC_DEPLOY_FILE.bak"
echo "✅ Python Processor deployment initiated."


# --- Step 5: Deploy Load Generator Application to Kubernetes ---
echo "--- Deploying Load Generator application to EKS ---"
TMP_LOADGEN_DEPLOY_FILE=$(mktemp)
cp load-generator/deployment.yaml "$TMP_LOADGEN_DEPLOY_FILE"
sed -i.bak "s|image:.*|image: ${LOADGEN_ECR_IMAGE_URI}|g" "$TMP_LOADGEN_DEPLOY_FILE"
sed -i.bak "s|value: \"YOUR_SQS_QUEUE_URL\"|value: \"${SQS_QUEUE_URL}\"|g" "$TMP_LOADGEN_DEPLOY_FILE"
sed -i.bak "s|value: \"us-east-1\"|value: \"${AWS_REGION}\"|g" "$TMP_LOADGEN_DEPLOY_FILE"
kubectl apply -f "$TMP_LOADGEN_DEPLOY_FILE"
kubectl apply -f load-generator/service.yaml
rm -f "$TMP_LOADGEN_DEPLOY_FILE" "$TMP_LOADGEN_DEPLOY_FILE.bak"
echo "✅ Load Generator deployment initiated."


# --- Step 6: Verifying Deployments and Getting URL ---
echo "--- Verifying Deployments ---"
echo "Waiting for processor pod to become ready..."
kubectl wait --for=condition=Ready pod -l app=python-processor --timeout=300s
echo "✅ Python Processor pod is running."

echo "Waiting for load-generator pod to become ready..."
kubectl wait --for=condition=Ready pod -l app=load-generator --timeout=300s
echo "✅ Load Generator pod is running."

echo "--- Waiting for Load Balancer to be provisioned ---"
echo "(This can take a few minutes...)"
kubectl wait --for=jsonpath='{.status.loadBalancer.ingress}' service/load-generator-service --timeout=300s
LOAD_BALANCER_URL=$(kubectl get service load-generator-service -o=jsonpath='{.status.loadBalancer.ingress[0].hostname}')

echo "-----------------------------------------------------"
echo "✅ Deployment Complete!"
echo "Access the Load Generator UI at:"
echo "http://${LOAD_BALANCER_URL}"
echo "-----------------------------------------------------"
