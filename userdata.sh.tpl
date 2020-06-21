#!bin/bash
mkdir -p /etc/ecs
touch /etc/ecs/ecs.config
echo ECS_CLUSTER=${cluster_name} > /etc/ecs/ecs.config
yum install docker
yum update -y
yum install docker -y
service docker start
sudo usermod -a -G docker ec2-user
yum install ecs-init -y
start ecs
