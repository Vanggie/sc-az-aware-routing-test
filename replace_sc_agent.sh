#!/bin/bash
set -e
ENVOY_IMAGE=377429403256.dkr.ecr.us-west-2.amazonaws.com/aws-appmesh-envoy:v1.34.12.1-beta
aws ecr get-login-password --region us-west-2 | docker login --username AWS --password-stdin $ENVOY_IMAGE
docker pull $ENVOY_IMAGE
docker tag $ENVOY_IMAGE ecs-service-connect-agent:interface-v1
sudo docker image save ecs-service-connect-agent:interface-v1 -o ecs-service-connect-agent.interface-v1.tar
sudo cp ecs-service-connect-agent.interface-v1.tar /var/lib/ecs/deps/serviceconnect/
sudo systemctl stop ecs
sudo rm -rf /var/lib/ecs/data/*; sudo rm -rf /var/log/ecs/*
docker kill $(docker ps -q); docker rm $(docker ps -a -q); docker rmi --force $(docker images -a -q)
sudo systemctl start ecs

