# ECS Service Connect AZ-Aware Routing Demo & BugBash

This repository demonstrates AZ-aware routing using ECS Service Connect with both Fargate and EC2 launch types.

## Prerequisites

- AWS CLI configured with appropriate credentials
- `isengardcli` for credential management
- `jq` for JSON parsing
- Python 3 (for the web analyzer)

## Architecture

The demo creates:
- **Frontend service**: Receives requests from ALB and forwards to backend
- **Backend service**: Processes requests and returns responses
- **Service Connect**: Enables AZ-aware routing between services
- **ALB**: Routes external traffic to frontend service
- **Web Analyzer**: Visualizes AZ routing statistics

## Fargate Launch Type

### Setup

```bash
# Full setup (infrastructure + services)
./setup_fargate.sh <account-id> [role-name]

# Step-by-step setup
./setup_fargate.sh <account-id> [role-name] infrastructure  # VPC, ALB, cluster
./setup_fargate.sh <account-id> [role-name] tasks           # Task definitions
./setup_fargate.sh <account-id> [role-name] services        # ECS services

# Use specific task definition revisions
./setup_fargate.sh <account-id> [role-name] services <fe-revision> <backend-revision>
```

**Default values:**
- Role: `Admin`
- Region: `us-west-2`
- Task count: 10

### Cleanup

```bash
# Clean up services only
./clean_up_fargate.sh <account-id> [role-name] ecs-services

# Clean up ECS resources (services, cluster, task definitions)
./clean_up_fargate.sh <account-id> [role-name] ecs-all

# Clean up everything (includes ALB, target groups, security groups)
./clean_up_fargate.sh <account-id> [role-name] all
```

## EC2 Launch Type

### Configuration

Set environment variables (optional):

```bash
export ENVOY_IMAGE=public.ecr.aws/appmesh/aws-appmesh-envoy:v1.34.12.1-prod
export TASK_COUNT=12
```

**Defaults:**
- `ENVOY_IMAGE`: `public.ecr.aws/appmesh/aws-appmesh-envoy:v1.34.12.1-prod`
- `TASK_COUNT`: `1`

### Setup

```bash
# Full setup (ASG, cluster, services)
./setup_ec2.sh <account-id> [role-name]

# Step-by-step setup
./setup_ec2.sh <account-id> [role-name] infrastructure  # VPC, ALB, ASG, cluster
./setup_ec2.sh <account-id> [role-name] tasks           # Task definitions
./setup_ec2.sh <account-id> [role-name] services        # ECS services
```

**Features:**
- Auto Scaling Group with ECS-optimized AMI
- Custom Envoy image pre-loaded on instances
- awsvpc network mode for better isolation
- Metadata hop limit configured for awsvpc

### Cleanup

```bash
# Clean up services only
./clean_up_ec2.sh <account-id> [role-name] ecs

# Clean up everything (includes ASG, launch template, ALB, security groups)
./clean_up_ec2.sh <account-id> [role-name] all
```

## Web Analyzer

After setup completes, the web analyzer automatically opens in your browser at `http://localhost:8080/az-routing-test.html`.

**Features:**
- Real-time AZ routing statistics
- Request success/failure tracking
- Historical data with slider navigation
- Automatic snapshots every 10 requests

**Manual start:**
```bash
./setup_fargate.sh <account-id> [role-name] analyzer
# or
./setup_ec2.sh <account-id> [role-name] analyzer
```

## Custom Envoy Image

To use a different Envoy image with EC2:

```bash
# Set before running setup
export ENVOY_IMAGE=<your-custom-envoy-image>
./setup_ec2.sh <account-id>

# Or inline
ENVOY_IMAGE=<your-custom-envoy-image> ./setup_ec2.sh <account-id>
```

The image is pulled and cached on EC2 instances during launch via user data.

## Troubleshooting

### Health Check Failures
- Check target group health: `aws elbv2 describe-target-health --target-group-arn <arn>`
- Verify security group rules allow traffic on ports 8080 (frontend) and 8090 (backend)
- Check container logs in CloudWatch

### Service Connect Issues
- Verify namespace exists: `aws servicediscovery list-namespaces`
- Check Service Connect logs with prefix `service-connect` in CloudWatch
- Ensure both services are in the same namespace

### EC2 Instance Issues
- Check user data execution: `cat /var/log/cloud-init-output.log` on the instance
- Verify ECS agent is running: `systemctl status ecs`
- Check instance metadata access for awsvpc mode

## Resources Created

### Fargate
- ECS Cluster: `az-aware-bugbash-cluster`
- Services: `az-aware-fe-service`, `az-aware-backend-service`
- ALB: `az-aware-routing-bugbash`
- Target Group: `az-aware-routing-bugbash`
- Security Groups: `az-aware-routing-bugbash-lb-sg`, `az-aware-routing-bugbash-client-sg`, `az-aware-routing-bugbash-server-sg`

### EC2
- ECS Cluster: `az-aware-bugbash-cluster-ec2`
- Services: `az-aware-fe-service-ec2`, `az-aware-backend-service-ec2`
- ALB: `az-aware-routing-bugbash-ec2`
- Target Group: `az-aware-routing-bugbash-ec2`
- Launch Template: `az-aware-ec2-launch-template`
- Auto Scaling Group: `az-aware-ec2-asg`
- Security Groups: Same as Fargate

## Notes

- Both setups use the same Service Connect namespace for potential cross-launch-type communication
- EC2 setup uses awsvpc network mode (not bridge) for consistency with Fargate
- The web analyzer runs on port 8080 locally - ensure it's not in use
- All resources are created in `us-west-2` region by default
