#bin/sh

echo $(date '+%Y.%m.%d %H:%M:%S')

cd ~/environment

echo Get the existing VPC and Subnet IDs to inform EKS where to create the new cluster
export UNICORN_VPC_ID=$(aws cloudformation describe-stacks --stack-name UnicornStoreVpc --query 'Stacks[0].Outputs[?OutputKey==`idUnicornStoreVPC`].OutputValue' --output text)
export UNICORN_SUBNET_PRIVATE_1=$(aws ec2 describe-subnets \
--filters "Name=vpc-id,Values=$UNICORN_VPC_ID" "Name=tag:Name,Values=UnicornStoreVpc/UnicornVpc/PrivateSubnet1" --query 'Subnets[0].SubnetId' --output text)
export UNICORN_SUBNET_PRIVATE_2=$(aws ec2 describe-subnets \
--filters "Name=vpc-id,Values=$UNICORN_VPC_ID" "Name=tag:Name,Values=UnicornStoreVpc/UnicornVpc/PrivateSubnet2" --query 'Subnets[0].SubnetId' --output text)
export UNICORN_SUBNET_PUBLIC_1=$(aws ec2 describe-subnets \
--filters "Name=vpc-id,Values=$UNICORN_VPC_ID" "Name=tag:Name,Values=UnicornStoreVpc/UnicornVpc/PublicSubnet1" --query 'Subnets[0].SubnetId' --output text)
export UNICORN_SUBNET_PUBLIC_2=$(aws ec2 describe-subnets \
--filters "Name=vpc-id,Values=$UNICORN_VPC_ID" "Name=tag:Name,Values=UnicornStoreVpc/UnicornVpc/PublicSubnet2" --query 'Subnets[0].SubnetId' --output text)

aws ec2 create-tags --resources $UNICORN_SUBNET_PRIVATE_1 $UNICORN_SUBNET_PRIVATE_2 \
--tags Key=kubernetes.io/cluster/unicorn-store,Value=shared Key=kubernetes.io/role/internal-elb,Value=1

aws ec2 create-tags --resources $UNICORN_SUBNET_PUBLIC_1 $UNICORN_SUBNET_PUBLIC_2 \
--tags Key=kubernetes.io/cluster/unicorn-store,Value=shared Key=kubernetes.io/role/elb,Value=1

echo Create the cluster with eksctl
eksctl create cluster \
--name unicorn-store \
--version 1.27 --region $AWS_REGION \
--nodegroup-name managed-node-group-x64 --managed --node-type m5.xlarge --nodes 2 --nodes-min 2 --nodes-max 4 \
--with-oidc --full-ecr-access --alb-ingress-access \
--vpc-private-subnets $UNICORN_SUBNET_PRIVATE_1,$UNICORN_SUBNET_PRIVATE_2 \
--vpc-public-subnets $UNICORN_SUBNET_PUBLIC_1,$UNICORN_SUBNET_PUBLIC_2

echo Add the Participant IAM role to the list of the EKS cluster administrators to get access from the AWS Console..
eksctl create iamidentitymapping --cluster unicorn-store --region=$AWS_REGION \
    --arn arn:aws:iam::$ACCOUNT_ID:role/WSParticipantRole --username admin --group system:masters \
    --no-duplicate-arns

echo Create a Kubernetes namespace for the application:
kubectl create namespace unicorn-store-spring

echo Create an IAM-Policy with the proper permissions to publish to EventBridge, retrieve secrets & parameters and basic monitoring
cat <<EOF > service-account-policy.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Action": "xray:PutTraceSegments",
            "Resource": "*",
            "Effect": "Allow"
        },
        {
            "Action": "events:PutEvents",
            "Resource": "arn:aws:events:$AWS_REGION:$ACCOUNT_ID:event-bus/unicorns",
            "Effect": "Allow"
        },
        {
            "Action": [
                "secretsmanager:GetSecretValue",
                "secretsmanager:DescribeSecret"
            ],
            "Resource": "$(aws cloudformation describe-stacks --stack-name UnicornStoreInfrastructure --query 'Stacks[0].Outputs[?OutputKey==`arnUnicornStoreDbSecret`].OutputValue' --output text)",
            "Effect": "Allow"
        },
        {
            "Action": [
                "ssm:DescribeParameters",
                "ssm:GetParameters",
                "ssm:GetParameter",
                "ssm:GetParameterHistory"
            ],
            "Resource": "arn:aws:ssm:$AWS_REGION:$ACCOUNT_ID:parameter/databaseJDBCConnectionString",
            "Effect": "Allow"
        }
    ]
}
EOF
aws iam create-policy --policy-name unicorn-eks-service-account-policy --policy-document file://service-account-policy.json

echo Create a Kubernetes Service Account with a reference to the previous created IAM policy
eksctl create iamserviceaccount --cluster=unicorn-store --name=unicorn-store-spring --namespace=unicorn-store-spring \
   --attach-policy-arn=$(aws iam list-policies --query 'Policies[?PolicyName==`unicorn-eks-service-account-policy`].Arn' --output text) --approve --region=$AWS_REGION
rm service-account-policy.json

echo use External Secrets and install it via Helm
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets \
external-secrets/external-secrets \
-n external-secrets \
--create-namespace \
--set installCRDs=true \
--set webhook.port=9443 \
--wait

echo Install the External Secrets Operator
cat <<EOF | envsubst | kubectl create -f -
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: unicorn-store-spring-secret-store
  namespace: unicorn-store-spring
spec:
  provider:
    aws:
      service: SecretsManager
      region: $AWS_REGION
      auth:
        jwt:
          serviceAccountRef:
            name: unicorn-store-spring
EOF

cat <<EOF | kubectl create -f -
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: unicorn-store-spring-external-secret
  namespace: unicorn-store-spring
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: unicorn-store-spring-secret-store
    kind: SecretStore
  target:
    name: unicornstore-db-secret
    creationPolicy: Owner
  data:
    - secretKey: password
      remoteRef:
        key: unicornstore-db-secret
        property: password
EOF

echo $(date '+%Y.%m.%d %H:%M:%S')
