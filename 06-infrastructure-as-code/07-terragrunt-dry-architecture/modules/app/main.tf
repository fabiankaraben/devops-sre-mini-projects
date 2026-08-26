# ==============================================================================
# main.tf - Application Compute & Security Resources
# ==============================================================================

resource "aws_security_group" "app" {
  name        = "${var.name}-app-sg"
  description = "Security group for ${var.name} application workload"
  vpc_id      = var.vpc_id

  ingress {
    description = "Application HTTP traffic"
    from_port   = var.app_port
    to_port     = var.app_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH administrative access"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
  }

  egress {
    description = "Outbound internet access"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    var.tags,
    {
      Name = "${var.name}-app-sg"
    }
  )
}

resource "aws_instance" "app" {
  count                  = var.instance_count
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = element(var.subnet_ids, count.index % max(1, length(var.subnet_ids)))
  vpc_security_group_ids = [aws_security_group.app.id]

  user_data = <<-EOF
              #!/bin/bash
              echo "Starting ${var.name} instance ${count.index + 1}"
              EOF

  tags = merge(
    var.tags,
    {
      Name = "${var.name}-node-${count.index + 1}"
      Role = "App"
    }
  )
}
