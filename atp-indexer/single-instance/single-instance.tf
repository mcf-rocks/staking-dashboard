data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "availability-zone"
    values = [data.aws_availability_zones.available.names[0]]
  }
}

data "aws_subnet" "public" {
  id = data.aws_subnets.default.ids[0]
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-6.1-x86_64"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_security_group" "instance" {
  name        = "${local.si_name}-instance"
  description = "Public HTTP/HTTPS for the staking-dashboard atp-indexer single instance"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.si_allowed_http_cidrs
  }
  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.si_allowed_http_cidrs
  }
  egress {
    description = "Outbound internet"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.si_tags
}

resource "aws_iam_role" "instance" {
  name = "${local.si_name}-instance"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
  tags = local.si_tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Pull the atp-indexer image from this repo's existing ECR repository.
resource "aws_iam_role_policy" "ecr_read" {
  name = "${local.si_name}-ecr-read"
  role = aws_iam_role.instance.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer"
        ]
        Resource = "arn:aws:ecr:${var.region}:${data.aws_caller_identity.current.account_id}:repository/*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "instance" {
  name = "${local.si_name}-instance"
  role = aws_iam_role.instance.name
}

resource "aws_ebs_volume" "data" {
  availability_zone = data.aws_subnet.public.availability_zone
  size              = var.si_data_volume_size_gb
  type              = "gp3"
  encrypted         = true
  tags              = merge(local.si_tags, { Name = "${local.si_name}-data" })
}

resource "aws_instance" "this" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.si_instance_type
  subnet_id                   = data.aws_subnet.public.id
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.instance.id]
  iam_instance_profile        = aws_iam_instance_profile.instance.name

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  user_data = templatefile("${path.module}/templates/user_data.sh.tftpl", {
    region            = var.region
    account_id        = data.aws_caller_identity.current.account_id
    volume_id_no_dash = replace(aws_ebs_volume.data.id, "-", "")
    compose_b64 = base64encode(templatefile("${path.module}/templates/docker-compose.yml.tftpl", {
      atp_indexer_image              = var.si_atp_indexer_image
      atp_postgres_connection_string = "postgresql://ponder:ponder@local-postgres:5432/ponder"
      atp_database_schema            = var.si_atp_database_schema
    }))
    caddyfile_b64 = base64encode(templatefile("${path.module}/templates/Caddyfile.tftpl", {
      acme_email             = var.si_acme_email
      atp_indexer_domain     = var.si_atp_indexer_domain
      cloudfront_front       = var.si_front_with_cloudfront
      cf_secret_header_name  = var.cloudfront_secret_header_name
      cf_secret_header_value = var.cloudfront_secret_header_value
    }))
    start_services_on_boot = var.si_start_services_on_boot
  })

  tags = local.si_tags
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/xvdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.this.id
}

resource "aws_eip" "this" {
  domain   = "vpc"
  instance = aws_instance.this.id
  tags     = local.si_tags
}

data "aws_route53_zone" "zone" {
  count        = var.si_create_dns_records || var.si_front_with_cloudfront ? 1 : 0
  name         = var.si_route53_zone_name
  private_zone = false
}

# Caddy-direct: hostname -> the instance EIP (testnet). Mutually exclusive with CloudFront-front.
resource "aws_route53_record" "direct" {
  count   = var.si_create_dns_records ? 1 : 0
  zone_id = data.aws_route53_zone.zone[0].zone_id
  name    = var.si_atp_indexer_domain
  type    = "A"
  ttl     = 60
  records = [aws_eip.this.public_ip]
}

output "instance_public_ip" {
  value = aws_eip.this.public_ip
}

output "instance_id" {
  value = aws_instance.this.id
}
