# Configure the AWS Provider
provider "aws" {
  version = "~> 2.0"
  region  = "us-east-1"
}

terraform {
  backend "s3" {
    bucket = "clnoel-ecs-deepdive"
    key    = "tfstate"
    region = "us-east-1"
  }
}

data "template_file" "userdata" {
  template = "${file("userdata.sh.tpl")}"

  vars = {
    cluster_name = "ecs-deepdive-${terraform.workspace}"
  }
}

resource "aws_ecs_cluster" "ecs-cluster" {
  name = "ecs-deepdive-${terraform.workspace}"
}

resource "aws_vpc" "main" {
  cidr_block       = "10.0.0.0/16"

  tags = {
    Name = "devops-${terraform.workspace}"
  }
}

resource "aws_subnet" "public-1a" {
  vpc_id     = "${aws_vpc.main.id}"
  cidr_block = "10.0.128.0/24"
  availability_zone = "us-east-1a"
  tags = {
    Name = "public-1a-${terraform.workspace}"
  }
}

resource "aws_internet_gateway" "gw" {
  vpc_id = "${aws_vpc.main.id}"

  tags = {
    Name = "igw-${terraform.workspace}"
  }
}

resource "aws_route_table" "rt-public" {
  vpc_id = "${aws_vpc.main.id}"
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = "${aws_internet_gateway.gw.id}"
  }
  tags = {
    Name = "rt-public-1a-${terraform.workspace}"
  }
}

resource "aws_route_table_association" "public-1a" {
  subnet_id      = "${aws_subnet.public-1a.id}"
  route_table_id = "${aws_route_table.rt-public.id}"
}

resource "aws_security_group" "ecs-sg" {
  name        = "allow_ssh"
  description = "Allow SSH inbound traffic"
  vpc_id      = "${aws_vpc.main.id}"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "TCP"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "TCP"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "ecs-instance" {
  ami = "ami-0f22545d00916181b"
  instance_type = "t2.micro"
  subnet_id = "${aws_subnet.public-1a.id}"
  vpc_security_group_ids = ["${aws_security_group.ecs-sg.id}"]
  associate_public_ip_address="true"
  key_name = "ecs-deepdive"
  iam_instance_profile = "${aws_iam_instance_profile.ecs_profile.name}"
  user_data = "${data.template_file.userdata.rendered}"
}

resource "aws_route53_record" "www" {
  zone_id = "Z1UKXVYYQ8MSN8"
  name    = "ecs-instance.curtisnoel.net"
  type    = "A"
  ttl     = "300"
  records = ["${aws_instance.ecs-instance.public_ip}"]
}

resource "aws_iam_role" "ecs_role" {
  name = "ecs_role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF

  tags = {
      Name = "ecs-iam-role-${terraform.workspace}"
  }
}

resource "aws_iam_instance_profile" "ecs_profile" {
  name = "ecs_profile"
  role = "${aws_iam_role.ecs_role.name}"
}

resource "aws_iam_role_policy" "ecs_policy" {
  name = "ecs_policy"
  role = "${aws_iam_role.ecs_role.id}"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": [
        "s3:*"
      ],
      "Effect": "Allow",
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeTags",
        "ecs:CreateCluster",
        "ecs:DeregisterContainerInstance",
        "ecs:DiscoverPollEndpoint",
        "ecs:Poll",
        "ecs:RegisterContainerInstance",
        "ecs:StartTelemetrySession",
        "ecs:UpdateContainerInstancesState",
        "ecs:Submit*",
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "*"
    }
  ]
}
EOF
}

resource "aws_ecs_service" "nginx_service" {
  name            = "nginx"
  //iam_role        = "arn:aws:iam::663128422632:role/ecsServiceRole"
  cluster         = "${aws_ecs_cluster.ecs-cluster.id}"
  task_definition = "${aws_ecs_task_definition.nginx_app.family}:${max("${aws_ecs_task_definition.nginx_app.revision}", "${data.aws_ecs_task_definition.nginx_app.revision}")}"
  desired_count   = "1"
  deployment_minimum_healthy_percent = "50"
  deployment_maximum_percent = "100"
  lifecycle {
    ignore_changes = ["task_definition"]
  }
}

data "aws_ecs_task_definition" "nginx_app" {
  task_definition = "${aws_ecs_task_definition.nginx_app.family}"
  depends_on = ["aws_ecs_task_definition.nginx_app"]
}

resource "aws_ecs_task_definition" "nginx_app" {
  family                = "web_app"
  container_definitions = <<DEFINITION
[
  {
    "name": "nginx",
    "image": "nginx:latest",
    "memoryReservation": 300,
    "cpu": 256,
    "portMappings": [
      {
        "containerPort": 80,
        "hostPort": 80
      }
    ],
    "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/webserver",
          "awslogs-region": "us-east-1",
          "awslogs-stream-prefix": "ecs"
        }
    }
  }
]
DEFINITION
}
