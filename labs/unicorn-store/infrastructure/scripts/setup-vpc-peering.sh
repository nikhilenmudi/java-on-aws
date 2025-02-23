#bin/sh

echo $(date '+%Y.%m.%d %H:%M:%S')

export UNICORN_VPC_ID=$(aws cloudformation describe-stacks --stack-name UnicornStoreInfrastructure --query 'Stacks[0].Outputs[?OutputKey==`idUnicornStoreVPC`].OutputValue' --output text)

export CLOUD9_VPC_ID=$(curl -s http://169.254.169.254/latest/meta-data/network/interfaces/macs/$( ip address show dev eth0 | grep ether | awk ' { print $2  } ' )/vpc-id)

export VPC_PEERING_ID=$(aws ec2 create-vpc-peering-connection --vpc-id $CLOUD9_VPC_ID \
--peer-vpc-id $UNICORN_VPC_ID \
--query 'VpcPeeringConnection.VpcPeeringConnectionId' --output text)

sleep 5

aws ec2 accept-vpc-peering-connection --vpc-peering-connection-id $VPC_PEERING_ID --output text

export CLOUD9_ROUTE_TABLE_ID=$(aws ec2 describe-route-tables \
--filters "Name=vpc-id,Values=$CLOUD9_VPC_ID" "Name=tag:Name,Values=java-on-aws-workshop Public Routes" \
--query 'RouteTables[0].RouteTableId' --output text)

export UNICORN_DB_ROUTE_TABLE_ID_1=$(aws ec2 describe-route-tables \
--filters "Name=vpc-id,Values=$UNICORN_VPC_ID" "Name=tag:Name,Values=UnicornStoreVpc/UnicornVpc/PrivateSubnet1" \
--query 'RouteTables[0].RouteTableId' --output text)
export UNICORN_DB_ROUTE_TABLE_ID_2=$(aws ec2 describe-route-tables \
--filters "Name=vpc-id,Values=$UNICORN_VPC_ID" "Name=tag:Name,Values=UnicornStoreVpc/UnicornVpc/PrivateSubnet2" \
--query 'RouteTables[0].RouteTableId' --output text)

aws ec2 create-route --route-table-id $CLOUD9_ROUTE_TABLE_ID \
--destination-cidr-block 10.0.0.0/16 --vpc-peering-connection-id $VPC_PEERING_ID

aws ec2 create-route --route-table-id $UNICORN_DB_ROUTE_TABLE_ID_1 \
--destination-cidr-block 10.10.0.0/16 --vpc-peering-connection-id $VPC_PEERING_ID
aws ec2 create-route --route-table-id $UNICORN_DB_ROUTE_TABLE_ID_2 \
--destination-cidr-block 10.10.0.0/16 --vpc-peering-connection-id $VPC_PEERING_ID
