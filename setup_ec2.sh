#!/bin/bash
set -e

# Global variables
REGION="us-west-2"
CLUSTER_NAME="az-aware-bugbash-cluster-ec2"
ECS_ENDPOINT="https://madison.us-west-2.amazonaws.com"
TASK_COUNT="${TASK_COUNT:-6}"
ENVOY_IMAGE="${ENVOY_IMAGE:-public.ecr.aws/appmesh/aws-appmesh-envoy:v1.34.12.1-prod}"

setup_credentials() {
    local account_id=$1
    local role_name=$2
    
    eval "$(isengardcli credentials $account_id --role $role_name)"
    aws configure set cli_pager ""
}

get_vpc_info() {
    VPC_ID=$(aws ec2 --region $REGION describe-vpcs --filters "Name=isDefault,Values=true" --query "Vpcs[0].VpcId" --output text)
    
    # Get subnets from 3 different AZs
    SUBNETS=$(aws ec2 --region $REGION describe-subnets \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=map-public-ip-on-launch,Values=true" \
        --query "Subnets | sort_by(@, &AvailabilityZone) | [].[SubnetId, AvailabilityZone]" \
        --output text)
    
    # Extract unique AZs and their subnets
    SUBNET_1=$(echo "$SUBNETS" | awk 'NR==1 {print $1}')
    AZ_1=$(echo "$SUBNETS" | awk 'NR==1 {print $2}')
    
    SUBNET_2=$(echo "$SUBNETS" | awk -v az="$AZ_1" '$2 != az {print $1; exit}')
    AZ_2=$(echo "$SUBNETS" | awk -v az="$AZ_1" '$2 != az {print $2; exit}')
    
    SUBNET_3=$(echo "$SUBNETS" | awk -v az1="$AZ_1" -v az2="$AZ_2" '$2 != az1 && $2 != az2 {print $1; exit}')
    AZ_3=$(echo "$SUBNETS" | awk -v az1="$AZ_1" -v az2="$AZ_2" '$2 != az1 && $2 != az2 {print $2; exit}')
    
    echo "VPC ID: $VPC_ID"
    echo "Subnet 1: $SUBNET_1 (AZ: $AZ_1)"
    echo "Subnet 2: $SUBNET_2 (AZ: $AZ_2)"
    echo "Subnet 3: $SUBNET_3 (AZ: $AZ_3)"
}

setup_security_groups() {
    # Check if security groups exist and create them if they don't
    LB_SG=$(aws ec2 --region $REGION describe-security-groups \
        --filters "Name=group-name,Values=az-aware-routing-bugbash-lb-sg" "Name=vpc-id,Values=$VPC_ID" \
        --query "SecurityGroups[0].GroupId" --output text)

    if [ "$LB_SG" == "None" ] || [ -z "$LB_SG" ]; then
        echo "Creating LB security group..."
        LB_SG=$(aws ec2 --region $REGION create-security-group \
            --group-name az-aware-routing-bugbash-lb-sg \
            --description "Security group for az aware routing LB" \
            --vpc-id $VPC_ID \
            --query "GroupId" --output text)
    fi

    CLIENT_SG=$(aws ec2 --region $REGION describe-security-groups \
        --filters "Name=group-name,Values=az-aware-routing-bugbash-client-sg" "Name=vpc-id,Values=$VPC_ID" \
        --query "SecurityGroups[0].GroupId" --output text)

    if [ "$CLIENT_SG" == "None" ] || [ -z "$CLIENT_SG" ]; then
        echo "Creating client security group..."
        CLIENT_SG=$(aws ec2 --region $REGION create-security-group \
            --group-name az-aware-routing-bugbash-client-sg \
            --description "Security group for az aware routing client" \
            --vpc-id $VPC_ID \
            --query "GroupId" --output text)
    fi

    SERVER_SG=$(aws ec2 --region $REGION describe-security-groups \
        --filters "Name=group-name,Values=az-aware-routing-bugbash-server-sg" "Name=vpc-id,Values=$VPC_ID" \
        --query "SecurityGroups[0].GroupId" --output text)

    if [ "$SERVER_SG" == "None" ] || [ -z "$SERVER_SG" ]; then
        echo "Creating server security group..."
        SERVER_SG=$(aws ec2 --region $REGION create-security-group \
            --group-name az-aware-routing-bugbash-server-sg \
            --description "Security group for az aware routing server" \
            --vpc-id $VPC_ID \
            --query "GroupId" --output text)
    fi

    # Configure security group rules
    aws ec2 --region $REGION authorize-security-group-ingress \
        --group-id $LB_SG \
        --protocol tcp \
        --port 80 \
        --cidr 0.0.0.0/0 2>/dev/null || true

    aws ec2 --region $REGION authorize-security-group-ingress \
        --group-id $CLIENT_SG \
        --protocol tcp \
        --port 8080 \
        --source-group $LB_SG 2>/dev/null || true

    aws ec2 --region $REGION authorize-security-group-ingress \
        --group-id $SERVER_SG \
        --protocol tcp \
        --port 8090 \
        --source-group $CLIENT_SG 2>/dev/null || true
        
    echo "Security groups created/configured successfully"
}

create_ecs_cluster() {
    aws ecs --region $REGION --endpoint $ECS_ENDPOINT create-cluster \
        --cluster-name $CLUSTER_NAME \
        --service-connect-defaults '{
            "namespace": "az-aware-routing-bugbash-ec2"
        }'
    echo "ECS cluster created successfully"
}

get_ecs_ami() {
    AMI_ID=$(aws ssm get-parameter \
        --region $REGION \
        --name /aws/service/ecs/optimized-ami/amazon-linux-2/recommended \
        --query 'Parameter.Value' \
        --output text | jq -r '.image_id')
    echo "ECS-optimized AMI: $AMI_ID"
}

create_launch_template() {
    local account_id=$1
    
    # Check if launch template exists
    LT_ID=$(aws ec2 --region $REGION describe-launch-templates \
        --launch-template-names az-aware-ec2-launch-template \
        --query "LaunchTemplates[0].LaunchTemplateId" \
        --output text 2>/dev/null || echo "")
    
    if [ ! -z "$LT_ID" ] && [ "$LT_ID" != "None" ]; then
        echo "Launch template already exists: $LT_ID"
        return
    fi
    
    get_ecs_ami
    
    USER_DATA=$(cat <<'EOF'
#!/bin/bash
set -e

echo ECS_CLUSTER=__CLUSTER_NAME__ >> /etc/ecs/ecs.config
echo AWS_DEFAULT_REGION=__REGION__ >> /etc/ecs/ecs.config
echo ECS_BACKEND_HOST=__ECS_ENDPOINT__ >> /etc/ecs/ecs.config

# Install custom Envoy image
ENVOY_IMAGE=__ENVOY_IMAGE__
docker pull $ENVOY_IMAGE
docker tag $ENVOY_IMAGE ecs-service-connect-agent:interface-v1
docker image save ecs-service-connect-agent:interface-v1 -o ecs-service-connect-agent.interface-v1.tar
cp ecs-service-connect-agent.interface-v1.tar /var/lib/ecs/deps/serviceconnect/
systemctl stop ecs
rm -rf /var/lib/ecs/data/*; rm -rf /var/log/ecs/*
docker kill $(docker ps -q) 2>/dev/null || true
docker rm $(docker ps -a -q) 2>/dev/null || true
docker rmi --force $(docker images -a -q) 2>/dev/null || true
systemctl start ecs

# Wait for ECS agent to register
sleep 30
EOF
)
    
    USER_DATA=$(echo "$USER_DATA" | sed \
        -e "s|__CLUSTER_NAME__|${CLUSTER_NAME}|g" \
        -e "s|__REGION__|${REGION}|g" \
        -e "s|__ECS_ENDPOINT__|${ECS_ENDPOINT}|g" \
        -e "s|__ENVOY_IMAGE__|${ENVOY_IMAGE}|g")

    
    LT_ID=$(aws ec2 --region $REGION create-launch-template \
        --launch-template-name az-aware-ec2-launch-template \
        --version-description "ECS optimized launch template with custom Envoy" \
        --launch-template-data "{
            \"ImageId\": \"$AMI_ID\",
            \"InstanceType\": \"t3.medium\",
            \"IamInstanceProfile\": {
                \"Arn\": \"arn:aws:iam::${account_id}:instance-profile/ecsInstanceRole\"
            },
            \"SecurityGroupIds\": [\"$CLIENT_SG\", \"$SERVER_SG\"],
            \"MetadataOptions\": {
                \"HttpEndpoint\": \"enabled\",
                \"HttpTokens\": \"required\",
                \"HttpPutResponseHopLimit\": 2
            },
            \"UserData\": \"$(echo "$USER_DATA" | base64 | tr -d '\n')\",
            \"TagSpecifications\": [{
                \"ResourceType\": \"instance\",
                \"Tags\": [{
                    \"Key\": \"Name\",
                    \"Value\": \"az-aware-ecs-instance\"
                }]
            }]
        }" \
        --query 'LaunchTemplate.LaunchTemplateId' \
        --output text)
    
    echo "Launch template created: $LT_ID"
}

create_autoscaling_group() {
    # Check if ASG exists
    EXISTING_ASG=$(aws autoscaling --region $REGION describe-auto-scaling-groups \
        --auto-scaling-group-names az-aware-ec2-asg \
        --query "AutoScalingGroups[0].AutoScalingGroupName" \
        --output text 2>/dev/null || echo "")
    
    if [ ! -z "$EXISTING_ASG" ] && [ "$EXISTING_ASG" != "None" ]; then
        echo "Auto Scaling Group already exists: $EXISTING_ASG"
        return
    fi
    
    aws autoscaling --region $REGION create-auto-scaling-group \
        --auto-scaling-group-name az-aware-ec2-asg \
        --launch-template "LaunchTemplateId=$LT_ID" \
        --min-size 1 \
        --max-size 30 \
        --desired-capacity $((TASK_COUNT * 2)) \
        --vpc-zone-identifier "$SUBNET_1,$SUBNET_2,$SUBNET_3" \
        --health-check-type EC2 \
        --health-check-grace-period 300 \
        --tags "Key=Name,Value=az-aware-ecs-instance,PropagateAtLaunch=true"
    
    echo "Auto Scaling Group created successfully"
}

setup_load_balancer() {
    # Check if ALB exists
    ALB_ARN=$(aws elbv2 --region $REGION describe-load-balancers \
        --names az-aware-routing-bugbash-ec2 \
        --query "LoadBalancers[0].LoadBalancerArn" \
        --output text 2>/dev/null || echo "")
    
    if [ -z "$ALB_ARN" ] || [ "$ALB_ARN" == "None" ]; then
        echo "Creating new load balancer..."
        ALB_ARN=$(aws elbv2 --region $REGION create-load-balancer \
            --name az-aware-routing-bugbash-ec2 \
            --subnets $SUBNET_1 $SUBNET_2 $SUBNET_3 \
            --security-groups $LB_SG \
            --query "LoadBalancers[0].LoadBalancerArn" \
            --output text)
    else
        echo "Using existing load balancer: $ALB_ARN"
    fi

    # Check if target group exists
    TG_ARN=$(aws elbv2 --region $REGION describe-target-groups \
        --names az-aware-routing-bugbash-ec2 \
        --query "TargetGroups[0].TargetGroupArn" \
        --output text 2>/dev/null || echo "")
    
    if [ -z "$TG_ARN" ] || [ "$TG_ARN" == "None" ]; then
        echo "Creating new target group..."
        TG_ARN=$(aws elbv2 --region $REGION create-target-group \
            --name az-aware-routing-bugbash-ec2 \
            --protocol HTTP \
            --port 80 \
            --vpc-id $VPC_ID \
            --target-type ip \
            --health-check-path /ping \
            --health-check-interval-seconds 10 \
            --query "TargetGroups[0].TargetGroupArn" \
            --output text)
    else
        echo "Using existing target group: $TG_ARN"
    fi

    # Check if listener exists
    LISTENER_ARN=$(aws elbv2 --region $REGION describe-listeners \
        --load-balancer-arn $ALB_ARN \
        --query "Listeners[0].ListenerArn" \
        --output text 2>/dev/null || echo "")
    
    if [ -z "$LISTENER_ARN" ] || [ "$LISTENER_ARN" == "None" ]; then
        echo "Creating new listener..."
        aws elbv2 --region $REGION create-listener \
            --load-balancer-arn $ALB_ARN \
            --protocol HTTP \
            --port 80 \
            --default-actions Type=forward,TargetGroupArn=$TG_ARN
    else
        echo "Listener already exists: $LISTENER_ARN"
    fi
        
    echo "Load balancer setup completed"
    echo "Target group ARN: $TG_ARN"
    echo "Load balancer ARN: $ALB_ARN"
}

register_task_definitions() {
    local account_id=$1
    
    # Register frontend service task def version
    FE_SERVICE_TD=$(aws ecs register-task-definition \
        --region $REGION \
        --endpoint $ECS_ENDPOINT \
        --family az-aware-fe-service-ec2 \
        --requires-compatibilities EC2 \
        --network-mode awsvpc \
        --cpu 1024 \
        --memory 2048 \
        --execution-role-arn arn:aws:iam::${account_id}:role/ecsTaskExecutionRole \
        --task-role-arn arn:aws:iam::${account_id}:role/ecsTaskExecutionRole \
        --runtime-platform cpuArchitecture=X86_64,operatingSystemFamily=LINUX \
        --container-definitions '[
            {
                "name": "fe-app",
                "image": "public.ecr.aws/h5t0a8k7/serviceconnect/az-aware-routing-test:latest",
                "cpu": 512,
                "memory": 1024,
                "portMappings": [
                    {
                        "name": "http",
                        "containerPort": 8080,
                        "protocol": "tcp",
                        "appProtocol": "http"
                    }
                ],
                "essential": true,
                "command": ["server","-port=8080","-protocol=http","-name=fe","-routes=[{\"match\":\"product\", \"destination\": \"http://sc.test.az.aware.backend:8090\",\"method\":\"Egress\"}]"],
                "logConfiguration": {
                    "logDriver": "awslogs",
                    "options": {
                        "awslogs-group": "/ecs/az-aware-fe-service-ec2",
                        "awslogs-region": "us-west-2",
                        "awslogs-stream-prefix": "ecs",
                        "awslogs-create-group": "true"
                    }
                }
            }
        ]' \
        --query 'taskDefinition.revision' \
        --output text)

    # Register backend service task def version
    BACKEND_SERVICE_TD=$(aws ecs register-task-definition \
        --region $REGION \
        --endpoint $ECS_ENDPOINT \
        --family az-aware-backend-service-ec2 \
        --requires-compatibilities EC2 \
        --network-mode awsvpc \
        --cpu 1024 \
        --memory 2048 \
        --execution-role-arn arn:aws:iam::${account_id}:role/ecsTaskExecutionRole \
        --task-role-arn arn:aws:iam::${account_id}:role/ecsTaskExecutionRole \
        --runtime-platform cpuArchitecture=X86_64,operatingSystemFamily=LINUX \
        --container-definitions '[
            {
                "name": "backend-app",
                "image": "public.ecr.aws/h5t0a8k7/serviceconnect/az-aware-routing-test:latest",
                "cpu": 512,
                "memory": 1024,
                "portMappings": [
                    {
                        "name": "http",
                        "containerPort": 8090,
                        "protocol": "tcp",
                        "appProtocol": "http"
                    }
                ],
                "essential": true,
                "command": ["server","-port=8090","-protocol=http","-name=product","-routes=[]"],
                "logConfiguration": {
                    "logDriver": "awslogs",
                    "options": {
                        "awslogs-group": "/ecs/az-aware-backend-service-ec2",
                        "awslogs-region": "us-west-2",
                        "awslogs-stream-prefix": "ecs",
                        "awslogs-create-group": "true"
                    }
                }
            }
        ]' \
        --query 'taskDefinition.revision' \
        --output text)
    
    echo "Task definitions registered successfully"
    echo "AZ Aware FE Service TD: $FE_SERVICE_TD"
    echo "AZ Aware Backend Service TD: $BACKEND_SERVICE_TD"
}

create_services() {
    local fe_revision=$1
    local backend_revision=$2
    
    local fe_def="az-aware-fe-service-ec2"
    local backend_def="az-aware-backend-service-ec2"
    
    # Append revision numbers if provided
    if [ ! -z "$fe_revision" ]; then
        fe_def="${fe_def}:${fe_revision}"
    fi
    if [ ! -z "$backend_revision" ]; then
        backend_def="${backend_def}:${backend_revision}"
    fi
    
    echo "Creating services with task definitions:"
    echo "Backend service: $backend_def"
    echo "FE service: $fe_def"
    
    echo "Waiting for cluster and container instances to be ready..."
    sleep 30

    # Check if backend service exists
    BACKEND_EXISTS=$(aws ecs --region $REGION --endpoint $ECS_ENDPOINT describe-services \
        --cluster $CLUSTER_NAME \
        --services az-aware-backend-service-ec2 \
        --query "services[?status=='ACTIVE'].serviceName" \
        --output text 2>/dev/null || echo "")
    
    if [ -z "$BACKEND_EXISTS" ]; then
        echo "Creating backend service..."
        # Create backend
        aws ecs --region $REGION --endpoint $ECS_ENDPOINT create-service \
            --cluster $CLUSTER_NAME \
            --service-name az-aware-backend-service-ec2 \
            --task-definition $backend_def \
            --desired-count $TASK_COUNT \
            --launch-type EC2 \
            --enable-execute-command \
            --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_1,$SUBNET_2,$SUBNET_3],securityGroups=[$SERVER_SG]}" \
            --service-connect-configuration '{
                "enabled": true,
                "logConfiguration": {
                    "logDriver": "awslogs",
                    "options": {
                        "awslogs-group": "/ecs/az-aware-backend-service-ec2",
                        "awslogs-region": "us-west-2",
                        "awslogs-stream-prefix": "service-connect"
                    }
                },
                "services": [{
                    "portName": "http",
                    "discoveryName": "sc-test-az-aware-backend",
                    "clientAliases": [{
                        "port": 8090,
                        "dnsName": "sc.test.az.aware.backend"
                    }]
                }]
            }'
    else
        echo "Backend service already exists, skipping creation"
    fi

    # Check if frontend service exists
    FE_EXISTS=$(aws ecs --region $REGION --endpoint $ECS_ENDPOINT describe-services \
        --cluster $CLUSTER_NAME \
        --services az-aware-fe-service-ec2 \
        --query "services[?status=='ACTIVE'].serviceName" \
        --output text 2>/dev/null || echo "")
    
    if [ -z "$FE_EXISTS" ]; then
        echo "Creating frontend service..."
        # Create frontend service
        aws ecs --region $REGION --endpoint $ECS_ENDPOINT create-service \
            --cluster $CLUSTER_NAME \
            --service-name az-aware-fe-service-ec2 \
            --task-definition $fe_def \
            --desired-count $TASK_COUNT \
            --launch-type EC2 \
            --enable-execute-command \
            --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_1,$SUBNET_2,$SUBNET_3],securityGroups=[$CLIENT_SG]}" \
            --load-balancers "[{
                \"targetGroupArn\": \"$TG_ARN\",
                \"containerName\": \"fe-app\",
                \"containerPort\": 8080
            }]" \
            --service-connect-configuration '{
                "enabled": true,
                "logConfiguration": {
                    "logDriver": "awslogs",
                    "options": {
                        "awslogs-group": "/ecs/az-aware-fe-service-ec2",
                        "awslogs-region": "us-west-2",
                        "awslogs-stream-prefix": "service-connect"
                    }
                },
                "services": [{
                    "portName": "http",
                    "discoveryName": "sc-test-az-aware-fe",
                    "clientAliases": [{
                        "port": 8080,
                        "dnsName": "sc.test.az.aware.fe"
                    }]
                }]
            }'
    else
        echo "Frontend service already exists, skipping creation"
    fi
        
    echo "Services created successfully"
}

show_alb_dns() {
    echo "Setup complete! Your ALB DNS name is:"
    ALB_BNS_NAME=$(aws elbv2 --region $REGION describe-load-balancers \
        --load-balancer-arns $ALB_ARN \
        --query "LoadBalancers[0].DNSName" \
        --output text)
    export ALB_BNS_NAME=$ALB_BNS_NAME     
    echo $ALB_BNS_NAME    
}

start_web_analyzer() {
    # Check if port 8080 is in use
    if lsof -ti:8080 > /dev/null 2>&1; then
        # Get the process name
        PROCESS=$(lsof -ti:8080 | xargs ps -p | grep -v PID | awk '{print $4}')
    
        # Check if it's our proxy server
        if echo "$PROCESS" | grep -q "python"; then
            # Check if it's running our proxy script
            echo "Killing existing proxy server on port 8080..."
            lsof -ti:8080 | xargs kill -9
            sleep 1
        else
            echo "ERROR: Port 8080 is occupied by: $PROCESS"
            exit 1
        fi
    fi
    LB_DNS_NAME=$ALB_BNS_NAME python3 az-aware-testing-proxy-server.py &
    sleep 2
    if open -a "Google Chrome" http://localhost:8080/az-routing-test.html 2>/dev/null; then
        echo "Opened in Chrome"
    elif open -a "Firefox" http://localhost:8080/az-routing-test.html 2>/dev/null; then
        echo "Opened in Firefox"
    elif open -a "Safari" http://localhost:8080/az-routing-test.html 2>/dev/null; then
        echo "Opened in Safari"
    else
        echo "Could not open browser. Please navigate to http://localhost:8080/az-routing-test.html"
    fi
}

main() {
    if [ -z "$1" ]; then
        echo "Usage: $0 <account-id> [role-name] [component] [fe_revision] [backend_revision]"
        echo "Components: infrastructure, tasks, services, all"
        echo "fe_revision: Optional task definition revision for az-aware-fe-service-ec2"
        echo "backend_revision: Optional task definition revision for az-aware-backend-service-ec2"
        exit 1
    fi

    local account_id=$1
    local role_name=${2:-Admin}
    local component=${3:-all}
    local fe_revision=$4
    local backend_revision=$5

    setup_credentials "$account_id" "$role_name"

    case $component in
        "infrastructure")
            get_vpc_info
            setup_security_groups
            create_ecs_cluster
            create_launch_template "$account_id"
            create_autoscaling_group
            setup_load_balancer
            ;;
        "tasks")
            register_task_definitions "$account_id"
            ;;
        "services")
            create_services "$fe_revision" "$backend_revision"
            show_alb_dns
            start_web_analyzer
            ;;
        "analyzer")
            start_web_analyzer
            ;;            
        "all")
            get_vpc_info
            setup_security_groups
            create_ecs_cluster
            create_launch_template "$account_id"
            create_autoscaling_group
            setup_load_balancer
            register_task_definitions "$account_id"
            create_services "$FE_REVISION" "$BACKEND_REVISION"
            show_alb_dns
            start_web_analyzer
            ;;
        *)
            echo "Invalid component. Choose from: infrastructure, tasks, analyzer, services, all"
            exit 1
            ;;
    esac
}

# Execute main function with all arguments
main "$@"
