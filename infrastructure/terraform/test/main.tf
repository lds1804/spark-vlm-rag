# =============================================================================
# Terraform — Minimal POC environment for spark-vlm-rag
# =============================================================================
# This creates:
#   1. Security group with required ports
#   2. g4dn.xlarge instance for vLLM
#   3. t3.large instance for Spark + Weaviate
#
# Usage:
#   terraform init
#   terraform plan
#   terraform apply
# =============================================================================

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

variable "region" {
  description = "AWS region"
  default     = "us-east-1"
}

variable "key_name" {
  description = "Existing EC2 Key Pair name for SSH access"
  type        = string
}

variable "gpu_instance_type" {
  description = "GPU instance type for vLLM"
  default     = "g4dn.xlarge"
}

variable "cpu_instance_type" {
  description = "CPU instance type for Spark + Weaviate"
  default     = "t3.large"
}

provider "aws" {
  region = var.region
}

# Get latest Ubuntu 22.04 AMI
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Security group
resource "aws_security_group" "poc_sg" {
  name_prefix = "spark-vlm-rag-poc-"
  description = "Security group for spark-vlm-rag POC"

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "vLLM API"
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Weaviate"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "FastAPI"
    from_port   = 8001
    to_port     = 8001
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Internal traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Project = "spark-vlm-rag-poc"
  }
}

# GPU Instance — vLLM
resource "aws_instance" "vllm" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.gpu_instance_type
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.poc_sg.id]

  root_block_device {
    volume_size = 100
    volume_type = "gp3"
  }

  user_data = file("${path.module}/../../user-data/vllm-gpu.sh")

  tags = {
    Name    = "spark-vlm-rag-vllm"
    Project = "spark-vlm-rag-poc"
  }
}

# CPU Instance — Spark + Weaviate
resource "aws_instance" "spark" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.cpu_instance_type
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.poc_sg.id]

  root_block_device {
    volume_size = 50
    volume_type = "gp3"
  }

  user_data = file("${path.module}/../../user-data/spark-node.sh")

  tags = {
    Name    = "spark-vlm-rag-spark"
    Project = "spark-vlm-rag-poc"
  }
}

# Outputs
output "vllm_public_ip" {
  description = "Public IP of the vLLM GPU instance"
  value       = aws_instance.vllm.public_ip
}

output "spark_public_ip" {
  description = "Public IP of the Spark + Weaviate instance"
  value       = aws_instance.spark.public_ip
}

output "ssh_commands" {
  description = "SSH commands to connect to instances"
  value = {
    vllm  = "ssh -i ${var.key_name}.pem ubuntu@${aws_instance.vllm.public_ip}"
    spark = "ssh -i ${var.key_name}.pem ubuntu@${aws_instance.spark.public_ip}"
  }
}
