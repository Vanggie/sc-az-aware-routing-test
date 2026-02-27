#!/bin/bash
set -e

REGION="us-west-2"
CLUSTER_NAME="az-aware-bugbash-cluster-ec2"
ECS_ENDPOINT="https://madison.us-west-2.amazonaws.com"

setup_credentials() {
    local account_id=$1
    local role_name=$2
    
    eval "$(isengardcli credentials $account_id --role $role_name)"
    aws configure set cli_pager ""
}

delete_services() {
    echo "Deleting ECS services..."
    
    aws ecs --region $REGION --endpoint $ECS_ENDPOINT update-service \
        --cluster $CLUSTER_NAME \
        --service az-aware-fe-service-ec2 \
        --desired-count 0 2>/dev/null || true
    
    aws ecs --region $REGION --endpoint $ECS_ENDPOINT update-service \
        --cluster $CLUSTER_NAME \
        --service az-aware-backend-service-ec2 \
        --desired-count 0 2>/dev/null || true
    
    sleep 5
    
    aws ecs --region $REGION --endpoint $ECS_ENDPOINT delete-service \
        --cluster $CLUSTER_NAME \
        --service az-aware-fe-service-ec2 2>/dev/null || true
    
    aws ecs --region $REGION --endpoint $ECS_ENDPOINT delete-service \
        --cluster $CLUSTER_NAME \
        --service az-aware-backend-service-ec2 2>/dev/null || true
    
    echo "Services deleted"
}

delete_autoscaling_group() {
    echo "Deleting Auto Scaling Group..."
    
    aws autoscaling --region $REGION delete-auto-scaling-group \
        --auto-scaling-group-name az-aware-ec2-asg \
        --force-delete 2>/dev/null || true
    
    echo "Waiting for instances to terminate..."
    sleep 30
    
    echo "Auto Scaling Group deleted"
}

delete_launch_template() {
    echo "Deleting launch template..."
    
    aws ec2 --region $REGION delete-launch-template \
        --launch-template-name az-aware-ec2-launch-template 2>/dev/null || true
    
    echo "Launch template deleted"
}

delete_load_balancer() {
    echo "Deleting load balancer and target group..."
    
    ALB_ARN=$(aws elbv2 --region $REGION describe-load-balancers \
        --names az-aware-routing-bugbash-ec2 \
        --query "LoadBalancers[0].LoadBalancerArn" \
        --output text 2>/dev/null || echo "")
    
    if [ ! -z "$ALB_ARN" ] && [ "$ALB_ARN" != "None" ]; then
        LISTENER_ARN=$(aws elbv2 --region $REGION describe-listeners \
            --load-balancer-arn $ALB_ARN \
            --query "Listeners[0].ListenerArn" \
            --output text 2>/dev/null || echo "")
        
        [ ! -z "$LISTENER_ARN" ] && aws elbv2 --region $REGION delete-listener \
            --listener-arn $LISTENER_ARN 2>/dev/null || true
        
        aws elbv2 --region $REGION delete-load-balancer \
            --load-balancer-arn $ALB_ARN 2>/dev/null || true
    fi
    
    sleep 10
    
    TG_ARN=$(aws elbv2 --region $REGION describe-target-groups \
        --names az-aware-routing-bugbash-ec2 \
        --query "TargetGroups[0].TargetGroupArn" \
        --output text 2>/dev/null || echo "")
    
    [ ! -z "$TG_ARN" ] && [ "$TG_ARN" != "None" ] && aws elbv2 --region $REGION delete-target-group \
        --target-group-arn $TG_ARN 2>/dev/null || true
    
    echo "Load balancer and target group deleted"
}

delete_cluster() {
    echo "Deleting ECS cluster...wait for 30s for instances to be deregistered"
    sleep 30
    
    aws ecs --region $REGION --endpoint $ECS_ENDPOINT delete-cluster \
        --cluster $CLUSTER_NAME 2>/dev/null || true
    
    echo "Cluster deleted"
}

deregister_task_definitions() {
    echo "Deregistering task definitions..."
    
    for family in az-aware-fe-service-ec2 az-aware-backend-service-ec2; do
        REVISIONS=$(aws ecs --region $REGION --endpoint $ECS_ENDPOINT list-task-definitions \
            --family-prefix $family \
            --query "taskDefinitionArns[]" \
            --output text 2>/dev/null || echo "")
        
        for arn in $REVISIONS; do
            aws ecs --region $REGION --endpoint $ECS_ENDPOINT deregister-task-definition \
                --task-definition $arn 2>/dev/null || true
        done
    done
    
    echo "Task definitions deregistered"
}

delete_security_groups() {
    echo "Deleting security groups..."
    
    VPC_ID=$(aws ec2 --region $REGION describe-vpcs --filters "Name=isDefault,Values=true" --query "Vpcs[0].VpcId" --output text)
    
    for sg_name in az-aware-routing-bugbash-server-sg az-aware-routing-bugbash-client-sg az-aware-routing-bugbash-lb-sg; do
        SG_ID=$(aws ec2 --region $REGION describe-security-groups \
            --filters "Name=group-name,Values=$sg_name" "Name=vpc-id,Values=$VPC_ID" \
            --query "SecurityGroups[0].GroupId" \
            --output text 2>/dev/null || echo "")
        
        if [ ! -z "$SG_ID" ] && [ "$SG_ID" != "None" ]; then
            aws ec2 --region $REGION delete-security-group --group-id $SG_ID 2>/dev/null || true
        fi
    done
    
    echo "Security groups deleted"
}

stop_proxy() {
    echo "Stopping proxy server..."
    lsof -ti:8080 | xargs kill -9 2>/dev/null || true
    echo "Proxy server stopped"
}

main() {
    if [ -z "$1" ]; then
        echo "Usage: $0 <account-id> [role-name] [scope]"
        echo "Scope: ecs-services (services/tasks), ecs-all (services/cluster/tasks only) or all (includes ASG, LT, lb and security groups)"
        exit 1
    fi

    local account_id=$1
    local role_name=${2:-Admin}
    local scope=${3:-all}

    setup_credentials "$account_id" "$role_name"
    
    case $scope in
        "ecs-all")
            stop_proxy
            delete_services
            delete_cluster
            deregister_task_definitions
            ;;
        "ecs-services")
            stop_proxy
            delete_services
            ;;            
        "all")
            stop_proxy
            delete_services
            delete_autoscaling_group
            delete_load_balancer
            delete_cluster
            deregister_task_definitions
            delete_launch_template
            delete_security_groups
            ;;
        *)
            echo "Invalid scope. Choose: ecs or all"
            exit 1
            ;;
    esac
    
    echo "Cleanup complete!"
}

main "$@"
